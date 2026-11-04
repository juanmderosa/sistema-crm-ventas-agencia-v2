begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','get_reporting_summary',array['text','date','date'],'Owner/Admin summary exists');
insert into auth.users(id,email)
select md5('summary-actor-'||n)::uuid,'summary-'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('summary-actor-'||n)::uuid,
 (case n when 1 then 'owner' when 2 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
 'Summary actor '||n,n<5 from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year,publication_status,availability_status)
select md5('summary-vehicle-'||n)::uuid,'Test','Summary',2040,'published',
 (case when n=3 then 'sold' else 'available' end)::public.vehicle_availability_status from generate_series(1,3)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('summary-contact')::uuid,'+5491187651234','Private contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name,origin,created_at)
select md5('summary-inquiry-'||n)::uuid,md5('summary-submit-'||n)::uuid,md5('summary-contact')::uuid,
 case when n=3 then null else md5('summary-vehicle-'||case when n in(4,6) then 2 else 1 end)::uuid end,
 case when n=3 then null else md5('summary-actor-'||case when n=4 then 5 else 3 end)::uuid end,
 '+5491187651234','Private submitted name',
 (case when n=3 then 'in_person' when n=4 then 'phone' else 'web' end)::public.inquiry_origin,
 case when n=1 then timestamptz '2040-02-01 03:00Z'
      when n=5 then timestamptz '2040-03-01 03:00Z'
      when n=6 then timestamptz '2040-02-01 02:59:59.999999Z'
      else timestamptz '2040-02-15 12:00Z' end from generate_series(1,6)n;
insert into public.inquiry_interests(inquiry_id,vehicle_id)
select md5('summary-inquiry-'||i)::uuid,md5('summary-vehicle-'||v)::uuid from generate_series(1,6)i cross join generate_series(1,3)v;
update public.inquiries set assignee_id=md5('summary-actor-4')::uuid where id=md5('summary-inquiry-1')::uuid;
update public.inquiry_first_responsibilities set first_observed_at='2040-02-15 12:00Z'
 where inquiry_id in(select id from public.inquiries where submitted_name='Private submitted name');
update public.inquiry_first_responsibilities set first_observed_at='2040-03-01 03:00Z'
 where inquiry_id=md5('summary-inquiry-5')::uuid;
update public.inquiry_responsibility_tracking set complete_from_creation=false where inquiry_id=md5('summary-inquiry-2')::uuid;
insert into public.vehicle_view_events(vehicle_id,counted_at)
select md5('summary-vehicle-'||v)::uuid,t from (values
 (1,timestamptz '2040-02-01 03:00Z'),(1,timestamptz '2040-02-10 12:00Z'),
 (1,timestamptz '2040-03-01 02:59:59.999999Z'),(2,timestamptz '2040-02-15 12:00Z'),
 (1,timestamptz '2040-02-01 02:59:59.999999Z'),(1,timestamptz '2040-03-01 03:00Z')) views(v,t);
insert into public.reservations(id,inquiry_id,vehicle_id,contact_id,created_by,status,started_at,ended_at,cancelled_by,completed_by)
select md5('summary-reservation-'||n)::uuid,md5('summary-inquiry-'||n)::uuid,
 md5('summary-vehicle-'||case when n=1 then 2 else 1 end)::uuid,md5('summary-contact')::uuid,
 md5('summary-actor-'||case when n=1 then 3 else 4 end)::uuid,
 (case when n=1 then 'cancelled' else 'completed' end)::public.reservation_status,
 '2040-02-15 12:00Z','2040-02-16 12:00Z',
 case when n=1 then md5('summary-actor-1')::uuid end,
 case when n=2 then md5('summary-actor-1')::uuid end from generate_series(1,2)n;
insert into public.sale_reviews(id,inquiry_id,vehicle_id,contact_id,reported_by,reported_at,status,resolved_by,resolved_at)
select md5('summary-review-'||n)::uuid,md5('summary-inquiry-'||n)::uuid,
 md5('summary-vehicle-'||case when n=1 then 2 else 1 end)::uuid,md5('summary-contact')::uuid,
 md5('summary-actor-4')::uuid,'2040-02-15 12:00Z',case when n=1 then 'confirmed' else 'pending' end,
 case when n=1 then md5('summary-actor-1')::uuid end,
 case when n=1 then timestamptz '2040-02-16 12:00Z' end from generate_series(1,2)n;
