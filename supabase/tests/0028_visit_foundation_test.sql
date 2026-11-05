begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select has_table('public', 'dealership_opening_hours', 'opening hours exist');
select has_table('public', 'visits', 'private visits exist');
select has_table('public', 'visit_history', 'visit history exists');

insert into auth.users(id, email)
select ('28000000-0000-4000-8000-00000000000' || n)::uuid,
  'visit-' || n || '@example.invalid' from generate_series(1, 5) n;
insert into public.profiles(id, role, display_name, is_active) values
('28000000-0000-4000-8000-000000000001', 'owner', 'Visit Owner', true),
('28000000-0000-4000-8000-000000000002', 'admin', 'Visit Admin', true),
('28000000-0000-4000-8000-000000000003', 'seller', 'Visit Seller', true),
('28000000-0000-4000-8000-000000000004', 'seller', 'Other Seller', true),
('28000000-0000-4000-8000-000000000005', 'seller', 'Inactive Seller', false);
insert into public.vehicles(id, brand, model, year) values
('28100000-0000-4000-8000-000000000001', 'Test', 'Private draft', 2024),
('28100000-0000-4000-8000-000000000002', 'Test', 'Other interest', 2024);
insert into public.contacts(id, normalized_phone, display_name) values
('28200000-0000-4000-8000-000000000001', '+5491188880028', 'Visit Contact');
insert into public.inquiries(id, submission_id, contact_id, originating_vehicle_id,
  assignee_id, submitted_name, submitted_phone) values
('28300000-0000-4000-8000-000000000001', '28400000-0000-4000-8000-000000000001',
 '28200000-0000-4000-8000-000000000001', '28100000-0000-4000-8000-000000000001',
 '28000000-0000-4000-8000-000000000003', 'Visit Contact', '+5491188880028');
insert into public.inquiry_interests(inquiry_id, vehicle_id) values
('28300000-0000-4000-8000-000000000001', '28100000-0000-4000-8000-000000000001'),
('28300000-0000-4000-8000-000000000001', '28100000-0000-4000-8000-000000000002');

insert into public.visits(id, inquiry_id, vehicle_id, scheduled_at, request_assignee_id) values
('28500000-0000-4000-8000-000000000001', '28300000-0000-4000-8000-000000000001',
 '28100000-0000-4000-8000-000000000001', '2030-01-07 12:00:00-03',
 '28000000-0000-4000-8000-000000000003');
insert into public.visit_history(visit_id, to_status, actor_id) values
('28500000-0000-4000-8000-000000000001', 'requested', '28000000-0000-4000-8000-000000000003');
select is((select status::text from public.visits), 'requested', 'new visits are tentative');
select throws_ok($$insert into public.visits(inquiry_id, vehicle_id, scheduled_at) values
('28300000-0000-4000-8000-000000000001','28100000-0000-4000-8000-000000000002',now())$$,
'23505', null, 'one pending visit per inquiry even for another interest vehicle');
select throws_ok($$update public.visits set vehicle_id = '28100000-0000-4000-8000-000000000099'$$,
'23503', null, 'visit must reference an actual interest');
select throws_ok($$update public.visits set outcome_assignee_id = request_assignee_id$$,
'23514', null, 'attribution requires an explicit first-outcome marker');
update public.visits set status = 'cancelled', first_outcome_recorded_at = now();
select is((select outcome_assignee_id is null from public.visits), true,
  'first unassigned outcome is representable');
insert into public.visits(inquiry_id, vehicle_id, scheduled_at) values
('28300000-0000-4000-8000-000000000001', '28100000-0000-4000-8000-000000000002', '2030-01-08 12:00:00-03');
select is((select count(*)::int from public.visits), 2, 'finalized visits allow a later visit');

set local role authenticated;
set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000001","role":"authenticated"}';
select lives_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":1,"opens_at":"09:00","closes_at":"13:00"},{"weekday":1,"opens_at":"16:00","closes_at":"20:00"}]')$$,
 'owner configures split opening intervals');
select is((select count(*)::int from public.dealership_opening_hours), 2, 'configured intervals persist');
select throws_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":1,"opens_at":"09:00","closes_at":"13:00"},{"weekday":1,"opens_at":"12:00","closes_at":"14:00"}]')$$,
 '23P01', null, 'overlapping intervals rejected');
select throws_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":7,"opens_at":"09:00","closes_at":"13:00"}]')$$,
 '23514', null, 'weekday outside Sunday zero through Saturday six rejected');
select throws_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":1,"opens_at":"13:00","closes_at":"09:00"}]')$$,
 '23514', null, 'inverted interval rejected');
select throws_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":1,"opens_at":"09:00","closes_at":"09:00"}]')$$,
 '23514', null, 'empty interval rejected');
