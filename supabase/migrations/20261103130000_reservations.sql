-- A commercial reservation always links inquiry, contact and one specific
-- vehicle. It is created and cancelled only through controlled operations.
alter table public.vehicles add column sale_enabled boolean not null default true;

create type public.reservation_status as enum ('active', 'cancelled');

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.inquiries (id) on delete restrict,
  vehicle_id uuid not null references public.vehicles (id) on delete restrict,
  contact_id uuid not null references public.contacts (id) on delete restrict,
  created_by uuid not null references public.profiles (id) on delete restrict,
  status public.reservation_status not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  cancelled_by uuid references public.profiles (id) on delete restrict,
  constraint reservations_end_state check (
    (status = 'active' and ended_at is null and cancelled_by is null)
    or (status = 'cancelled' and ended_at is not null and cancelled_by is not null)
  )
);

-- At most one active reservation per vehicle and per linked inquiry.
create unique index reservations_one_active_per_vehicle_idx
on public.reservations (vehicle_id) where status = 'active';
create unique index reservations_one_active_per_inquiry_idx
on public.reservations (inquiry_id) where status = 'active';
create index reservations_inquiry_idx on public.reservations (inquiry_id);
create index reservations_contact_idx on public.reservations (contact_id);

alter table public.reservations enable row level security;

-- Reservation visibility follows the linked inquiry; no separate actor logic.
create policy reservations_select_visible_inquiry
on public.reservations for select to authenticated
using (
  exists (select 1 from public.inquiries i where i.id = reservations.inquiry_id)
);

revoke all on public.reservations from anon, authenticated;
grant select on public.reservations to authenticated;
grant select, insert, update on public.reservations to service_role;

comment on table public.reservations is
  'One active reservation per vehicle and per inquiry. History is retained after cancellation; there is no automatic expiry or payment.';

-- Leaving Reserved, selling or deleting while a reservation is active would
-- silently break the customer commitment, so the inventory path must refuse it.
create function public.guard_reserved_vehicle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.reservations r
    where r.vehicle_id = old.id and r.status = 'active'
  ) then
    if new.availability_status is distinct from 'reserved' then
      raise exception 'cancel the active reservation before changing availability'
        using errcode = '22023';
    end if;
    if new.deleted_at is not null and old.deleted_at is null then
      raise exception 'cancel the active reservation before deleting the vehicle'
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_reserved_vehicle() from public, anon, authenticated;
create trigger vehicles_guard_active_reservation
before update on public.vehicles
for each row execute function public.guard_reserved_vehicle();

-- Reassignment, contact changes and closure without sale are blocked while the
-- inquiry anchors an active reservation. Reporting a sale stays allowed.
create function public.guard_reserved_inquiry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.reservations r
    where r.inquiry_id = new.id and r.status = 'active'
  ) then
    if new.assignee_id is distinct from old.assignee_id then
      raise exception 'cancel the active reservation before reassigning the inquiry'
        using errcode = '22023';
    end if;
    if new.contact_id is distinct from old.contact_id then
      raise exception 'cancel the active reservation before changing the inquiry contact'
        using errcode = '22023';
    end if;
    if new.status = 'closed_without_sale' and old.status is distinct from 'closed_without_sale' then
      raise exception 'cancel the active reservation before closing the inquiry without a sale'
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_reserved_inquiry() from public, anon, authenticated;
create trigger inquiries_guard_active_reservation
before update on public.inquiries
for each row execute function public.guard_reserved_inquiry();

