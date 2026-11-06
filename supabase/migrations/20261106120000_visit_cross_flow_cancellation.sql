-- Parent operations already authorize and lock their inquiry/vehicle. These
-- hooks descend to visits only: never lock another vehicle, actor or inquiry.
create function public.cancel_pending_visits(
  p_inquiry_id uuid, p_vehicle_id uuid, p_reason text
) returns void language plpgsql set search_path = '' as $$
declare
  selected_visit public.visits%rowtype;
  responsible uuid;
  changed_at timestamptz;
begin
  for selected_visit in
    select v.* from public.visits v
    where (p_inquiry_id is null or v.inquiry_id = p_inquiry_id)
      and (p_vehicle_id is null or v.vehicle_id = p_vehicle_id)
      and v.status in ('requested','confirmed')
    order by v.id for update
  loop
    -- Read after any visit-row wait. No upward row lock is acquired here.
    select assignee_id into responsible from public.inquiries where id = selected_visit.inquiry_id;
    changed_at := clock_timestamp();
    update public.visits set status = 'cancelled',
      first_outcome_recorded_at = coalesce(first_outcome_recorded_at, changed_at),
      outcome_assignee_id = case when first_outcome_recorded_at is null
        then responsible else outcome_assignee_id end
      where id = selected_visit.id;
    insert into public.visit_history(visit_id,from_status,to_status,
      previous_scheduled_at,scheduled_at,actor_id,reason,occurred_at)
      values(selected_visit.id,selected_visit.status,'cancelled',
        selected_visit.scheduled_at,selected_visit.scheduled_at,auth.uid(),p_reason,changed_at);
  end loop;
end;
$$;
revoke all on function public.cancel_pending_visits(uuid,uuid,text)
  from public, anon, authenticated, service_role;

create function public.cancel_closed_inquiry_visits()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status
    and new.status in ('sale_reported','closed_without_sale') then
    perform public.cancel_pending_visits(new.id, null, 'Consulta cerrada');
  end if;
  return new;
end;
$$;
revoke all on function public.cancel_closed_inquiry_visits()
  from public, anon, authenticated, service_role;
create trigger inquiries_cancel_pending_visits after update of status on public.inquiries
  for each row execute function public.cancel_closed_inquiry_visits();

create function public.cancel_unavailable_vehicle_visits()
returns trigger language plpgsql security definer set search_path = '' as $$
declare reason text;
begin
  -- One event per affected visit, with deterministic precedence for combined
  -- administrative edits. Reserved and unrelated edits do not cancel visits.
  if new.deleted_at is not null and old.deleted_at is null then
    reason := 'Vehículo dado de baja';
  elsif new.availability_status = 'sold' and old.availability_status <> 'sold' then
    reason := 'Vehículo vendido';
  elsif not new.sale_enabled and old.sale_enabled then
    reason := 'Vehículo bloqueado';
  end if;
  if reason is not null then
    perform public.cancel_pending_visits(null, new.id, reason);
  end if;
  return new;
end;
$$;
revoke all on function public.cancel_unavailable_vehicle_visits()
  from public, anon, authenticated, service_role;
create trigger vehicles_cancel_pending_visits
  after update of deleted_at, availability_status, sale_enabled on public.vehicles
  for each row execute function public.cancel_unavailable_vehicle_visits();
comment on function public.cancel_pending_visits(uuid,uuid,text) is
  'Private parent-trigger helper; visit-only locks ordered by ID, no upward locks. READ COMMITTED required. First-result attribution and immutable visit intent survive.';
