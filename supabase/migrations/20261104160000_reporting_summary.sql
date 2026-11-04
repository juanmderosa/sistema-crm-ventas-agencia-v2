create function public.get_reporting_summary(p_kind text,p_start date,p_end date default null)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'UTC' as $$
declare
  bounds record;
  result jsonb;
begin
  -- Authorize before input validation or any business-data access.
  if not public.is_owner_or_admin() then
    raise exception 'reporting access denied' using errcode='42501';
  end if;
  select * into bounds from public.reporting_period(p_kind,p_start,p_end);
  with inquiries as (
    select i.id,i.origin,i.originating_vehicle_id,coalesce(t.complete_from_creation,false) as complete_history
    from public.inquiries i left join public.inquiry_responsibility_tracking t on t.inquiry_id=i.id
    where i.created_at>=bounds.start_at and i.created_at<bounds.end_at
  ), events as (
    -- Keep the counting grain at one source event. Never join inquiry interests.
    select 'views'::text metric,e.vehicle_id,null::text origin,null::uuid staff_id,'none'::text attribution
      from public.vehicle_view_events e where e.counted_at>=bounds.start_at and e.counted_at<bounds.end_at
    union all
    select 'inquiries',i.originating_vehicle_id,i.origin::text,null,'none' from inquiries i
    union all
    select 'reservations',r.vehicle_id,i.origin::text,r.created_by,'known'
      from public.reservations r join public.inquiries i on i.id=r.inquiry_id
      where r.started_at>=bounds.start_at and r.started_at<bounds.end_at
    union all
    select 'sale_reports',r.vehicle_id,i.origin::text,r.reported_by,'known'
      from public.sale_reviews r join public.inquiries i on i.id=r.inquiry_id
      where r.reported_at>=bounds.start_at and r.reported_at<bounds.end_at
    union all
    select 'confirmed_sales',s.vehicle_id,i.origin::text,s.responsible_id,
      case when s.responsible_id is null then 'unassigned' else 'known' end
      from public.confirmed_sales s join public.inquiries i on i.id=s.inquiry_id
      where s.confirmed_at>=bounds.start_at and s.confirmed_at<bounds.end_at
    union all
    -- Closures are inquiry outcomes, not a fabricated specific-vehicle sale.
    select 'closures_without_sale',null,i.origin::text,a.responsible_id,
      case when a.history_id is null then 'unknown' when a.responsible_id is null then 'unassigned' else 'known' end
      from public.inquiry_status_history h join public.inquiries i on i.id=h.inquiry_id
      left join public.inquiry_closure_attribution a on a.history_id=h.id
      where h.to_status='closed_without_sale' and h.occurred_at>=bounds.start_at and h.occurred_at<bounds.end_at
  ), totals as (
    select count(*) filter(where metric='views') views,
      count(*) filter(where metric='inquiries') inquiries,
      count(*) filter(where metric='reservations') reservations,
      count(*) filter(where metric='sale_reports') sale_reports,
      count(*) filter(where metric='confirmed_sales') confirmed_sales,
      count(*) filter(where metric='closures_without_sale') closures_without_sale,
      count(*) filter(where metric='inquiries' and origin='web') web_inquiries from events
  ), origins as (
    select o.origin,count(*) filter(where e.metric='inquiries') inquiries,
      count(*) filter(where e.metric='reservations') reservations,
      count(*) filter(where e.metric='sale_reports') sale_reports,
      count(*) filter(where e.metric='confirmed_sales') confirmed_sales,
      count(*) filter(where e.metric='closures_without_sale') closures_without_sale
    from (values('web'),('in_person'),('phone')) o(origin)
    left join events e on e.origin=o.origin group by o.origin
  ), vehicles as (
    select vehicle_id,count(*) filter(where metric='views') views,
      count(*) filter(where metric='inquiries') inquiries,
      count(*) filter(where metric='inquiries' and origin='web') web_inquiries,
      count(*) filter(where metric='reservations') reservations,
      count(*) filter(where metric='confirmed_sales') confirmed_sales
    from events where metric in ('views','inquiries','reservations','confirmed_sales') group by vehicle_id
  ), staff_events as (
    select metric,staff_id,attribution from events where attribution<>'none'
    union all
    select 'inquiries_first_assigned',r.responsible_id,'known'
    from public.inquiry_first_responsibilities r
    join public.inquiry_responsibility_tracking t on t.inquiry_id=r.inquiry_id and t.complete_from_creation
    where r.first_observed_at>=bounds.start_at and r.first_observed_at<bounds.end_at
  ), staff as (
    select staff_id,attribution,
      count(*) filter(where metric='inquiries_first_assigned') inquiries_first_assigned,
      count(*) filter(where metric='reservations') reservations_created,
      count(*) filter(where metric='sale_reports') sale_reports,
      count(*) filter(where metric='confirmed_sales') confirmed_sales,
      count(*) filter(where metric='closures_without_sale') closures_without_sale
    from staff_events group by staff_id,attribution
  ) select pg_catalog.jsonb_build_object(
    'period',pg_catalog.to_jsonb(bounds)||pg_catalog.jsonb_build_object('kind',p_kind),
    'totals',pg_catalog.to_jsonb(t)-'web_inquiries',
    'web_relation',pg_catalog.jsonb_build_object('numerator',t.web_inquiries,'denominator',t.views,
      'value',t.web_inquiries::numeric/nullif(t.views,0),'interpretation','relation_not_causality'),
    'by_origin',(select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(o) order by o.origin) from origins o),
    'by_vehicle',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(v)||pg_catalog.jsonb_build_object(
      'web_relation',pg_catalog.jsonb_build_object('numerator',v.web_inquiries,'denominator',v.views,
        'value',case when v.vehicle_id is not null then v.web_inquiries::numeric/nullif(v.views,0) end,
        'interpretation','relation_not_causality')) order by v.vehicle_id nulls last) from vehicles v),'[]'::jsonb),
    'by_staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(s) order by s.staff_id nulls last,s.attribution)
      from staff s),'[]'::jsonb),
    'inquiry_history_coverage',pg_catalog.jsonb_build_object('basis','inquiries_created_in_period',
      'complete',(select count(*) from inquiries where complete_history),
      'incomplete',(select count(*) from inquiries where not complete_history),
      'staff_first_assignment_excludes_incomplete',true,'staff_counts_nonadditive',true)
  ) into result from totals t;
  return result;
end;
$$;
revoke all on function public.get_reporting_summary(text,date,date) from public,anon,authenticated,service_role;
grant execute on function public.get_reporting_summary(text,date,date) to authenticated;
comment on function public.get_reporting_summary(text,date,date) is
  'Active Owner/Admin only: read-only period-scoped global/origin/vehicle/staff figures, web relations and explicit history coverage. No contact, inquiry-detail, browser-token or raw-history output. Staff first-assignment counts are nonadditive and exclude incomplete histories. Seller reader is a separate contract.';
