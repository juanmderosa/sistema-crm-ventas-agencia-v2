begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users (id, email)
values
  ('10000000-0000-4000-8000-000000000001', 'inquiry-owner@example.invalid'),
  ('10000000-0000-4000-8000-000000000002', 'inquiry-admin@example.invalid'),
  ('10000000-0000-4000-8000-000000000003', 'inquiry-seller@example.invalid'),
  ('10000000-0000-4000-8000-000000000004', 'inquiry-colleague@example.invalid');
insert into public.profiles (id, role, display_name)
values
  ('10000000-0000-4000-8000-000000000001', 'owner', 'Owner'),
  ('10000000-0000-4000-8000-000000000002', 'admin', 'Admin'),
  ('10000000-0000-4000-8000-000000000003', 'seller', 'Seller'),
  ('10000000-0000-4000-8000-000000000004', 'seller', 'Colleague');
insert into public.vehicles (id, brand, model, year)
values
  ('20000000-0000-4000-8000-000000000001', 'Toyota', 'Corolla', 2020),
  ('20000000-0000-4000-8000-000000000002', 'Ford', 'Ranger', 2021);
insert into public.contacts (id, normalized_phone, display_name, email)
values
  ('30000000-0000-4000-8000-000000000001', '+5491112345678', 'Shared contact', 'shared@example.invalid'),
  ('30000000-0000-4000-8000-000000000002', '+5491187654321', 'Private contact', 'private@example.invalid');
insert into public.inquiries (id, submission_id, contact_id, originating_vehicle_id, assignee_id, submitted_name, submitted_email)
values
  ('40000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000003', 'Original submission', 'original@example.invalid'),
  ('40000000-0000-4000-8000-000000000002', '50000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000004', 'Other submission', 'other@example.invalid'),
  ('40000000-0000-4000-8000-000000000003', '50000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001', null, 'Pending assignment', 'pending@example.invalid');
insert into public.inquiry_interests (inquiry_id, vehicle_id)
values
  ('40000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001'),
  ('40000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002'),
  ('40000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001');

select is((select count(*)::int from public.inquiries), 3, 'multiple interests do not duplicate inquiries');
select is((select count(*)::int from public.inquiry_interests where inquiry_id = '40000000-0000-4000-8000-000000000001'), 2, 'one inquiry has two interests');
select is((select count(*)::int from public.vehicles where availability_status <> 'available'), 0, 'interests do not reserve vehicles');
select is((select count(distinct creation_sequence)::int from public.inquiries), 3, 'creation sequence is unique for equal transaction timestamps');
select is((select bool_and(status = 'new') from public.inquiries), true, 'inquiries start as new');
select throws_ok($$insert into public.contacts (normalized_phone, display_name, email) values ('+5491112345678', 'Duplicate', 'duplicate@example.invalid')$$, '23505', null, 'normalized phone identifies one contact');
select throws_ok($$insert into public.contacts (normalized_phone, display_name, email) values ('01112345678', 'Ambiguous', 'ambiguous@example.invalid')$$, '23514', null, 'storage rejects unnormalized national phone');
select throws_ok($$insert into public.inquiry_interests values ('40000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', now())$$, '23505', null, 'duplicate interest rejected');
select throws_ok($$delete from public.contacts where id = '30000000-0000-4000-8000-000000000001'$$, '23503', null, 'contact history cannot be orphaned');

set local role anon;
select throws_ok('select * from public.contacts', '42501', null, 'anonymous caller cannot read contacts');
select throws_ok('select * from public.inquiries', '42501', null, 'anonymous caller cannot read inquiries');
select throws_ok('select * from public.inquiry_interests', '42501', null, 'anonymous caller cannot read interests');

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000003","role":"authenticated"}';
select is((select count(*)::int from public.inquiries), 1, 'seller reads only own inquiry even with a shared contact');
select is((select count(*)::int from public.contacts), 1, 'seller reads only contacts linked to own inquiries');
select is((select count(*)::int from public.inquiry_interests), 2, 'seller reads only own interests');
select is((select submitted_name from public.inquiries), 'Original submission'::text, 'submitted snapshot is retained');
select throws_ok('update public.inquiries set assignee_id = auth.uid()', '42501', null, 'seller cannot claim inquiries through direct update');
select throws_ok('update public.contacts set normalized_phone = ''+5491199999999''', '42501', null, 'seller cannot directly overwrite contact identity');
select throws_ok('delete from public.inquiry_interests', '42501', null, 'seller cannot delete interest history');
select throws_ok($$insert into public.inquiry_interests (inquiry_id, vehicle_id) values ('40000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000002')$$, '42501', null, 'direct interest insertion is denied pending controlled operation');

reset role;
update public.profiles set is_active = false where id = '10000000-0000-4000-8000-000000000003';
set local role authenticated;
select is((select count(*)::int from public.inquiries), 0, 'inactive seller loses inquiry access');
select is((select count(*)::int from public.contacts), 0, 'inactive seller loses contact access');
select is((select count(*)::int from public.inquiry_interests), 0, 'inactive seller loses interest access');

set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}';
select is((select count(*)::int from public.inquiries), 3, 'owner sees all inquiries including unassigned');
select is((select count(*)::int from public.contacts), 2, 'owner sees all contacts');
select is((select count(*)::int from public.inquiry_interests), 3, 'owner sees all interests');
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated"}';
select is((select count(*)::int from public.inquiries), 3, 'admin sees all inquiries');
select is((select count(*)::int from public.contacts), 2, 'admin sees all contacts');
select is((select count(*)::int from public.inquiry_interests), 3, 'admin sees all interests');
select throws_ok('update public.inquiries set status = ''sale_reported''', '42501', null, 'admin cannot bypass future transactional status operations');

reset role;
select is((select count(*)::int from public.inquiries), 3, 'rejected writes leave inquiries unchanged');
select is((select normalized_phone from public.contacts where id = '30000000-0000-4000-8000-000000000001'), '+5491112345678'::text, 'rejected contact write leaves phone unchanged');
select is((select count(*)::int from public.inquiry_interests), 3, 'rejected writes leave interests unchanged');
select * from finish();
rollback;
