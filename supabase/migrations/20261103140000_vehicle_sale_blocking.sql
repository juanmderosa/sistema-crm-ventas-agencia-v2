-- Internal blocking is a sales decision, not a commercial reservation. It never
-- cancels a reservation and never changes publication or availability, so the
-- public catalog and the private history stay distinguishable.
drop policy vehicles_select_public_or_staff on public.vehicles;
create policy vehicles_select_public_or_staff
on public.vehicles
for select
to anon, authenticated
using (
  (publication_status = 'published' and deleted_at is null and sale_enabled)
  or public.is_active_staff()
);

-- Blocking must be refused while a reservation is active, including through the
-- generic Owner/Admin inventory update that already exists.
create or replace function public.guard_reserved_vehicle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.reservations r
    where r.vehicle_id = old.id and r.status = 'active'
  ) then
    if new.sale_enabled is distinct from old.sale_enabled and new.sale_enabled is false then
      raise exception 'cancel the active reservation before blocking the vehicle'
        using errcode = '22023';
    end if;
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

create function public.set_vehicle_sale_blocked(p_vehicle_id uuid, p_blocked boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.vehicles%rowtype;
  result boolean;
begin
  -- Match the reservation lock order (vehicle, actor) so the two operations
  -- cannot deadlock. Locking a row discloses nothing; the message does.
  select * into selected from public.vehicles
  where id = p_vehicle_id for update;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_owner_or_admin() then
    raise exception 'vehicle sale access denied' using errcode = '42501';
  end if;
  if p_blocked is null then
    raise exception 'invalid vehicle sale input' using errcode = '22023';
  end if;
  if selected.id is null or selected.deleted_at is not null then
    raise exception 'vehicle not found or deleted' using errcode = '22023';
  end if;

  -- The guard trigger enforces the active-reservation rejection for every path,
  -- including direct inventory updates, with the same message.
  update public.vehicles set sale_enabled = not p_blocked
  where id = p_vehicle_id
  returning sale_enabled into result;

  return pg_catalog.jsonb_build_object('vehicle_id', p_vehicle_id, 'sale_enabled', result);
end;
$$;
revoke all on function public.set_vehicle_sale_blocked(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.set_vehicle_sale_blocked(uuid, boolean) to authenticated;

comment on function public.set_vehicle_sale_blocked(uuid, boolean) is
  'Owner/Admin block or enable vehicle sale. Blocking is separate from a reservation, is rejected while an active reservation exists, leaves publication and availability untouched, removes the vehicle from the public catalog and keeps private history.';
