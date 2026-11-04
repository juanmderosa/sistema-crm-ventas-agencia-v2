begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','get_my_reporting_summary',array['text','date','date'],'own-only summary exists');
insert into auth.users(id,email)
select md5('my-summary-actor-'||n)::uuid,'my-summary-'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('my-summary-actor-'||n)::uuid,
 (case n when 1 then 'owner' when 2 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
 'My summary actor '||n,n<5 from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year,publication_status)
select md5('my-summary-vehicle-'||n)::uuid,'Test','My summary',2040,'published' from generate_series(1,2)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('my-summary-contact')::uuid,'+5491187655678','Never expose this contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name,origin,created_at)
select md5('my-summary-inquiry-'||n)::uuid,md5('my-summary-submit-'||n)::uuid,md5('my-summary-contact')::uuid,
 case when n=3 then null else md5('my-summary-vehicle-1')::uuid end,
 case when n=3 then null else md5('my-summary-actor-'||case when n=4 then 4 else 3 end)::uuid end,
 '+5491187655678','Never expose this submission',
 (case n when 1 then 'web' when 2 then 'phone' else 'in_person' end)::public.inquiry_origin,'2040-01-10 12:00Z'
from generate_series(1,4)n;
update public.inquiries set assignee_id=md5('my-summary-actor-4')::uuid where id=md5('my-summary-inquiry-1')::uuid;
update public.inquiry_first_responsibilities set first_observed_at='2040-02-01 03:00Z'
 where inquiry_id in(select id from public.inquiries where submitted_name='Never expose this submission');
update public.inquiry_responsibility_tracking set complete_from_creation=false where inquiry_id=md5('my-summary-inquiry-2')::uuid;
insert into public.reservations(id,inquiry_id,vehicle_id,contact_id,created_by,status,started_at,ended_at,cancelled_by)
select md5('my-summary-reservation-'||n)::uuid,md5('my-summary-inquiry-'||n)::uuid,md5('my-summary-vehicle-2')::uuid,
 md5('my-summary-contact')::uuid,md5('my-summary-actor-3')::uuid,'cancelled',
 case when n=1 then timestamptz '2040-02-15 12:00Z' else timestamptz '2040-03-01 03:00Z' end,
 '2040-03-02 12:00Z',md5('my-summary-actor-1')::uuid from generate_series(1,2)n;
insert into public.sale_reviews(id,inquiry_id,vehicle_id,contact_id,reported_by,reported_at,status,resolved_by,resolved_at)
select md5('my-summary-review-'||n)::uuid,md5('my-summary-inquiry-'||n)::uuid,md5('my-summary-vehicle-'||case when n=1 then 2 else 1 end)::uuid,
 md5('my-summary-contact')::uuid,md5('my-summary-actor-'||case when n=1 then 3 else 4 end)::uuid,'2040-02-15 12:00Z',
 case when n=1 then 'confirmed' else 'pending' end,
 case when n=1 then md5('my-summary-actor-1')::uuid end,
 case when n=1 then timestamptz '2040-02-16 12:00Z' end from generate_series(1,2)n;
insert into public.confirmed_sales(review_id,vehicle_id,inquiry_id,contact_id,confirmed_by,responsible_id,confirmed_at)
values(md5('my-summary-review-1')::uuid,md5('my-summary-vehicle-2')::uuid,md5('my-summary-inquiry-1')::uuid,
 md5('my-summary-contact')::uuid,md5('my-summary-actor-1')::uuid,md5('my-summary-actor-3')::uuid,'2040-02-16 12:00Z');
insert into public.inquiry_status_history(id,inquiry_id,from_status,to_status,actor_id,occurred_at)
select md5('my-summary-closure-'||n)::uuid,md5('my-summary-inquiry-'||case when n=3 then 2 when n=4 then 3 else 1 end)::uuid,
 'following_up','closed_without_sale',md5('my-summary-actor-1')::uuid,
 case when n=5 then timestamptz '2040-03-01 03:00Z' else timestamptz '2040-02-17 12:00Z' end from generate_series(1,5)n;
update public.inquiry_closure_attribution set responsible_id=md5('my-summary-actor-3')::uuid
 where history_id in(select md5('my-summary-closure-'||n)::uuid from (values(1),(2),(5)) x(n));
delete from public.inquiry_closure_attribution where history_id=md5('my-summary-closure-3')::uuid;
insert into public.vehicle_view_events(vehicle_id,counted_at) values(md5('my-summary-vehicle-1')::uuid,'2040-02-15 12:00Z');

