begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','get_visit_reporting_summary',array['text','date','date'],'global visit reader exists');
select has_function('public','get_my_visit_reporting_summary',array['text','date','date'],'own visit reader exists');
insert into auth.users(id,email)
select md5('visit-report-actor-'||n)::uuid,'visit-report-'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('visit-report-actor-'||n)::uuid,
 (case n when 1 then 'owner' when 2 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
 'Visit report actor '||n,n<5 from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year)
select md5('visit-report-vehicle-'||n)::uuid,'Test','Visit metrics',2020 from generate_series(1,2)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('visit-report-contact')::uuid,'+5491188880034','Private contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name)
values(md5('visit-report-inquiry')::uuid,md5('visit-report-submit')::uuid,md5('visit-report-contact')::uuid,
 md5('visit-report-vehicle-1')::uuid,md5('visit-report-actor-4')::uuid,'+5491188880034','Private submission');
insert into public.inquiry_interests(inquiry_id,vehicle_id)
select md5('visit-report-inquiry')::uuid,md5('visit-report-vehicle-'||n)::uuid from generate_series(1,2)n;
insert into public.visits(id,inquiry_id,vehicle_id,status,created_at,scheduled_at,request_assignee_id,
 first_outcome_recorded_at,outcome_assignee_id,purpose)
select md5('visit-report-'||n)::uuid,md5('visit-report-inquiry')::uuid,
 md5('visit-report-vehicle-'||case when n in(1,3,6,8) then 2 else 1 end)::uuid,
 (case n when 1 then 'no_show' when 3 then 'cancelled' when 5 then 'cancelled' when 6 then 'no_show'
   when 8 then 'requested' else 'attended' end)::public.visit_status,
 case when n=1 then timestamptz '2020-02-01 02:59:59Z' when n in(5,7) then timestamptz '2020-03-01 03:00Z'
   when n=6 then timestamptz '2020-03-01 02:59:59Z' else timestamptz '2020-02-15 12:00Z' end,
 case when n=1 then timestamptz '2020-02-01 03:00Z' when n=5 then timestamptz '2020-02-01 02:59:59Z'
   when n in(2,6,7) then timestamptz '2020-03-01 03:00Z' when n=4 then timestamptz '2020-03-01 02:59:59Z'
   else timestamptz '2020-02-15 12:00Z' end,
 case when n<>3 then md5('visit-report-actor-'||case when n in(4,5,8) then 4 else 3 end)::uuid end,
 case when n<>8 then timestamptz '2021-01-01 12:00Z' end,
 case when n not in(3,8) then md5('visit-report-actor-'||case when n in(1,5) then 4 else 3 end)::uuid end,
 'Private purpose' from generate_series(1,8)n;
-- A history fanout must not multiply source visits or their current result.
insert into public.visit_history(visit_id,from_status,to_status,actor_id,reason)
select md5('visit-report-1')::uuid,'cancelled','no_show',md5('visit-report-actor-1')::uuid,'Private correction'
from generate_series(1,3);
set local role authenticated;
set local request.jwt.claim.sub='';
select throws_ok($$select public.get_visit_reporting_summary(null,null)$$,'42501','visit reporting access denied','missing identity rejected before validation');
select throws_ok($$select public.get_my_visit_reporting_summary(null,null)$$,'42501','own visit reporting access denied','own reader rejects missing identity first');
set local request.jwt.claim.sub= '00000000-0000-0000-0000-000000000034';
select throws_ok($$select public.get_my_visit_reporting_summary('month','2020-02-01')$$,'42501',null,'unknown profile denied');
reset role;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-1')::uuid::text,true);
set local role authenticated;
select is(public.get_visit_reporting_summary('month','2020-02-20')->'totals',
 '{"requests":5,"attended":1,"cancelled":1,"no_show":1}'::jsonb,'creation/scheduled local boundaries, one visit and one current result');
select is(public.get_visit_reporting_summary('month','2020-02-20')->'period'->>'timezone_name',
 'America/Argentina/Buenos_Aires','fixed business timezone');
