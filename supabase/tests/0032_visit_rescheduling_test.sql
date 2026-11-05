begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','reschedule_visit',array['uuid','timestamp with time zone','boolean'],'reschedule RPC exists');
create function pg_temp.vr(n integer) returns uuid language sql immutable as
 $$select md5('visit-reschedule-'||n)::uuid$$;
create temp table slots as select
 ((clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date+2+time '10:00')
 at time zone 'America/Argentina/Buenos_Aires' as a;
grant select on slots to authenticated;
insert into auth.users(id,email) select pg_temp.vr(n),'vr-'||n||'@example.invalid' from generate_series(1,5)n;
insert into public.profiles(id,role,display_name,is_active) values
 (pg_temp.vr(1),'owner','Owner',true),(pg_temp.vr(2),'admin','Admin',true),
 (pg_temp.vr(3),'seller','Seller',true),(pg_temp.vr(4),'seller','Other',true),
 (pg_temp.vr(5),'seller','Inactive',false);
insert into public.vehicles(id,brand,model,year) values(pg_temp.vr(20),'Test','Visit',2024);
insert into public.contacts(id,normalized_phone,display_name) values(pg_temp.vr(10),'+5491177000032','Customer');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_phone)
 values(pg_temp.vr(30),pg_temp.vr(31),pg_temp.vr(10),pg_temp.vr(20),pg_temp.vr(3),'Customer','+5491177000032');
insert into public.inquiry_interests(inquiry_id,vehicle_id) values(pg_temp.vr(30),pg_temp.vr(20));
insert into public.visits(id,inquiry_id,vehicle_id,scheduled_at,request_assignee_id,purpose)
 select pg_temp.vr(40),pg_temp.vr(30),pg_temp.vr(20),a-interval '1 day',pg_temp.vr(3),'Keep purpose' from slots;
insert into public.visit_creation_requests(submission_id,source,inquiry_id,visit_id,intent)
 values(pg_temp.vr(41),'staff',pg_temp.vr(30),pg_temp.vr(40),'{"immutable":"original"}');
create temp table preserved as select to_jsonb(v)-'scheduled_at'-'status'-'updated_at' as data from public.visits v;
delete from public.dealership_opening_hours;
insert into public.dealership_opening_hours select d,time '09:00',time '18:00' from generate_series(0,6)d;
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.vr(3)::text,true);
select is(public.reschedule_visit(pg_temp.vr(40),(select a from slots),true),jsonb_build_object('visit_id',pg_temp.vr(40)),'agreed reschedule returns same identity');
select is((select status::text from public.visits),'confirmed','agreement confirms');
select is((select scheduled_at from public.visits),(select a from slots),'new time persisted');
select ok((select from_status='requested' and to_status='confirmed' and actor_id=pg_temp.vr(3)
 and previous_scheduled_at=(select a-interval '1 day' from slots) and scheduled_at=(select a from slots)
 and occurred_at is not null from public.visit_history),'history records both appointments, states and actor');
select lives_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),true)$$,'exact valid retry succeeds');
select is((select count(*)::int from public.visit_history),1,'retry adds no history');
select lives_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a+interval '1 hour' from slots),false)$$,'confirmed appointment can become proposal');
select is((select status::text from public.visits),'requested','proposal requests');
select lives_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a+interval '2 hours' from slots),false)$$,'repeated rescheduling allowed');
select is((select count(*)::int from public.visit_history),3,'every actual reschedule adds history');
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),null,true)$$,'22023','visit time must be future and within opening hours','null time rejected');
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),'infinity',true)$$,'22023','visit time must be future and within opening hours','infinite time rejected');
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),clock_timestamp()-interval '1 second',true)$$,'22023','visit time must be future and within opening hours','past time rejected');
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a+interval '8 hours' from slots),true)$$,'22023','visit time must be future and within opening hours','closing boundary excluded');
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),null)$$,'22023','visit agreement is required','null agreement rejected');
select set_config('request.jwt.claim.sub',pg_temp.vr(4)::text,true);
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),true)$$,'42501','visit access denied','unrelated seller denied');
select set_config('request.jwt.claim.sub',pg_temp.vr(5)::text,true);
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),true)$$,'42501','visit access denied','inactive actor denied');
select set_config('request.jwt.claim.sub',pg_temp.vr(2)::text,true);
select lives_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a-interval '1 hour' from slots),true)$$,'Admin may use opening boundary');
select set_config('request.jwt.claim.sub',pg_temp.vr(1)::text,true);
select lives_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),false)$$,'Owner may propose');
select throws_ok($$select public.reschedule_visit(null,(select a from slots),true)$$,'42501','visit access denied','missing visit privacy-safe denial');
reset role;
select is((select to_jsonb(v)-'scheduled_at'-'status'-'updated_at' from public.visits v),(select data from preserved),'all other visit fields preserved');
select is((select intent from public.visit_creation_requests),'{"immutable":"original"}'::jsonb,'creation intent untouched');
update public.visits set status='attended',first_outcome_recorded_at=now(),outcome_assignee_id=pg_temp.vr(3);
set local role authenticated;
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),true)$$,'22023','only pending visits can be rescheduled','attended cannot reschedule');
reset role;
update public.visits set status='cancelled';
set local role authenticated;
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),true)$$,'22023','only pending visits can be rescheduled','cancelled cannot reschedule');
reset role;
update public.visits set status='no_show';
set local role authenticated;
select throws_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a from slots),true)$$,'22023','only pending visits can be rescheduled','No-show cannot reschedule');
select lives_ok($$select public.set_visit_status(pg_temp.vr(40),'confirmed','Restore')$$,'restore before rescheduling retains existing state contract');
select lives_ok($$select public.reschedule_visit(pg_temp.vr(40),(select a+interval '1 hour' from slots),true)$$,'restored appointment can reschedule');
select ok((select first_outcome_recorded_at is not null and outcome_assignee_id=pg_temp.vr(3) from public.visits),'first outcome survives rescheduling');
reset role;
select ok(not has_function_privilege('anon','public.reschedule_visit(uuid,timestamptz,boolean)','execute'),'anonymous execution denied');
select ok(not has_function_privilege('service_role','public.reschedule_visit(uuid,timestamptz,boolean)','execute'),'service execution denied');
select is((select count(*)::int from public.visits),1,'no duplicate visit');
select is((select count(*)::int from public.inquiries),1,'no new inquiry');
select is((select count(*)::int from public.reservations),0,'no reservation');
select is((select count(*)::int from public.vehicle_inquiry_rotation),0,'no routing effects');
select * from finish();
rollback;
