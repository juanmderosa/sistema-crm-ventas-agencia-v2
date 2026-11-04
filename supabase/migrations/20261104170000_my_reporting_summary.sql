create function public.get_my_reporting_summary(p_kind text,p_start date,p_end date default null)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'UTC' as $$
declare
  viewer uuid;
  bounds record;
  result jsonb;
begin
  if not public.is_active_staff() then
    raise exception 'own reporting access denied' using errcode='42501';
  end if;
  viewer:=auth.uid();
  select * into bounds from public.reporting_period(p_kind,p_start,p_end);
  -- Every branch is scoped at its source, not by filtering a global/admin JSON
  -- response. No caller-provided person selector or inquiry detail is exposed.
  with own_events as (
    select 'inquiries_first_assigned'::text metric,i.origin::text origin
    from public.inquiry_first_responsibilities r
    join public.inquiry_responsibility_tracking t on t.inquiry_id=r.inquiry_id and t.complete_from_creation
    join public.inquiries i on i.id=r.inquiry_id
    where r.responsible_id=viewer and r.first_observed_at>=bounds.start_at and r.first_observed_at<bounds.end_at
    union all
    select 'reservations_created',i.origin::text
    from public.reservations r join public.inquiries i on i.id=r.inquiry_id
    where r.created_by=viewer and r.started_at>=bounds.start_at and r.started_at<bounds.end_at
    union all
    select 'sale_reports',i.origin::text
    from public.sale_reviews r join public.inquiries i on i.id=r.inquiry_id
    where r.reported_by=viewer and r.reported_at>=bounds.start_at and r.reported_at<bounds.end_at
    union all
    select 'confirmed_sales',i.origin::text
    from public.confirmed_sales s join public.inquiries i on i.id=s.inquiry_id
    where s.responsible_id=viewer and s.confirmed_at>=bounds.start_at and s.confirmed_at<bounds.end_at
    union all
    select 'closures_without_sale',i.origin::text
    from public.inquiry_status_history h
    join public.inquiry_closure_attribution a on a.history_id=h.id and a.responsible_id=viewer
    join public.inquiries i on i.id=h.inquiry_id
    where h.to_status='closed_without_sale' and h.occurred_at>=bounds.start_at and h.occurred_at<bounds.end_at
  ), figures as (
    select count(*) filter(where metric='inquiries_first_assigned') inquiries_first_assigned,
      count(*) filter(where metric='reservations_created') reservations_created,
      count(*) filter(where metric='sale_reports') sale_reports,
      count(*) filter(where metric='confirmed_sales') confirmed_sales,
      count(*) filter(where metric='closures_without_sale') closures_without_sale from own_events
  ), origins as (
    select o.origin,count(*) filter(where e.metric='inquiries_first_assigned') inquiries_first_assigned,
      count(*) filter(where e.metric='reservations_created') reservations_created,
      count(*) filter(where e.metric='sale_reports') sale_reports,
      count(*) filter(where e.metric='confirmed_sales') confirmed_sales,
      count(*) filter(where e.metric='closures_without_sale') closures_without_sale
    from (values('web'),('in_person'),('phone')) o(origin)
    left join own_events e on e.origin=o.origin group by o.origin
  ) select pg_catalog.jsonb_build_object(
    'period',pg_catalog.to_jsonb(bounds)||pg_catalog.jsonb_build_object('kind',p_kind),
    'figures',pg_catalog.to_jsonb(f),
    'by_origin',(select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(o) order by o.origin) from origins o),
    'scope',pg_catalog.jsonb_build_object('subject','self','inquiry_history','complete_from_creation_only')
  ) into result from figures f;
  return result;
end;
$$;
revoke all on function public.get_my_reporting_summary(text,date,date) from public,anon,authenticated,service_role;
grant execute on function public.get_my_reporting_summary(text,date,date) to authenticated;
comment on function public.get_my_reporting_summary(text,date,date) is
  'Active staff own-only historical aggregates by auth.uid(), including former responsibilities without former inquiry details. No caller person selector, global totals/coverage, other staff, vehicle IDs, views, relations or raw data. Complete first-assignment histories only; reliable outcomes independent of inquiry-history completeness.';