select is((select x->>'requests' from jsonb_array_elements(public.get_visit_reporting_summary('month','2020-02-20')->'by_vehicle')x
 where x->>'vehicle_id'=md5('visit-report-vehicle-2')::uuid::text),'3','concrete visit vehicle, not originating inquiry vehicle');
select is((select x-'staff_id' from jsonb_array_elements(public.get_visit_reporting_summary('month','2020-02-20')->'by_staff')x
 where x->>'attribution'='unassigned'),'{"attribution":"unassigned","requests":1,"attended":0,"cancelled":1,"no_show":0}'::jsonb,'unassigned requests/outcomes not credited to recording admin');
select is(public.get_visit_reporting_summary('custom','2020-02-01','2020-02-29')->'totals',
 public.get_visit_reporting_summary('month','2020-02-20')->'totals','inclusive custom day range equals month');
select is(public.get_visit_reporting_summary('month','2020-04-01')->'totals',
 '{"requests":0,"attended":0,"cancelled":0,"no_show":0}'::jsonb,'empty totals are explicit zeros');
select is(public.get_visit_reporting_summary('month','2020-04-01')->'by_staff','[]'::jsonb,'empty staff groups');
select is(public.get_visit_reporting_summary('month','2020-04-01')->'by_vehicle','[]'::jsonb,'empty vehicle groups');
select is(public.get_visit_reporting_summary('quarter','2020-02-01')->'totals'->>'requests','8','quarter counts visits once');
select is(public.get_visit_reporting_summary('semester','2020-02-01')->'totals'->>'requests','8','semester delegated to calendar helper');
select is(public.get_visit_reporting_summary('year','2020-02-01')->'totals'->>'requests','8','year delegated to calendar helper');
select throws_ok($$select public.get_visit_reporting_summary('month','infinity')$$,'22023',null,'nonfinite anchor rejected');
select throws_ok($$select public.get_visit_reporting_summary('custom','2020-02-02','2020-02-01')$$,'22023',null,'reversed custom rejected');
select throws_ok($$select public.get_visit_reporting_summary('month','2020-02-01','2020-02-02')$$,'22023',null,'calendar end rejected');
select throws_ok($$select public.get_my_visit_reporting_summary('invalid','2020-02-01')$$,'22023',null,'own reader reuses period validation');
reset role;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-2')::uuid::text,true);
set local role authenticated;
select lives_ok($$select public.get_visit_reporting_summary('month','2020-02-01')$$,'active admin global access');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures',
 '{"requests":0,"attended":0,"cancelled":0,"no_show":0}'::jsonb,'admin own view does not inherit global totals');
reset role;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-3')::uuid::text,true);
set local role authenticated;
select throws_ok($$select public.get_visit_reporting_summary('month','2020-02-01')$$,'42501','visit reporting access denied','seller cannot get agency figures');
select is((select count(*)::int from public.visits where inquiry_id=md5('visit-report-inquiry')::uuid),0,'former assignee has no visit detail');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures',
 '{"requests":2,"attended":1,"cancelled":0,"no_show":0}'::jsonb,'historical own request/result attribution survives reassignment');
select is((select array_agg(k order by k) from jsonb_object_keys(public.get_my_visit_reporting_summary('month','2020-02-01'))k),
 array['figures','period','scope'],'own payload has no global, staff, vehicle or detail keys');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'scope','{"subject":"self"}'::jsonb,'own identity has no caller selector');
reset role;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-4')::uuid::text,true);
set local role authenticated;
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures',
 '{"requests":2,"attended":0,"cancelled":0,"no_show":1}'::jsonb,'current seller does not inherit former attribution');
