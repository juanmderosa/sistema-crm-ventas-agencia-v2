begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create function pg_temp.vu(n integer) returns uuid language sql immutable as
  $$select md5('visit-create-' || n)::uuid$$;
create function pg_temp.slot() returns timestamptz language sql as $$
  select (((clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date + 7)
    + time '10:00') at time zone 'America/Argentina/Buenos_Aires'
$$;
select has_function('public', 'create_inquiry_visit',
  array['uuid','uuid','uuid','timestamp with time zone','text'], 'private creation RPC exists');
insert into auth.users(id,email) select pg_temp.vu(n), 'vc-'||n||'@example.invalid' from generate_series(1,5)n;
insert into public.profiles(id,role,display_name,is_active) values
 (pg_temp.vu(1),'owner','Owner',true),(pg_temp.vu(2),'admin','Admin',true),
 (pg_temp.vu(3),'seller','Seller',true),(pg_temp.vu(4),'seller','Other',true),
 (pg_temp.vu(5),'seller','Inactive',false);
insert into public.vehicles(id,brand,model,year,availability_status) values
 (pg_temp.vu(21),'Test','Draft',2024,'available'),(pg_temp.vu(22),'Test','Reserved',2024,'reserved');
insert into public.contacts(id,normalized_phone,display_name) values(pg_temp.vu(10),'+5491177000029','Visit customer');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_phone)
 select pg_temp.vu(n),pg_temp.vu(n+10),pg_temp.vu(10),pg_temp.vu(21),
 case when n=32 then pg_temp.vu(4) else pg_temp.vu(3) end,'Customer','+5491177000029'
 from generate_series(31,34)n;
insert into public.inquiry_interests(inquiry_id,vehicle_id)
 select pg_temp.vu(n),pg_temp.vu(v) from generate_series(31,34)n cross join generate_series(21,22)v;
insert into public.dealership_opening_hours select n,'09:00','18:00' from generate_series(0,6)n;
set local role authenticated;
set local request.jwt.claims = '{"sub":"unused"}';
select set_config('request.jwt.claim.sub',pg_temp.vu(3)::text,true);
select lives_ok($$select public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')$$,
 'responsible seller creates tentative visit for unpublished eligible interest');
select is((select status::text from public.visits),'requested','creation is tentative');
select is((select purpose from public.visits),'First visit','optional purpose retained');
select is((select request_assignee_id from public.visits),pg_temp.vu(3),'request belongs to current inquiry assignee');
select is((select actor_id from public.visit_history),pg_temp.vu(3),'history records executing staff member');
select is((select count(*)::int from public.visit_history),1,'creation appends history once');
select is(public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')->>'visit_id',
 (select id::text from public.visits),'identical retry returns original visit');
savepoint original_retry;
reset role;
update public.visits set scheduled_at=scheduled_at+interval '1 hour',status='attended';
set local timezone='Asia/Tokyo';
set local role authenticated;
select is(public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')->>'visit_id',
 (select id::text from public.visits), 'retry uses immutable intent across timezone and later visit changes');
reset role;
update public.profiles set is_active=false where id=pg_temp.vu(3);
set local role authenticated;
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')$$,
 '42501','visit access denied','matching retry reauthorizes deactivated actor');
rollback to savepoint original_retry;
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'Different')$$,
 '22023','visit submission ID already used with different input','changed intent rejected');
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(102),pg_temp.vu(31),pg_temp.vu(22),pg_temp.slot(),null)$$,
 '22023','inquiry already has a pending visit','different vehicle cannot bypass pending visit limit');
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(103),pg_temp.vu(32),pg_temp.vu(21),pg_temp.slot(),null)$$,
 '42501','visit access denied','seller cannot create for another inquiry');
select lives_ok($$select public.create_inquiry_visit(pg_temp.vu(104),pg_temp.vu(33),pg_temp.vu(22),pg_temp.slot(),null)$$,
 'Reserved interest remains eligible');