insert into public.confirmed_sales(review_id,vehicle_id,inquiry_id,contact_id,confirmed_by,responsible_id,confirmed_at)
values(md5('summary-review-1')::uuid,md5('summary-vehicle-2')::uuid,md5('summary-inquiry-1')::uuid,
 md5('summary-contact')::uuid,md5('summary-actor-1')::uuid,md5('summary-actor-3')::uuid,'2040-02-16 12:00Z');
insert into public.inquiry_status_history(id,inquiry_id,from_status,to_status,actor_id,occurred_at)
select md5('summary-closure-'||n)::uuid,md5('summary-inquiry-'||case when n=1 then 3 else 4 end)::uuid,
 'following_up','closed_without_sale',md5('summary-actor-1')::uuid,'2040-02-17 12:00Z' from generate_series(1,3)n;
delete from public.inquiry_closure_attribution where history_id=md5('summary-closure-3')::uuid;

create function pg_temp.summary(n int,kind text default 'month',start_date date default '2040-02-15',end_date date default null)
returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claim.sub',md5('summary-actor-'||n)::uuid::text,true);
 perform set_config('role','authenticated',true);
 result:=public.get_reporting_summary(kind,start_date,end_date);
 perform set_config('role','none',true);
 return result;
exception when others then perform set_config('role','none',true); raise;
end $$;
create function pg_temp.reporting_state() returns text language plpgsql as $$
declare tab record; value text:=''; rows text;
begin
 for tab in select tablename from pg_tables where schemaname='public' order by tablename loop
  execute format('select coalesce(string_agg(j::text,%L order by j::text),%L) from (select to_jsonb(t) j from public.%I t)s',
   '', '',tab.tablename) into rows;
  value:=value||tab.tablename||rows;
 end loop;
 return md5(value);
end $$;
create temp table summary_before as select pg_temp.reporting_state() value;
create temp table summary_result as select pg_temp.summary(1) value;
select is((value->'totals'),'{"views":4,"inquiries":4,"reservations":2,"sale_reports":2,"confirmed_sales":1,"closures_without_sale":3}'::jsonb,
 'exact event counts, no interest multiplication or Sold-inventory counting') from summary_result;
