-- Additive visit-only readers. Existing reporting response contracts are unchanged.
create function public.get_visit_reporting_summary(p_kind text,p_start date,p_end date default null)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'UTC' as $$
declare bounds record; result jsonb;
begin
  if not public.is_owner_or_admin() then
    raise exception 'visit reporting access denied' using errcode='42501';
  end if;
  select * into bounds from public.reporting_period(p_kind,p_start,p_end);
  -- Grain: one request per visit, plus at most one current final result.
  -- Never join history or current inquiry responsibility for historical metrics.
  with events as (
    select 'requests'::text metric,v.vehicle_id,v.request_assignee_id staff_id
    from public.visits v where v.created_at>=bounds.start_at and v.created_at<bounds.end_at
    union all
    select v.status::text,v.vehicle_id,v.outcome_assignee_id
    from public.visits v where v.status in ('attended','cancelled','no_show')
      and v.scheduled_at>=bounds.start_at and v.scheduled_at<bounds.end_at
  ), totals as (
    select count(*) filter(where metric='requests') requests,
      count(*) filter(where metric='attended') attended,
      count(*) filter(where metric='cancelled') cancelled,
      count(*) filter(where metric='no_show') no_show from events
  ), vehicles as (
    select vehicle_id,count(*) filter(where metric='requests') requests,
      count(*) filter(where metric='attended') attended,
      count(*) filter(where metric='cancelled') cancelled,
      count(*) filter(where metric='no_show') no_show from events group by vehicle_id
  ), staff as (
    select staff_id,case when staff_id is null then 'unassigned' else 'known' end attribution,
      count(*) filter(where metric='requests') requests,
      count(*) filter(where metric='attended') attended,
      count(*) filter(where metric='cancelled') cancelled,
      count(*) filter(where metric='no_show') no_show from events group by staff_id
  ) select pg_catalog.jsonb_build_object(
    'period',pg_catalog.to_jsonb(bounds)||pg_catalog.jsonb_build_object('kind',p_kind),
    'totals',pg_catalog.to_jsonb(t),
    'by_vehicle',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(v) order by v.vehicle_id)
      from vehicles v),'[]'::jsonb),
    'by_staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(s) order by s.staff_id nulls last)
      from staff s),'[]'::jsonb)
  ) into result from totals t;
  return result;
end;
$$;
revoke all on function public.get_visit_reporting_summary(text,date,date) from public,anon,authenticated,service_role;
grant execute on function public.get_visit_reporting_summary(text,date,date) to authenticated;
comment on function public.get_visit_reporting_summary(text,date,date) is
  'Active Owner/Admin visit counts: global, concrete vehicle and historical responsible staff. Requests by creation, current final results by scheduled date; Buenos Aires periods. Null staff is unassigned, not the recording actor. No details, history rows or conversion ratios.';

create function public.get_my_visit_reporting_summary(p_kind text,p_start date,p_end date default null)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'UTC' as $$
declare viewer uuid; bounds record; result jsonb;
begin
  if not public.is_active_staff() then
    raise exception 'own visit reporting access denied' using errcode='42501';
  end if;
  viewer:=auth.uid();
  select * into bounds from public.reporting_period(p_kind,p_start,p_end);
  -- Scope every source independently. Do not filter an administrative response:
  -- historical attribution survives loss of detail access after reassignment.
  with own_events as (
    select 'requests'::text metric from public.visits v
    where v.request_assignee_id=viewer and v.created_at>=bounds.start_at and v.created_at<bounds.end_at
    union all
    select v.status::text from public.visits v
    where v.outcome_assignee_id=viewer and v.status in ('attended','cancelled','no_show')
      and v.scheduled_at>=bounds.start_at and v.scheduled_at<bounds.end_at
  ), figures as (
    select count(*) filter(where metric='requests') requests,
      count(*) filter(where metric='attended') attended,
      count(*) filter(where metric='cancelled') cancelled,
      count(*) filter(where metric='no_show') no_show from own_events
  ) select pg_catalog.jsonb_build_object(
    'period',pg_catalog.to_jsonb(bounds)||pg_catalog.jsonb_build_object('kind',p_kind),
    'figures',pg_catalog.to_jsonb(f),
    'scope',pg_catalog.jsonb_build_object('subject','self')
  ) into result from figures f;
  return result;
end;
$$;
revoke all on function public.get_my_visit_reporting_summary(text,date,date) from public,anon,authenticated,service_role;
grant execute on function public.get_my_visit_reporting_summary(text,date,date) to authenticated;
comment on function public.get_my_visit_reporting_summary(text,date,date) is
  'Active staff own visit aggregates by auth.uid(): request/first-outcome attribution, creation/scheduled periods, current final result only. No caller person selector, global totals, staff comparisons, vehicle IDs, views, ratios or details. Unassigned never falls back to the actor.';