select is((select count(*)::int from public.inquiries),3,'seller inquiry visibility unchanged');
select throws_ok('select * from public.visit_creation_requests','42501',null,'idempotency records are not exposed');
reset role;
select is((select count(*)::int from public.inquiries),4,'private visits never create inquiries');
select is((select count(*)::int from public.vehicle_inquiry_rotation),0,'private creation does not advance routing');
select is((select count(*)::int from public.reservations),0,'private creation never reserves');
update public.inquiries set status='closed_without_sale' where id=pg_temp.vu(34);
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.vu(3)::text,true);
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(105),pg_temp.vu(34),pg_temp.vu(21),pg_temp.slot(),null)$$,
 '22023','inquiry is not active','closed inquiry rejected');
reset role;
update public.inquiries set status='following_up' where id=pg_temp.vu(34);
delete from public.inquiry_interests where inquiry_id=pg_temp.vu(34) and vehicle_id=pg_temp.vu(22);
set local role authenticated;
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(106),pg_temp.vu(34),pg_temp.vu(22),pg_temp.slot(),null)$$,
 '22023','vehicle is not an inquiry interest','visit selects existing interest only');
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(107),pg_temp.vu(34),pg_temp.vu(21),clock_timestamp()-interval '1 hour',null)$$,
 '22023','visit time must be future and within opening hours','past visit rejected');
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(108),pg_temp.vu(34),pg_temp.vu(21),pg_temp.slot()+interval '8 hours',null)$$,
 '22023','visit time must be future and within opening hours','closing boundary excluded');
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(109),pg_temp.vu(34),pg_temp.vu(21),pg_temp.slot()-interval '2 hours',null)$$,
 '22023','visit time must be future and within opening hours','before opening rejected');
reset role;
update public.vehicles set sale_enabled=false where id=pg_temp.vu(21);
set local role authenticated;
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(110),pg_temp.vu(34),pg_temp.vu(21),pg_temp.slot(),null)$$,
 '22023','vehicle does not accept visits','blocked vehicle rejected');
reset role;
update public.vehicles set sale_enabled=true,deleted_at=clock_timestamp() where id=pg_temp.vu(21);
set local role authenticated;
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(111),pg_temp.vu(34),pg_temp.vu(21),pg_temp.slot(),null)$$,
 '22023','vehicle does not accept visits','deleted vehicle rejected');
reset role;
update public.vehicles set deleted_at=null where id=pg_temp.vu(21);
update public.inquiries set status='closed_without_sale' where id=pg_temp.vu(31);
delete from public.dealership_opening_hours;
set local role authenticated;
select is(public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')->>'visit_id',
 (select id::text from public.visits where inquiry_id=pg_temp.vu(31)), 'authorized retry survives closure and schedule changes');
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(112),pg_temp.vu(34),pg_temp.vu(21),pg_temp.slot(),null)$$,
 '22023','visit time must be future and within opening hours','empty opening schedule rejects new visits');
reset role;
update public.inquiries set assignee_id=pg_temp.vu(4) where id=pg_temp.vu(31);
set local role authenticated;
select throws_ok($$select public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')$$,
 '42501','visit access denied','former assignee cannot retrieve original visit by retry');
select set_config('request.jwt.claim.sub',pg_temp.vu(5)::text,true);
select throws_ok($$select public.create_inquiry_visit(null,null,null,null,null)$$,'42501','visit access denied','inactive user denied before input validation');
select set_config('request.jwt.claim.sub',pg_temp.vu(2)::text,true);
select is(public.create_inquiry_visit(pg_temp.vu(101),pg_temp.vu(31),pg_temp.vu(21),pg_temp.slot(),'First visit')->>'visit_id',
 (select id::text from public.visits where inquiry_id=pg_temp.vu(31)), 'admin may retry visible inquiry without changing attribution');
reset role;
set local role anon;
select throws_ok($$select public.create_inquiry_visit(null,null,null,null,null)$$,'42501',null,'anonymous creation denied');
reset role;
set local role service_role;
select throws_ok($$select public.create_inquiry_visit(null,null,null,null,null)$$,'42501',null,'service role cannot impersonate staff creation');
reset role;
select is((select count(*)::int from public.visits),2,'failed commands preserve visit count');
select is((select count(*)::int from public.visit_history where from_status is null),2,'retries and failures do not append creation history');
select is((select count(*)::int from public.visit_history where to_status='cancelled'),1,'blocking adds one cancellation; retries and later closure add none');
select is((select count(*)::int from public.visit_creation_requests),2,'only successful intents persist');
select * from finish();
rollback;