create function pg_temp.mine(n int,kind text default 'month',start_date date default '2040-02-15',end_date date default null)
returns jsonb language plpgsql as $$
declare result jsonb;
begin
 perform set_config('request.jwt.claim.sub',md5('my-summary-actor-'||n)::uuid::text,true);
 perform set_config('role','authenticated',true);
 result:=public.get_my_reporting_summary(kind,start_date,end_date);
 perform set_config('role','none',true);
 return result;
exception when others then perform set_config('role','none',true); raise;
end $$;
create temp table own_summary as select pg_temp.mine(3) value;
select is(value->'figures','{"inquiries_first_assigned":1,"reservations_created":1,"sale_reports":1,"confirmed_sales":1,"closures_without_sale":2}'::jsonb,
 'only self-attributed events, retained after reassignment, exact end excluded') from own_summary;
select is(value#>>'{scope,subject}','self','explicit self scope') from own_summary;
select is(value#>>'{scope,inquiry_history}','complete_from_creation_only','scope restriction disclosed without global totals') from own_summary;
select is((select (x->>'inquiries_first_assigned')::int from own_summary,jsonb_array_elements(value->'by_origin') x where x->>'origin'='web'),1,'own web first assignment');
select is((select (x->>'inquiries_first_assigned')::int from own_summary,jsonb_array_elements(value->'by_origin') x where x->>'origin'='phone'),0,'incomplete inquiry excluded from own inquiry metric');
select is(pg_temp.mine(1)->'figures','{"inquiries_first_assigned":0,"reservations_created":0,"sale_reports":0,"confirmed_sales":0,"closures_without_sale":0}'::jsonb,
 'confirming/closure-recording administrator does not own the commercial result');
select is((pg_temp.mine(4)#>>'{figures,inquiries_first_assigned}')::int,2,'second seller sees only their own first assignments');
select is((pg_temp.mine(4)#>>'{figures,sale_reports}')::int,1,'second seller own report');
select is((pg_temp.mine(4)#>>'{figures,confirmed_sales}')::int,0,'current responsibility does not transfer confirmed sale');
select is(pg_temp.mine(3,'custom','2040-02-01','2040-02-29'),(select value||jsonb_build_object('period',
 (value->'period')||jsonb_build_object('kind','custom')) from own_summary),'inclusive custom matches own month');
set local timezone='Pacific/Auckland';
select is(pg_temp.mine(3),(select value from own_summary),'own response independent of caller timezone');
set local timezone='UTC';
select is((pg_temp.mine(3,'month','2040-01-15')#>>'{figures,inquiries_first_assigned}')::int,0,
 'first assignment period, not creation period');
select is(pg_temp.mine(3,'year','2041-01-01')->'figures',
 '{"inquiries_first_assigned":0,"reservations_created":0,"sale_reports":0,"confirmed_sales":0,"closures_without_sale":0}'::jsonb,'empty own period');

set local role authenticated;
select set_config('request.jwt.claim.sub',md5('my-summary-actor-3')::uuid::text,true);
select is((select count(*) from public.inquiries where id=md5('my-summary-inquiry-1')::uuid),0::bigint,
 'former seller retains figures but cannot read former inquiry');
select throws_ok($$select public.get_reporting_summary('month','2040-02-15',null)$$,'42501','reporting access denied','seller still cannot call administrative summary');
select throws_ok($$select * from public.inquiry_first_responsibilities$$,'42501',null,'raw attribution rows remain private');
reset role;
select throws_ok(format('select pg_temp.mine(%s)',n),'42501','own reporting access denied','inactive/no-profile denied '||n) from generate_series(5,8)n;
select throws_ok($$select pg_temp.mine(8,'invalid',null,null)$$,'42501','own reporting access denied','authorization before invalid inputs');
select throws_ok($$select pg_temp.mine(3,'invalid')$$,'22023',null,'valid seller receives explicit invalid-period error');
set local role anon;
select throws_ok($$select public.get_my_reporting_summary('month','2040-02-15',null)$$,'42501',null,'anon denied own reader');
reset role;
set local role service_role;
select throws_ok($$select public.get_my_reporting_summary('month','2040-02-15',null)$$,'42501',null,'service denied own reader');
reset role;
select results_eq($$select jsonb_object_keys(value) from own_summary order by 1$$,
 $$select unnest(array['by_origin','figures','period','scope'])$$,'closed top-level contract, no global or vehicle sections');
select ok((select value::text !~ '"(inquiry_id|contact_id|browser_token|vehicle_id|staff_id|views|totals|web_relation|by_staff|by_vehicle|inquiry_history_coverage)"'
 and value::text not like '%Never expose%' and value::text not like '%+5491187655678%' from own_summary),
 'no global, other-person, vehicle or private-detail fields');
select * from finish();
rollback;
