alter table public.reservations add column completed_by uuid
  references public.profiles(id) on delete restrict;
alter table public.reservations drop constraint reservations_end_state;
alter table public.reservations add constraint reservations_end_state check (
  (status='active' and ended_at is null and cancelled_by is null and completed_by is null)
  or (status='cancelled' and ended_at is not null and cancelled_by is not null and completed_by is null)
  or (status='completed' and ended_at is not null and completed_by is not null and cancelled_by is null)
);

create table public.confirmed_sales (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null unique references public.sale_reviews(id) on delete restrict,
  vehicle_id uuid not null unique references public.vehicles(id) on delete restrict,
  inquiry_id uuid not null references public.inquiries(id) on delete restrict,
  contact_id uuid not null references public.contacts(id) on delete restrict,
  confirmed_by uuid not null references public.profiles(id) on delete restrict,
  responsible_id uuid references public.profiles(id) on delete restrict,
  confirmed_at timestamptz not null default now()
);
alter table public.confirmed_sales enable row level security;
create policy confirmed_sales_select_visible_inquiry on public.confirmed_sales
for select to authenticated using (
  exists (select 1 from public.inquiries i where i.id=confirmed_sales.inquiry_id)
);
revoke all on public.confirmed_sales from public, anon, authenticated, service_role;
grant select on public.confirmed_sales to authenticated, service_role;

create function public.guard_confirmed_vehicle()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op='UPDATE' and old.availability_status='sold'
    and new.availability_status<>'sold' and exists (
      select 1 from public.confirmed_sales where vehicle_id=old.id
    ) then
    raise exception 'confirmed sales cannot be reversed' using errcode='22023';
  end if;
  if new.availability_status='sold' and (tg_op='INSERT' or old.availability_status<>'sold')
    and not exists (select 1 from public.confirmed_sales where vehicle_id=new.id) then
    -- Database-owner maintenance/fixtures are outside the application API.
    -- SET ROLE authenticated/service_role never receives this exemption, even
    -- when a privileged test connection is used to exercise actual API roles.
    if session_user='postgres' and pg_catalog.current_setting('role',true)='none' then
      return new;
    end if;
    raise exception 'confirm an inquiry sale before marking the vehicle Sold' using errcode='22023';
  end if;
  return new;
end $$;
revoke all on function public.guard_confirmed_vehicle() from public,anon,authenticated;
-- Runs after the existing active-reservation guard, preserving its exact errors.
create trigger vehicles_guard_sale_confirmation before insert or update on public.vehicles
for each row execute function public.guard_confirmed_vehicle();

create function public.guard_pending_sale_review()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.sale_reviews where inquiry_id=old.id and status='pending')
    and (new.contact_id is distinct from old.contact_id
      or new.assignee_id is distinct from old.assignee_id
      or (new.status is distinct from old.status and new.status<>'sale_reported')) then
    raise exception 'resolve the pending sale review before changing the inquiry' using errcode='22023';
  end if;
  return new;
end $$;
revoke all on function public.guard_pending_sale_review() from public,anon,authenticated;
create trigger inquiries_guard_pending_sale_review before update on public.inquiries
for each row execute function public.guard_pending_sale_review();

