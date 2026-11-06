-- Rescheduling changes one pending appointment, never its creation or attribution.
create function public.reschedule_visit(
  p_visit_id uuid, p_scheduled_at timestamptz, p_agreed boolean
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  selected_visit public.visits%rowtype;
  next_status public.visit_status;
begin
  selected_visit := public.lock_managed_visit(p_visit_id);
  if selected_visit.status not in ('requested','confirmed') then
    raise exception 'only pending visits can be rescheduled' using errcode = '22023';
  end if;
  if p_agreed is null then
    raise exception 'visit agreement is required' using errcode = '22023';
  end if;
  perform public.require_visit_opening_time(p_scheduled_at);
  next_status := case when p_agreed then 'confirmed' else 'requested' end;
  -- Exact retries add no history; authorization and current time validation still apply.
  if selected_visit.scheduled_at = p_scheduled_at and selected_visit.status = next_status then
    return jsonb_build_object('visit_id', selected_visit.id);
  end if;
  update public.visits set scheduled_at = p_scheduled_at, status = next_status
    where id = selected_visit.id;
  insert into public.visit_history(visit_id,from_status,to_status,
    previous_scheduled_at,scheduled_at,actor_id,occurred_at)
    values(selected_visit.id,selected_visit.status,next_status,
      selected_visit.scheduled_at,p_scheduled_at,auth.uid(),clock_timestamp());
  return jsonb_build_object('visit_id', selected_visit.id);
end;
$$;
revoke all on function public.reschedule_visit(uuid,timestamptz,boolean)
  from public, anon, service_role;
grant execute on function public.reschedule_visit(uuid,timestamptz,boolean) to authenticated;
comment on function public.reschedule_visit(uuid,timestamptz,boolean) is
  'Current responsible active seller or Owner/Admin reschedules pending visits within current opening hours. Agreement confirms; proposal requests. Identity, purpose, creation intent and attribution survive. Exact valid retries are no-ops. READ COMMITTED required.';
