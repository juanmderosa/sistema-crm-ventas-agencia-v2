begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();
-- Independent T3b regressions: S8/S12 eligibility and integrity; S13 tie-break.
create function pg_temp.u(n integer) returns uuid language sql immutable as $$select ('77000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid$$;
create function pg_temp.submit(n integer, phone text) returns jsonb language plpgsql as $$declare r jsonb; begin
 set local role service_role;
 r:=public.submit_inquiry(('77000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'77000000-0000-4000-8000-000000000100',phone,'Verifier','verifier@example.invalid');
 reset role; return r;
end $$;
create function pg_temp.snapshot() returns text language sql as $$
select md5(coalesce(string_agg(kind||':'||v,E'\n' order by kind,v),'')) from (
 select 'contacts' kind,row_to_json(t)::text v from public.contacts t
 union all select 'inquiries',row_to_json(t)::text from public.inquiries t
 union all select 'interests',row_to_json(t)::text from public.inquiry_interests t
 union all select 'history',row_to_json(t)::text from public.inquiry_assignment_history t
 union all select 'rotation',row_to_json(t)::text from public.vehicle_inquiry_rotation t
 union all select 'participation',row_to_json(t)::text from public.vehicle_inquiry_participants t
 union all select 'vehicles',row_to_json(t)::text from public.vehicles t
) rows$$;
-- Disable existing sellers only inside this rolled-back test transaction.
update public.profiles set is_active=false where role='seller';
insert into auth.users(id,email) values (pg_temp.u(1),'verify-owner@example.invalid'),(pg_temp.u(2),'verify-admin@example.invalid'),(pg_temp.u(3),'verify-seller@example.invalid');
insert into public.profiles(id,role,display_name,is_active) values (pg_temp.u(1),'owner','Verifier owner',true),(pg_temp.u(2),'admin','Verifier admin',true),(pg_temp.u(3),'seller','Verifier seller',false);
insert into public.vehicles(id,brand,model,year,publication_status) values(pg_temp.u(100),'Verifier','Fixture',2020,'published');
-- 1: removed administrative participation excludes continuity and new assignment.
insert into public.vehicle_inquiry_participants values(pg_temp.u(100),pg_temp.u(2));
select is(pg_temp.submit(201,'+549110000001'),'{"accepted":true}'::jsonb,'1 enabled admin accepts');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(201)),pg_temp.u(2),'1 initial owner is admin');
delete from vehicle_inquiry_participants where vehicle_id=pg_temp.u(100);
select pg_temp.submit(202,'+549110000001');
select pg_temp.submit(203,'+549110000002');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(201)),pg_temp.u(2),'1 removal preserves earlier ownership');
select is((select count(*)::int from inquiries where submission_id in(pg_temp.u(202),pg_temp.u(203)) and assignee_id is null),2,'1 removed admin excluded from continuity and new contact');
-- 2: inactive assignee is not a continuity candidate.
update profiles set is_active=true where id=pg_temp.u(3);
select pg_temp.submit(204,'+549110000003');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(204)),pg_temp.u(3),'2 initial active seller assigned');
update profiles set is_active=false where id=pg_temp.u(3);
insert into vehicle_inquiry_participants values(pg_temp.u(100),pg_temp.u(2));
select pg_temp.submit(205,'+549110000003');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(205)),pg_temp.u(2),'2 inactive continuity replaced with eligible admin');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(204)),pg_temp.u(3),'2 inactive previous ownership preserved');
-- 3: Owner and Admin require individual opt-in equally.
delete from vehicle_inquiry_participants where vehicle_id=pg_temp.u(100);
select pg_temp.submit(206,'+549110000004');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(206)),null::uuid,'3 neither administrative role automatically eligible');
insert into vehicle_inquiry_participants values(pg_temp.u(100),pg_temp.u(1));
select pg_temp.submit(207,'+549110000005');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(207)),pg_temp.u(1),'3 opted-in Owner eligible');
delete from vehicle_inquiry_participants where vehicle_id=pg_temp.u(100);
insert into vehicle_inquiry_participants values(pg_temp.u(100),pg_temp.u(2));
select pg_temp.submit(208,'+549110000006');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(208)),pg_temp.u(2),'3 opted-in Admin equally eligible');
-- 4: pending retains all creation records and leaves existing cursor unchanged.
delete from vehicle_inquiry_participants where vehicle_id=pg_temp.u(100);
create temp table cursor_before as select * from vehicle_inquiry_rotation;
select pg_temp.submit(209,'+549110000007');
select ok(exists(select 1 from inquiries where submission_id=pg_temp.u(209) and assignee_id is null and status='new'),'4 pending inquiry retained');
select is((select count(*)::int from inquiry_interests where inquiry_id=(select id from inquiries where submission_id=pg_temp.u(209)) and vehicle_id=pg_temp.u(100)),1,'4 originating interest retained');
select is((select count(*)::int from inquiry_assignment_history where inquiry_id=(select id from inquiries where submission_id=pg_temp.u(209)) and assignee_id is null and reason='unassigned'),1,'4 initial unassigned history retained');
select results_eq('select * from vehicle_inquiry_rotation order by vehicle_id','select * from cursor_before order by vehicle_id','4 cursor unchanged');
-- 5: deliberately opposite UUID order; timestamps identical, sequence later wins.
insert into vehicle_inquiry_participants values(pg_temp.u(100),pg_temp.u(1)),(pg_temp.u(100),pg_temp.u(2));
insert into contacts(id,normalized_phone,display_name,email) values(pg_temp.u(300),'+549110000008','Tie','tie@example.invalid');
insert into inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_email,created_at) values(pg_temp.u(999),pg_temp.u(301),pg_temp.u(300),pg_temp.u(100),pg_temp.u(1),'Tie','tie@example.invalid','2026-01-01');
insert into inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_email,created_at) values(pg_temp.u(400),pg_temp.u(302),pg_temp.u(300),pg_temp.u(100),pg_temp.u(2),'Tie','tie@example.invalid','2026-01-01');
select ok((select a.created_at=b.created_at and a.id>b.id and a.creation_sequence<b.creation_sequence from inquiries a,inquiries b where a.id=pg_temp.u(999) and b.id=pg_temp.u(400)),'5 fixture forces timestamp tie opposite UUID order');
select pg_temp.submit(210,'+549110000008');
select is((select assignee_id from inquiries where submission_id=pg_temp.u(210)),pg_temp.u(2),'5 latest creation_sequence wins');
-- 6: Reserved accepts without mutating any vehicle fields.
update vehicles set availability_status='reserved' where id=pg_temp.u(100);
create temp table reserved_before as select row_to_json(v)::text v from vehicles v where id=pg_temp.u(100);
select is(pg_temp.submit(211,'+549110000009'),'{"accepted":true}'::jsonb,'6 published Reserved accepts');
select is((select row_to_json(v)::text from vehicles v where id=pg_temp.u(100)),(select v from reserved_before),'6 Reserved vehicle row unchanged');
-- 7: successful winner materialized; rejected loser must change no stored rows.
select pg_temp.submit(212,'+549110000010');
create temp table rejection_before as select pg_temp.snapshot() h;
set local role service_role;
select throws_ok($$select public.submit_inquiry('77000000-0000-4000-8000-000000000212','77000000-0000-4000-8000-000000000100','+549110000010','Changed','verifier@example.invalid')$$,'22023','submission ID already used with different input','7 exact changed-payload rejection');
reset role;
select is(pg_temp.snapshot(),(select h from rejection_before),'7 all seven stored-row collections unchanged after rejection');
select * from finish();
rollback;