create function public.resolve_sale_review(p_review_id uuid,p_confirm boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  review public.sale_reviews%rowtype;
  vehicle public.vehicles%rowtype;
  inquiry public.inquiries%rowtype;
  reservation public.reservations%rowtype;
  sale uuid;
  result_status text;
begin
  if not public.is_owner_or_admin() then
    raise exception 'sale resolution access denied' using errcode='42501';
  end if;
  if p_review_id is null or p_confirm is null then
    raise exception 'review and explicit confirmation decision are required' using errcode='22023';
  end if;
  -- Review identifiers are immutable and clients cannot update this table.
  -- Read them without locking to preserve vehicle -> actor -> inquiry order.
  select * into review from public.sale_reviews where id=p_review_id;
  if not found then raise exception 'sale review not found' using errcode='22023'; end if;
  select * into vehicle from public.vehicles where id=review.vehicle_id for update;
  perform 1 from public.profiles where id=auth.uid() for share;
  if not public.is_owner_or_admin() then
    raise exception 'sale resolution access denied' using errcode='42501';
  end if;
  select * into inquiry from public.inquiries where id=review.inquiry_id for update;
  select * into review from public.sale_reviews where id=p_review_id for update;
  result_status:=case when p_confirm then 'confirmed' else 'rejected' end;
  if review.status<>'pending' then
    if review.status<>result_status then
      raise exception 'sale review is already resolved with a different decision' using errcode='22023';
    end if;
    select id into sale from public.confirmed_sales where review_id=p_review_id;
    return pg_catalog.jsonb_build_object('review_id',p_review_id,'status',result_status,'sale_id',sale);
  end if;
  if inquiry.status<>'sale_reported' or inquiry.contact_id<>review.contact_id then
    raise exception 'sale review no longer matches the inquiry' using errcode='22023';
  end if;
  select * into reservation from public.reservations
  where inquiry_id=inquiry.id and status='active' for update;
  if reservation.id is not null and reservation.vehicle_id<>vehicle.id then
    raise exception 'sale review does not match the active reservation' using errcode='22023';
  end if;
  if p_confirm then
    if vehicle.deleted_at is not null or not vehicle.sale_enabled then
      raise exception 'vehicle must exist and be enabled for sale' using errcode='22023';
    end if;
    if exists (select 1 from public.reservations
      where vehicle_id=vehicle.id and status='active' and inquiry_id<>inquiry.id) then
      raise exception 'resolve the competing reservation before confirming the sale' using errcode='22023';
    end if;
    if (reservation.id is null and vehicle.availability_status<>'available')
      or (reservation.id is not null and vehicle.availability_status<>'reserved') then
      raise exception 'vehicle must be Available or reserved by this inquiry' using errcode='22023';
    end if;
    if not exists (select 1 from public.inquiry_interests where inquiry_id=inquiry.id and vehicle_id=vehicle.id) then
      raise exception 'vehicle is not an interest of this inquiry' using errcode='22023';
    end if;
    -- End the reservation before the existing inventory guard permits Sold.
    if reservation.id is not null then
      update public.reservations set status='completed',ended_at=now(),completed_by=auth.uid()
      where id=reservation.id;
    end if;
    insert into public.confirmed_sales(review_id,vehicle_id,inquiry_id,contact_id,confirmed_by,responsible_id)
    values(review.id,vehicle.id,inquiry.id,review.contact_id,auth.uid(),inquiry.assignee_id)
    returning id into sale;
    update public.vehicles set availability_status='sold' where id=vehicle.id;
  else
    -- Reuse cancellation so its availability and historical attribution stay
    -- identical to the existing reservation operation. Locks are reentrant.
    if reservation.id is not null then perform public.cancel_reservation(reservation.id); end if;
  end if;
  update public.sale_reviews set status=result_status,resolved_at=now(),resolved_by=auth.uid()
  where id=p_review_id;
  if not p_confirm then
    insert into public.inquiry_status_history(inquiry_id,from_status,to_status,actor_id,review_id)
    values(inquiry.id,inquiry.status,'closed_without_sale',auth.uid(),review.id);
    update public.inquiries set status='closed_without_sale' where id=inquiry.id;
  end if;
  return pg_catalog.jsonb_build_object('review_id',p_review_id,'status',result_status,'sale_id',sale);
end $$;
revoke all on function public.resolve_sale_review(uuid,boolean) from public,anon,authenticated;
grant execute on function public.resolve_sale_review(uuid,boolean) to authenticated;
comment on table public.confirmed_sales is
  'One irreversible confirmed sale per vehicle, linked to explicit administrative review. Historical responsible staff and confirming actor are retained; reporting formulas remain deferred.';
comment on function public.resolve_sale_review(uuid,boolean) is
  'Active Owner/Admin explicitly confirms or rejects one pending report atomically. Confirmation rechecks sale eligibility and competing reservations; rejection only cancels this inquiry reservation. Same-decision retries retain the original resolution.';
