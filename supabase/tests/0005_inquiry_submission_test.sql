begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users (id, email) values
  ('60000000-0000-4000-8000-000000000001', 'routing-one@example.invalid'),
  ('60000000-0000-4000-8000-000000000002', 'routing-two@example.invalid'),
  ('60000000-0000-4000-8000-000000000003', 'routing-admin@example.invalid');
insert into public.profiles (id, role, display_name) values
  ('60000000-0000-4000-8000-000000000001', 'seller', 'First'),
  ('60000000-0000-4000-8000-000000000002', 'seller', 'Second'),
  ('60000000-0000-4000-8000-000000000003', 'admin', 'Admin');
insert into public.vehicles (id, brand, model, year, publication_status) values
  ('61000000-0000-4000-8000-000000000001', 'Toyota', 'Corolla', 2020, 'published'),
  ('61000000-0000-4000-8000-000000000002', 'Ford', 'Ranger', 2021, 'published');

-- All inputs are already canonical; this operation is not a public form parser.
set local role service_role;
select is(public.submit_inquiry('62000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001', '+5491111111101', 'One', 'one@example.invalid'), '{"accepted":true}'::jsonb, 'creation returns only a privacy-safe acknowledgement');
reset role;
select is((select assignee_id from public.inquiries where submission_id = '62000000-0000-4000-8000-000000000001'), '60000000-0000-4000-8000-000000000001'::uuid, 'rotation selects the first eligible seller');
select is((select count(*)::int from public.inquiry_interests where inquiry_id = (select id from public.inquiries where submission_id = '62000000-0000-4000-8000-000000000001')), 1, 'origin is recorded as an interest');
set local role service_role;
select is(public.submit_inquiry('62000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001', '+5491111111101', 'One', 'one@example.invalid'), '{"accepted":true}'::jsonb, 'identical retry returns identical minimal response');
select throws_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001', '+5491111111101', 'Changed', 'one@example.invalid')$$, '22023', null, 'changed payload under the same submission ID is rejected');
select lives_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000002', '61000000-0000-4000-8000-000000000001', '+5491111111101', 'Different name', 'different@example.invalid')$$, 'new intention for same contact preserves continuity');
reset role;
select is((select count(*)::int from public.inquiries where contact_id = (select id from public.contacts where normalized_phone = '+5491111111101')), 2, 'retry deduplicates but a new intention remains separate');
select is((select count(distinct assignee_id)::int from public.inquiries where contact_id = (select id from public.contacts where normalized_phone = '+5491111111101')), 1, 'continuity keeps one eligible assignee');
select is((select display_name from public.contacts where normalized_phone = '+5491111111101'), 'One'::text, 'public resubmission does not overwrite recognized contact');
select is((select last_assignee_id from public.vehicle_inquiry_rotation where vehicle_id = '61000000-0000-4000-8000-000000000001'), '60000000-0000-4000-8000-000000000001'::uuid, 'continuity and retry do not advance rotation');
set local role service_role;
select lives_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000003', '61000000-0000-4000-8000-000000000001', '+5491111111102', 'Two', 'two@example.invalid')$$, 'another contact enters rotation');
reset role;
select is((select assignee_id from public.inquiries where submission_id = '62000000-0000-4000-8000-000000000003'), '60000000-0000-4000-8000-000000000002'::uuid, 'rotation advances to the second seller');
select is((select count(*)::int from public.inquiry_assignment_history), 3, 'each accepted intention has exactly one initial assignment event');

-- Equal transaction timestamps: latest sequential inquiry wins, not UUID order.
update public.inquiries set assignee_id = '60000000-0000-4000-8000-000000000002' where submission_id = '62000000-0000-4000-8000-000000000002';
set local role service_role;
select lives_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000004', '61000000-0000-4000-8000-000000000001', '+5491111111101', 'Three', 'three@example.invalid')$$, 'latest eligible continuity resolves timestamp ties');
reset role;
select is((select assignee_id from public.inquiries where submission_id = '62000000-0000-4000-8000-000000000004'), '60000000-0000-4000-8000-000000000002'::uuid, 'sequential tie-break chooses latest inquiry');

-- Explicit administrative participation is per vehicle; sellers are always eligible.
insert into public.vehicle_inquiry_participants (vehicle_id, profile_id) values ('61000000-0000-4000-8000-000000000002', '60000000-0000-4000-8000-000000000003');
update public.profiles set is_active = false where role = 'seller';
set local role service_role;
select lives_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000005', '61000000-0000-4000-8000-000000000002', '+5491111111103', 'Admin contact', 'admin-contact@example.invalid')$$, 'enabled administrator participates');
select lives_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000006', '61000000-0000-4000-8000-000000000001', '+5491111111104', 'Pending', 'pending@example.invalid')$$, 'no eligible participant keeps inquiry for administrative handling');
reset role;
select is((select assignee_id from public.inquiries where submission_id = '62000000-0000-4000-8000-000000000005'), '60000000-0000-4000-8000-000000000003'::uuid, 'only individually enabled admin receives inquiry');
select is((select assignee_id from public.inquiries where submission_id = '62000000-0000-4000-8000-000000000006'), null::uuid, 'inactive sellers and non-enabled admin cannot receive inquiry');

update public.vehicles set availability_status = 'reserved' where id = '61000000-0000-4000-8000-000000000002';
set local role service_role;
select lives_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000007', '61000000-0000-4000-8000-000000000002', '+5491111111105', 'Reserved interest', 'reserved@example.invalid')$$, 'published reserved vehicle accepts inquiry');
reset role;
update public.vehicles set availability_status = 'sold' where id = '61000000-0000-4000-8000-000000000002';
set local role service_role;
select throws_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000008', '61000000-0000-4000-8000-000000000002', '+5491111111106', 'Rejected', 'rejected@example.invalid')$$, '22023', null, 'sold vehicle rejects new inquiry');
select is(public.submit_inquiry('62000000-0000-4000-8000-000000000007', '61000000-0000-4000-8000-000000000002', '+5491111111105', 'Reserved interest', 'reserved@example.invalid'), '{"accepted":true}'::jsonb, 'late retry remains safe after vehicle becomes sold');
reset role;
select is((select count(*)::int from public.contacts where normalized_phone = '+5491111111106'), 0, 'rejected creation does not persist a contact');
select is((select count(*)::int from public.inquiries), 7, 'rejections and retries do not persist extra inquiries');
select is((select count(*)::int from public.inquiry_assignment_history), 7, 'rejections and retries do not duplicate history');

set local role anon;
select throws_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000009', '61000000-0000-4000-8000-000000000001', '+5491111111107', 'Denied', 'denied@example.invalid')$$, '42501', null, 'anonymous caller cannot invoke internal operation');
reset role;
set local role authenticated;
select throws_ok($$select public.submit_inquiry('62000000-0000-4000-8000-000000000009', '61000000-0000-4000-8000-000000000001', '+5491111111107', 'Denied', 'denied@example.invalid')$$, '42501', null, 'authenticated caller cannot invoke internal operation');
reset role;
select * from finish();
rollback;
