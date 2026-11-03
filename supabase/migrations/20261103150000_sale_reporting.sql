-- Reporting is a CRM handoff, never inventory confirmation.
create table public.sale_reviews (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.inquiries(id) on delete restrict,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  contact_id uuid not null references public.contacts(id) on delete restrict,
  reported_by uuid not null references public.profiles(id) on delete restrict,
  reported_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  resolved_by uuid references public.profiles(id) on delete restrict,
  resolved_at timestamptz,
  constraint sale_reviews_resolution check (
    (status = 'pending' and resolved_by is null and resolved_at is null)
    or (status <> 'pending' and resolved_by is not null and resolved_at is not null)
  )
);
create unique index sale_reviews_one_pending_inquiry_idx
on public.sale_reviews(inquiry_id) where status = 'pending';
create index sale_reviews_vehicle_idx on public.sale_reviews(vehicle_id);

create table public.inquiry_status_history (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.inquiries(id) on delete restrict,
  from_status public.inquiry_status not null,
  to_status public.inquiry_status not null,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  review_id uuid references public.sale_reviews(id) on delete restrict,
  occurred_at timestamptz not null default now()
);
alter table public.sale_reviews enable row level security;
alter table public.inquiry_status_history enable row level security;
create policy sale_reviews_select_visible_inquiry on public.sale_reviews
for select to authenticated using (
  exists (select 1 from public.inquiries i where i.id = sale_reviews.inquiry_id)
);
create policy inquiry_status_history_select_visible_inquiry on public.inquiry_status_history
for select to authenticated using (
  exists (select 1 from public.inquiries i where i.id = inquiry_status_history.inquiry_id)
);
revoke all on public.sale_reviews, public.inquiry_status_history from public, anon, authenticated, service_role;
grant select on public.sale_reviews, public.inquiry_status_history to authenticated, service_role;

create function public.report_inquiry_sale(p_inquiry_id uuid, p_vehicle_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  selected_vehicle public.vehicles%rowtype;
  selected_inquiry public.inquiries%rowtype;
  active_reservation public.reservations%rowtype;
  pending public.sale_reviews%rowtype;
  review uuid;
begin
  -- Reject non-staff before any inventory-dependent error is observable.
  if not public.is_active_staff() then
    raise exception 'sale access denied' using errcode = '42501';
  end if;
  -- Shared order with interest additions and reservations: vehicle, actor, inquiry.
  select * into selected_vehicle from public.vehicles where id = p_vehicle_id for update;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'sale access denied' using errcode = '42501';
  end if;
  select * into selected_inquiry from public.inquiries where id = p_inquiry_id for update;
  if not found or not (public.is_owner_or_admin()
    or selected_inquiry.assignee_id = auth.uid()) is true then
    raise exception 'sale access denied' using errcode = '42501';
  end if;
  if selected_vehicle.id is null or selected_vehicle.deleted_at is not null
    or not selected_vehicle.sale_enabled then
    raise exception 'vehicle must exist and be enabled for sale' using errcode = '22023';
  end if;
  if not exists (select 1 from public.inquiry_interests
    where inquiry_id = p_inquiry_id and vehicle_id = p_vehicle_id) then
    raise exception 'vehicle is not an interest of this inquiry' using errcode = '22023';
  end if;
  -- A retry observes an existing handoff, not a new sale report. A later
  -- competing reservation must not invalidate its original response. Current
  -- authorization and explicit blocking/deletion restrictions still apply.
  select * into pending from public.sale_reviews
  where inquiry_id = p_inquiry_id and status = 'pending';
  if selected_inquiry.status = 'sale_reported' and pending.vehicle_id = p_vehicle_id then
    return pg_catalog.jsonb_build_object('review_id', pending.id);
  end if;
  select * into active_reservation from public.reservations
  where inquiry_id = p_inquiry_id and status = 'active';
  if active_reservation.id is not null then
    if active_reservation.vehicle_id <> p_vehicle_id
      or selected_vehicle.availability_status <> 'reserved' then
      raise exception 'report the vehicle reserved by this inquiry' using errcode = '22023';
    end if;
  elsif selected_vehicle.availability_status <> 'available' or exists (
    select 1 from public.reservations where vehicle_id = p_vehicle_id and status = 'active'
  ) then
    raise exception 'vehicle must be Available or reserved by this inquiry' using errcode = '22023';
  end if;
  if selected_inquiry.status not in ('new', 'contacted', 'following_up') then
    raise exception 'inquiry is not active' using errcode = '22023';
  end if;
  insert into public.sale_reviews(inquiry_id, vehicle_id, contact_id, reported_by)
  values (p_inquiry_id, p_vehicle_id, selected_inquiry.contact_id, auth.uid()) returning id into review;
  insert into public.inquiry_status_history(inquiry_id, from_status, to_status, actor_id, review_id)
  values (p_inquiry_id, selected_inquiry.status, 'sale_reported', auth.uid(), review);
  update public.inquiries set status = 'sale_reported' where id = p_inquiry_id;
  return pg_catalog.jsonb_build_object('review_id', review);
end;
$$;
revoke all on function public.report_inquiry_sale(uuid, uuid) from public, anon, authenticated;
grant execute on function public.report_inquiry_sale(uuid, uuid) to authenticated;
comment on function public.report_inquiry_sale(uuid, uuid) is
  'Report an enabled interest vehicle on an active authorized inquiry. Retain inventory and reservations, create one pending administrative review and preserve the status transition. Identical pending reports return the same review ID.';