select is((value#>>'{web_relation,numerator}')::int,2,'web-only numerator') from summary_result;
select is((value#>>'{web_relation,denominator}')::int,4,'same-period view denominator') from summary_result;
select is((value#>>'{web_relation,value}')::numeric,0.5::numeric,'global relation') from summary_result;
select is(value#>>'{web_relation,interpretation}','relation_not_causality','explicit relation label') from summary_result;
select is((value#>>'{inquiry_history_coverage,complete}')::int,3,'complete history cohort') from summary_result;
select is((value#>>'{inquiry_history_coverage,incomplete}')::int,1,'incomplete inquiry still in global counts') from summary_result;
select is((select (x->>'inquiries')::int from summary_result,jsonb_array_elements(value->'by_origin') x where x->>'origin'='web'),2,'web inquiries');
select is((select (x->>'inquiries')::int from summary_result,jsonb_array_elements(value->'by_origin') x where x->>'origin'='in_person'),1,'manual inquiry without originating vehicle');
select is((select (x->>'inquiries')::int from summary_result,jsonb_array_elements(value->'by_origin') x where x->>'origin'='phone'),1,'phone inquiries');
select is((select (x->>'inquiries')::int from summary_result,jsonb_array_elements(value->'by_vehicle') x where x->>'vehicle_id' is null),1,'explicit no-vehicle bucket');
select is((select (x->>'reservations')::int from summary_result,jsonb_array_elements(value->'by_vehicle') x where x->>'vehicle_id'=md5('summary-vehicle-2')::uuid::text),1,
 'reservation belongs to actual vehicle, not originating vehicle');
select is((select (x->>'confirmed_sales')::int from summary_result,jsonb_array_elements(value->'by_vehicle') x where x->>'vehicle_id'=md5('summary-vehicle-2')::uuid::text),1,'sale actual vehicle');
select is((select (x#>>'{web_relation,value}')::numeric from summary_result,jsonb_array_elements(value->'by_vehicle') x
 where x->>'vehicle_id'=md5('summary-vehicle-1')::uuid::text),2::numeric/3,'vehicle web relation uses its own numerator and views');
select is((select (x->>'inquiries_first_assigned')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'staff_id'=md5('summary-actor-3')::uuid::text),2,
 'first-assignment period independent of creation period, legacy excluded');
select is((select (x->>'inquiries_first_assigned')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'staff_id'=md5('summary-actor-4')::uuid::text),1,
 'same inquiry belongs once to each distinct responsible');
select is((select (x->>'confirmed_sales')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'staff_id'=md5('summary-actor-3')::uuid::text),1,
 'sale responsible snapshot, not current assignee or confirming admin');
select is((select (x->>'sale_reports')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'staff_id'=md5('summary-actor-4')::uuid::text),2,'sale report performer');
select is((select (x->>'reservations_created')::int from summary_result,jsonb_array_elements(value->'by_staff') x
 where x->>'staff_id'=md5('summary-actor-3')::uuid::text),1,'reservation performer distinct from current assignee');
select is((select (x->>'closures_without_sale')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'staff_id'=md5('summary-actor-5')::uuid::text),1,'inactive responsible retains known outcome');
select is((select (x->>'closures_without_sale')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'attribution'='unknown'),1,'unknown closure distinct bucket');
select is((select (x->>'closures_without_sale')::int from summary_result,jsonb_array_elements(value->'by_staff') x where x->>'attribution'='unassigned'),1,'known unassigned closure distinct bucket');
select is(pg_temp.summary(2),(select value from summary_result),'Owner/Admin parity');
set local timezone='Pacific/Auckland';
select is(pg_temp.summary(1),(select value from summary_result),'caller timezone does not alter JSON contract');
set local timezone='UTC';
select is(pg_temp.summary(1,'custom','2040-02-01','2040-02-29')->'totals',(select value->'totals' from summary_result),'inclusive custom days equal calendar month');
select is(pg_temp.summary(1,'year','2041-01-01')->'totals',
 '{"views":0,"inquiries":0,"reservations":0,"sale_reports":0,"confirmed_sales":0,"closures_without_sale":0}'::jsonb,'empty period totals');
select is(pg_temp.summary(1,'year','2041-01-01')#>'{web_relation,value}','null'::jsonb,'zero denominator unavailable, not zero relation');
select is(pg_temp.summary(1,'year','2041-01-01')->'by_staff','[]'::jsonb,'empty staff data is an array');
select is((select value#>'{inquiry_history_coverage,staff_counts_nonadditive}' from summary_result),'true'::jsonb,
 'staff figures explicitly nonadditive');
select throws_ok(format('select pg_temp.summary(%s)',n),'42501','reporting access denied','seller/inactive/no-profile denied '||n)
 from generate_series(3,8)n;
select throws_ok($$select pg_temp.summary(1,'week')$$,'22023',null,'authorized invalid period rejected');
set local role anon;
select throws_ok($$select public.get_reporting_summary('month','2040-02-15',null)$$,'42501',null,'anon denied');
reset role;
set local role service_role;
select throws_ok($$select public.get_reporting_summary('month','2040-02-15',null)$$,'42501',null,'service has no direct reader grant');
reset role;
select ok((select value::text not like '%Private contact%' and value::text not like '%Private submitted name%'
 and value::text not like '%+5491187651234%' from summary_result),'no contact details or submitted snapshots');
select ok((select value::text !~ '"(inquiry_id|contact_id|browser_token|normalized_phone|submitted_name|submitted_email)"' from summary_result),
 'no raw inquiry/contact/browser identifiers');
select is(pg_temp.reporting_state(),(select value from summary_before),'authorized and rejected reads preserve all public data');
select * from finish();
rollback;