create function public.reserve_inquiry_vehicle(p_inquiry_id uuid, p_vehicle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_vehicle public.vehicles%rowtype;
  selected_inquiry public.inquiries%rowtype;
  reservation uuid;
begin
  -- Match add_inquiry_interest ordering: vehicle, actor, inquiry. The actor lock
  -- holds deactivation/role changes until this transaction commits.
  select * into selected_vehicle from public.vehicles
  where id = p_vehicle_id for update;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'reservation access denied' using errcode = '42501';
  end if;

  select * into selected_inquiry from public.inquiries
  where id = p_inquiry_id for update;
  if not found then
    raise exception 'reservation access denied' using errcode = '42501';
  end if;
  if not (
    public.is_owner_or_admin()
    or (public.current_staff_role() = 'seller' and selected_inquiry.assignee_id = auth.uid())
  ) is true then
    raise exception 'reservation access denied' using errcode = '42501';
  end if;
  if selected_inquiry.status not in ('new', 'contacted', 'following_up') then
    raise exception 'inquiry is not active' using errcode = '22023';
  end if;
  if selected_vehicle.id is null or selected_vehicle.deleted_at is not null
     or selected_vehicle.availability_status <> 'available'
     or not selected_vehicle.sale_enabled then
    raise exception 'vehicle must be Available and enabled for sale' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.inquiry_interests ii
    where ii.inquiry_id = p_inquiry_id and ii.vehicle_id = p_vehicle_id
  ) then
    raise exception 'vehicle is not an interest of this inquiry' using errcode = '22023';
  end if;

  begin
    insert into public.reservations (inquiry_id, vehicle_id, contact_id, created_by)
    values (p_inquiry_id, p_vehicle_id, selected_inquiry.contact_id, auth.uid())
    returning id into reservation;
  exception when unique_violation then
    raise exception 'an active reservation already exists' using errcode = '23505';
  end;
  update public.vehicles set availability_status = 'reserved' where id = p_vehicle_id;
  return pg_catalog.jsonb_build_object('reservation_id', reservation);
end;
$$;
revoke all on function public.reserve_inquiry_vehicle(uuid, uuid) from public, anon, authenticated;
grant execute on function public.reserve_inquiry_vehicle(uuid, uuid) to authenticated;

create function public.cancel_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.reservations%rowtype;
  selected_vehicle public.vehicles%rowtype;
  selected_inquiry public.inquiries%rowtype;
begin
  if not public.is_active_staff() then
    raise exception 'reservation access denied' using errcode = '42501';
  end if;
  -- Vehicle and inquiry identifiers never change, so reading them before taking
  -- locks keeps the reservation operation's order: vehicle, actor, inquiry.
  select * into target from public.reservations where id = p_reservation_id;
  if not found then
    raise exception 'reservation access denied' using errcode = '42501';
  end if;
  select * into selected_vehicle from public.vehicles
  where id = target.vehicle_id for update;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'reservation access denied' using errcode = '42501';
  end if;
  select * into selected_inquiry from public.inquiries
  where id = target.inquiry_id for update;
  select * into target from public.reservations
  where id = p_reservation_id for update;
  if target.status <> 'active' then
    raise exception 'reservation is not active' using errcode = '22023';
  end if;
  if not public.is_owner_or_admin() then
    -- A seller releases only a reservation they created while still assigned to
    -- the linked inquiry; an administrative reservation needs an administrator.
    if target.created_by <> auth.uid() or selected_inquiry.assignee_id <> auth.uid() then
      raise exception 'reservation access denied' using errcode = '42501';
    end if;
  end if;

  update public.reservations
  set status = 'cancelled', ended_at = now(), cancelled_by = auth.uid()
  where id = p_reservation_id;
  if selected_vehicle.availability_status = 'reserved' then
    update public.vehicles set availability_status = 'available'
    where id = target.vehicle_id;
  end if;
  return pg_catalog.jsonb_build_object('cancelled', true);
end;
$$;
revoke all on function public.cancel_reservation(uuid) from public, anon, authenticated;
grant execute on function public.cancel_reservation(uuid) to authenticated;

comment on column public.vehicles.sale_enabled is
  'Administrative sale eligibility. Blocking a vehicle requires the dedicated operation; an active reservation must be resolved first.';
comment on function public.reserve_inquiry_vehicle(uuid, uuid) is
  'Active staff reserve an Available, sale-enabled interest of an active inquiry. Sellers require current assignment; Owner/Admin may use any active inquiry. Rejects competing attempts and changes availability atomically.';
comment on function public.cancel_reservation(uuid) is
  'Owner/Admin cancel any active reservation. A seller cancels only a reservation they created while the linked inquiry is still assigned to them. Cancellation restores Available and retains history.';
