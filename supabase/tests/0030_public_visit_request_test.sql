begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create function pg_temp.pu(n integer) returns uuid language sql immutable as $$select md5('public-visit-'||n)::uuid$$;
create temp table visit_slot as select (((clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date+7)
  +time '10:00') at time zone 'America/Argentina/Buenos_Aires' as value;
grant select on visit_slot to service_role;
create function pg_temp.public_visit(k integer, v integer default 21, phone text default '+5491177000030', purpose text default null)
returns jsonb language sql as $$select public.submit_visit_request(pg_temp.pu(k),pg_temp.pu(v),phone,
 'Public Customer','public@example.invalid',(select value from visit_slot),purpose)$$;
insert into auth.users(id,email) select pg_temp.pu(n),'pv-'||n||'@example.invalid' from generate_series(1,3)n;
insert into public.profiles(id,role,display_name) values
 (pg_temp.pu(1),'owner','Owner'),(pg_temp.pu(2),'seller','Seller A'),(pg_temp.pu(3),'seller','Seller B');
insert into public.vehicles(id,brand,model,year,publication_status) values
 (pg_temp.pu(21),'Public','First',2024,'published'),(pg_temp.pu(22),'Public','Second',2024,'published'),
 (pg_temp.pu(23),'Private','Draft',2024,'draft');
insert into public.dealership_opening_hours select n,'09:00','18:00' from generate_series(0,6)n;
set local role service_role;
select is(pg_temp.public_visit(101),' {"accepted":true}'::jsonb,'public creation returns accepted only');
reset role;
select is((select count(*)::int from public.visits),1,'public request creates one visit');
select is((select count(*)::int from public.inquiries),1,'public request creates one inquiry');
select is((select count(*)::int from public.inquiry_interests),1,'origin interest created');
select is((select count(*)::int from public.inquiry_assignment_history),1,'normal routing history created');
select is((select v.request_assignee_id=i.assignee_id from public.visits v join public.inquiries i on i.id=v.inquiry_id),true,'visit attribution uses routed assignee');
select is((select actor_id is null from public.visit_history),true,'public submission has no staff audit actor');
select is((select count(*)::int from public.reservations),0,'public visit does not reserve');
set local role service_role;
select is(pg_temp.public_visit(101),'{"accepted":true}'::jsonb,'identical retry is accepted');
savepoint time_boundaries;
select is(public.submit_visit_request(pg_temp.pu(109),pg_temp.pu(21),'+5491177000030','Public Customer','public@example.invalid',
 (select value-interval '1 hour' from visit_slot),null),'{"accepted":true}'::jsonb,'opening boundary included');
select throws_ok($$select public.submit_visit_request(pg_temp.pu(110),pg_temp.pu(21),'+5491177000030','Public Customer','public@example.invalid',
 (select value+interval '8 hours' from visit_slot),null)$$,'22023','visit time must be future and within opening hours','closing boundary excluded');
select throws_ok($$select public.submit_visit_request(pg_temp.pu(111),pg_temp.pu(21),'+5491177000030','Public Customer','public@example.invalid',null,null)$$,
 '22023','invalid visit input','null appointment rejected');
rollback to savepoint time_boundaries;
select throws_ok($$select pg_temp.public_visit(101,21,'+5491177000030','Changed')$$,'22023','visit submission ID already used with different input','changed purpose rejected');
select throws_ok($$select public.submit_visit_request(pg_temp.pu(101),pg_temp.pu(21),'+5491177000030','Public Customer','public@example.invalid',(select value+interval '1 hour' from visit_slot),null)$$,
 '22023','visit submission ID already used with different input','changed timestamp rejected');
select throws_ok($$select public.submit_inquiry(pg_temp.pu(101),pg_temp.pu(21),'+5491177000030','Public Customer','public@example.invalid')$$,
 '22023','submission ID already used with different input','visit key cannot become ordinary inquiry');
select lives_ok($$select public.submit_inquiry(pg_temp.pu(102),pg_temp.pu(21),'+5491177000031','Ordinary','ordinary@example.invalid')$$,'ordinary submission unchanged');
select throws_ok($$select public.submit_visit_request(pg_temp.pu(102),pg_temp.pu(21),'+5491177000031','Ordinary','ordinary@example.invalid',(select value from visit_slot),null)$$,
 '22023','submission ID already used with different input','ordinary key cannot become visit request');
reset role;
update public.vehicles set sale_enabled=false where id=pg_temp.pu(22);
set local role service_role;
select throws_ok($$select pg_temp.public_visit(103,22,'+5491177000032')$$,'22023','vehicle does not accept visits','blocked public visit rejected');
select lives_ok($$select public.submit_inquiry(pg_temp.pu(104),pg_temp.pu(22),'+5491177000032','Ordinary','ordinary@example.invalid')$$,
 'legacy ordinary behavior for blocked vehicles deliberately unchanged');
select throws_ok($$select pg_temp.public_visit(105,23,'+5491177000033')$$,'22023','vehicle does not accept inquiries','public draft rejected by normal submission');
reset role;
update public.vehicles set sale_enabled=true where id=pg_temp.pu(22);
create temp table before_failure as select
 (select count(*) from public.contacts) contacts,(select count(*) from public.inquiries) inquiries,
 (select jsonb_agg(to_jsonb(r) order by vehicle_id) from public.vehicle_inquiry_rotation r) rotation;
delete from public.dealership_opening_hours;
set local role service_role;
select throws_ok($$select pg_temp.public_visit(106,22,'+5491177000034')$$,'22023','visit time must be future and within opening hours','invalid schedule rolls back entire submission');
select is(pg_temp.public_visit(101),'{"accepted":true}'::jsonb,'retry survives schedule removal');
reset role;
select is((select count(*) from public.contacts),(select contacts from before_failure),'failed submission does not retain a contact');
select is((select count(*) from public.inquiries),(select inquiries from before_failure),'failed submission does not retain an inquiry');
select is((select jsonb_agg(to_jsonb(r) order by vehicle_id) from public.vehicle_inquiry_rotation r),(select rotation from before_failure),'failure restores exact rotation');
update public.vehicles set sale_enabled=false where id=pg_temp.pu(21);
update public.inquiries set status='closed_without_sale' where submission_id=pg_temp.pu(101);
set local role service_role;
select is(pg_temp.public_visit(101),'{"accepted":true}'::jsonb,'matching retry independent of current vehicle and inquiry state');
reset role;
update public.profiles set is_active=false where role='seller';
insert into public.dealership_opening_hours select n,'09:00','18:00' from generate_series(0,6)n;
set local role service_role;
select is(pg_temp.public_visit(107,22,'+5491177000035'),'{"accepted":true}'::jsonb,'no eligible staff still accepts unassigned visit request');
reset role;
select is((select request_assignee_id is null from public.visits where inquiry_id=(select id from public.inquiries where submission_id=pg_temp.pu(107))),true,'unassigned request attribution retained');
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.pu(1)::text,true);
select throws_ok($$select public.submit_visit_request(pg_temp.pu(108),pg_temp.pu(21),'+5491177000030','Customer','c@example.invalid','2030-01-01T10:00:00Z',null)$$,
 '42501','permission denied for function submit_visit_request','even Owner cannot execute service-only request directly');
reset role;
set local role anon;
select throws_ok($$select public.submit_visit_request(pg_temp.pu(108),pg_temp.pu(21),'+5491177000030','Customer','c@example.invalid','2030-01-01T10:00:00Z',null)$$,
 '42501','permission denied for function submit_visit_request','anonymous direct execution denied');
reset role;
select is((select count(*)::int from public.visits),2,'only two successful distinct visit requests stored');
select is((select count(*)::int from public.visit_history),2,'technical retries add no history');
select * from finish();
rollback;