select is((select count(*)::int from public.dealership_opening_hours), 2, 'failed replacements preserve old hours');
select throws_ok($$select public.set_dealership_opening_hours('[{}]')$$, '23502', null, 'missing interval fields rejected');
select throws_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":1,"opens_at":"bad","closes_at":"13:00"}]')$$, '22007', null, 'malformed time rejected');
select is((select jsonb_agg(to_jsonb(h) order by weekday, opens_at) from public.dealership_opening_hours h),
 '[{"weekday":1,"opens_at":"09:00:00","closes_at":"13:00:00"},{"weekday":1,"opens_at":"16:00:00","closes_at":"20:00:00"}]'::jsonb,
 'rejected replacements preserve exact schedule values');
select is((select count(*)::int from public.visits), 2, 'hours changes preserve visits');
select is((select count(*)::int from public.visit_history), 1, 'hours changes preserve visit history');
select throws_ok($$select public.set_dealership_opening_hours(null)$$, '22023', null, 'null hours rejected');
select throws_ok($$select public.set_dealership_opening_hours('{}')$$, '22023', null, 'non-array hours rejected');
select throws_ok($$update public.visits set status = 'attended'$$, '42501', null, 'owner cannot bypass lifecycle RPCs');
select throws_ok($$delete from public.visit_history$$, '42501', null, 'owner cannot erase history');

set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000002","role":"authenticated"}';
select lives_ok($$select public.set_dealership_opening_hours(
 '[{"weekday":2,"opens_at":"10:00","closes_at":"12:00"},{"weekday":2,"opens_at":"12:00","closes_at":"14:00"}]')$$,
 'admin configures touching nonoverlapping intervals');
select is((select count(*)::int from public.visits), 2, 'admin sees all visits');
select lives_ok($$select public.set_dealership_opening_hours('[]')$$, 'explicit empty schedule allowed');

set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000003","role":"authenticated"}';
select is((select count(*)::int from public.visits), 2, 'responsible seller sees all own inquiry visits');
select is((select count(*)::int from public.visit_history), 1, 'responsible seller sees own history');
select lives_ok('select * from public.dealership_opening_hours', 'seller reads opening hours');
select throws_ok($$select public.set_dealership_opening_hours('[]')$$, '42501', 'opening hours access denied', 'seller cannot configure hours');
select throws_ok('insert into public.visits(inquiry_id,vehicle_id,scheduled_at) values(null,null,now())', '42501', null, 'seller cannot directly create visits');
select throws_ok('delete from public.dealership_opening_hours', '42501', null, 'seller cannot directly change hours');

set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000004","role":"authenticated"}';
select is((select count(*)::int from public.visits), 0, 'unrelated seller sees no visits');
select is((select count(*)::int from public.visit_history), 0, 'unrelated seller sees no history');
reset role;
update public.inquiries set assignee_id = '28000000-0000-4000-8000-000000000004';
set local role authenticated;
set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000003","role":"authenticated"}';
select is((select count(*)::int from public.visits), 0, 'former seller loses visit details');
select is((select count(*)::int from public.visit_history), 0, 'historical attribution does not expose history');
set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000004","role":"authenticated"}';
select is((select count(*)::int from public.visits), 2, 'new responsible seller gains visit details');
reset role;
update public.profiles set is_active = false where id = '28000000-0000-4000-8000-000000000004';
set local role authenticated;
select is((select count(*)::int from public.visits), 0, 'deactivated responsible seller loses visits');
select is((select count(*)::int from public.visit_history), 0, 'deactivated seller loses history');
set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000005","role":"authenticated"}';
select throws_ok($$select public.set_dealership_opening_hours('[]')$$, '42501', 'opening hours access denied', 'inactive user denied');
set local request.jwt.claims = '{"sub":"28000000-0000-4000-8000-000000000099","role":"authenticated"}';
select throws_ok($$select public.set_dealership_opening_hours(null)$$, '42501', 'opening hours access denied', 'missing profile denied before validation');
select is((select count(*)::int from public.visits), 0, 'missing profile cannot read populated private visits');

reset role;
set local role anon;
select throws_ok('select * from public.visits', '42501', null, 'anonymous visits denied');
select throws_ok('select * from public.visit_history', '42501', null, 'anonymous history denied');
select throws_ok('select * from public.dealership_opening_hours', '42501', null, 'raw anonymous schedule denied pending public contract');
select throws_ok($$select public.set_dealership_opening_hours('[]')$$, '42501', null, 'anonymous configuration denied');
reset role;
set local role service_role;
select throws_ok('select * from public.visits', '42501', null, 'service role has no broad visit access');
select throws_ok($$select public.set_dealership_opening_hours('[]')$$, '42501', null, 'service role cannot impersonate hours administrator');
reset role;
select is((select count(*)::int from public.visits), 2, 'denials preserve visits');
select is((select count(*)::int from public.visit_history), 1, 'denials preserve history');
select * from finish();
rollback;