-- Real lifecycle operations change the aggregate, not the source visit grain.
select public.set_visit_status(md5('visit-report-1')::uuid,'attended','Correct result');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures'->>'no_show','0','correction removes prior result');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures'->>'attended','1','correction adds current result in scheduled period');
select public.set_visit_status(md5('visit-report-8')::uuid,'cancelled');
select public.set_visit_status(md5('visit-report-1')::uuid,'confirmed','Restore');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures'->>'attended','0','pending restoration removes final result');
select public.set_visit_status(md5('visit-report-1')::uuid,'no_show');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures'->>'no_show','1','refinalization retains first result responsibility');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures'->>'requests','2','correction/restoration do not create requests');
reset role;
update public.inquiries set assignee_id=md5('visit-report-actor-3')::uuid where id=md5('visit-report-inquiry')::uuid;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-1')::uuid::text,true);
set local role authenticated;
select public.set_visit_status(md5('visit-report-1')::uuid,'confirmed','Restore after reassignment');
select public.set_visit_status(md5('visit-report-1')::uuid,'no_show');
select is((select x->>'no_show' from jsonb_array_elements(public.get_visit_reporting_summary('month','2020-02-01')->'by_staff')x
 where x->>'staff_id'=md5('visit-report-actor-4')::uuid::text),'1','refinalization after reassignment keeps first attribution, not actor/current owner');
select public.set_visit_status(md5('visit-report-8')::uuid,'confirmed','Restore for rescheduling');
select public.set_dealership_opening_hours((select jsonb_agg(jsonb_build_object('weekday',n,'opens_at','00:00','closes_at','24:00')) from generate_series(0,6)n));
select public.reschedule_visit(md5('visit-report-8')::uuid,clock_timestamp()+interval '7 days',true);
select is(public.get_visit_reporting_summary('month','2020-02-01')->'totals',
 '{"requests":5,"attended":1,"cancelled":1,"no_show":1}'::jsonb,'reschedule keeps original request and pending visit has no final result');
reset role;
update public.profiles set is_active=false where id=md5('visit-report-actor-3')::uuid;
set local role authenticated;
select is((select x->>'requests' from jsonb_array_elements(public.get_visit_reporting_summary('month','2020-02-01')->'by_staff')x
 where x->>'staff_id'=md5('visit-report-actor-3')::uuid::text),'2','deactivated responsible remains in historical admin figures');
reset role;
update public.profiles set is_active=true where id=md5('visit-report-actor-3')::uuid;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-4')::uuid::text,true);
set local role authenticated;
select is((select count(*)::int from public.visits where inquiry_id=md5('visit-report-inquiry')::uuid),0,'new former seller cannot inspect visit details');
select is(public.get_my_visit_reporting_summary('month','2020-02-01')->'figures'->>'no_show','1','former seller retains only historical own result');
reset role;
-- Unauthorized identities must be rejected by both readers.
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('visit-report-actor-5')::uuid::text,true);
select throws_ok('select public.get_visit_reporting_summary(null,null)','42501',null,'inactive seller global denied');
select throws_ok('select public.get_my_visit_reporting_summary(null,null)','42501',null,'inactive seller own denied');
select set_config('request.jwt.claim.sub',md5('visit-report-actor-6')::uuid::text,true);
select throws_ok('select public.get_visit_reporting_summary(null,null)','42501',null,'inactive owner global denied');
select throws_ok('select public.get_my_visit_reporting_summary(null,null)','42501',null,'inactive owner own denied');
select set_config('request.jwt.claim.sub',md5('visit-report-actor-7')::uuid::text,true);
select throws_ok('select public.get_visit_reporting_summary(null,null)','42501',null,'inactive admin global denied');
select throws_ok('select public.get_my_visit_reporting_summary(null,null)','42501',null,'inactive admin own denied');
select set_config('request.jwt.claim.sub',md5('visit-report-actor-8')::uuid::text,true);
select throws_ok('select public.get_visit_reporting_summary(null,null)','42501',null,'identity without profile global denied');
select throws_ok('select public.get_my_visit_reporting_summary(null,null)','42501',null,'identity without profile own denied');
reset role;
select ok(not has_function_privilege(r,'public.get_visit_reporting_summary(text,date,date)','execute')
 and not has_function_privilege(r,'public.get_my_visit_reporting_summary(text,date,date)','execute'),'no direct reader grant for '||r)
 from (values('anon'),('service_role')) roles(r);
select * from finish();
rollback;
