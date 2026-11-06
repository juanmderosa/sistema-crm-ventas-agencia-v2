-- State-only management preserves appointment and immutable creation intent.
create function public.lock_managed_visit(p_visit_id uuid)
returns public.visits language plpgsql set search_path = '' as $$
declare
  selected_visit public.visits%rowtype;
  selected_inquiry public.inquiries%rowtype;
  actor public.profiles%rowtype;
begin
  if not public.is_active_staff() then
    raise exception 'visit access denied' using errcode = '42501';
  end if;
  select * into selected_visit from public.visits where id = p_visit_id;
  if not found then
    raise exception 'visit access denied' using errcode = '42501';
  end if;
  -- Match creation/commercial lock order; inquiry serializes all its vehicles.
  perform 1 from public.vehicles where id = selected_visit.vehicle_id for update;
  select * into actor from public.profiles where id = auth.uid() for share;
  select * into selected_inquiry from public.inquiries where id = selected_visit.inquiry_id for update;
  select * into selected_visit from public.visits where id = p_visit_id for update;
  if actor.id is null or not actor.is_active or actor.role not in ('owner','admin','seller')
    or selected_inquiry.id is null or selected_visit.id is null
    or (actor.role = 'seller' and selected_inquiry.assignee_id is distinct from actor.id) then
    raise exception 'visit access denied' using errcode = '42501';
  end if;
  return selected_visit;
end;
$$;
revoke all on function public.lock_managed_visit(uuid) from public, anon, authenticated, service_role;

create function public.set_visit_status(
  p_visit_id uuid, p_status public.visit_status, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  selected_visit public.visits%rowtype;
  selected_inquiry public.inquiries%rowtype;
  selected_vehicle public.vehicles%rowtype;
  is_correction boolean;
  is_final boolean;
  changed_at timestamptz;
begin
  selected_visit := public.lock_managed_visit(p_visit_id);
  if p_status is null then
    raise exception 'invalid visit transition' using errcode = '22023';
  end if;
  -- Authorization and locks precede no-op retries, including final states.
  if selected_visit.status = p_status then
    return jsonb_build_object('visit_id', selected_visit.id);
  end if;
  is_correction := selected_visit.status in ('attended','cancelled','no_show');
  is_final := p_status in ('attended','cancelled','no_show');
  if is_correction then
    if p_reason is null or btrim(p_reason) = '' then
      raise exception 'correction reason is required' using errcode = '22023';
    end if;
  elsif not ((selected_visit.status = 'requested' and p_status in ('confirmed','cancelled'))
    or (selected_visit.status = 'confirmed' and is_final)) then
    raise exception 'invalid visit transition' using errcode = '22023';
  end if;
  if not is_correction and p_status in ('attended','no_show')
    and selected_visit.scheduled_at > clock_timestamp() then
    raise exception 'visit time has not been reached' using errcode = '22023';
  end if;
  select * into selected_inquiry from public.inquiries where id = selected_visit.inquiry_id;
  if is_correction and not is_final then
    if selected_inquiry.status not in ('new','contacted','following_up') then
      raise exception 'inquiry is not active' using errcode = '22023';
    end if;
    select * into selected_vehicle from public.vehicles where id = selected_visit.vehicle_id;
    if selected_vehicle.deleted_at is not null or not selected_vehicle.sale_enabled
      or selected_vehicle.availability_status = 'sold' then
      raise exception 'vehicle does not accept visits' using errcode = '22023';
    end if;
    if exists (select 1 from public.visits where inquiry_id = selected_visit.inquiry_id
      and id <> selected_visit.id and status in ('requested','confirmed')) then
      raise exception 'inquiry already has a pending visit' using errcode = '22023';
    end if;
  end if;
  -- Existing appointments survive opening-hour changes, including past restoration.
  changed_at := clock_timestamp();
  update public.visits set status = p_status,
    first_outcome_recorded_at = case when is_final and first_outcome_recorded_at is null
      then changed_at else first_outcome_recorded_at end,
    outcome_assignee_id = case when is_final and first_outcome_recorded_at is null
      then selected_inquiry.assignee_id else outcome_assignee_id end
    where id = selected_visit.id;
  insert into public.visit_history(visit_id,from_status,to_status,previous_scheduled_at,
    scheduled_at,actor_id,reason,occurred_at)
    values(selected_visit.id,selected_visit.status,p_status,selected_visit.scheduled_at,
      selected_visit.scheduled_at,auth.uid(),p_reason,changed_at);
  return jsonb_build_object('visit_id', selected_visit.id);
end;
$$;
revoke all on function public.set_visit_status(uuid,public.visit_status,text) from public, anon, service_role;
grant execute on function public.set_visit_status(uuid,public.visit_status,text) to authenticated;
comment on function public.set_visit_status(uuid,public.visit_status,text) is
  'Current responsible active seller or Owner/Admin manages visit state. Final-state corrections require reason; first-outcome attribution and creation intent survive. Authorized same-state calls are no-ops. No rescheduling or cross-flow effects. READ COMMITTED required.';
