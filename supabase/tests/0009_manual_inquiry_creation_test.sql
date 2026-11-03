begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Synthetic identities and inventory; every fixture rolls back.
insert into auth.users (id, email)
select md5('manual-actor-' || n)::uuid, 'manual-' || n || '@example.invalid'
from generate_series(1, 5) n;
insert into public.profiles (id, role, display_name, is_active)
select md5('manual-actor-' || n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,
  'Manual actor ' || n, n <> 4
from generate_series(1, 4) n;
insert into public.vehicles (id, brand, model, year, publication_status, availability_status, deleted_at)
select md5('manual-vehicle-' || n)::uuid, 'Test', 'Manual ' || n, 2020,
  (case when n = 2 then 'draft' else 'published' end)::public.vehicle_publication_status,
  (case n when 3 then 'sold' when 5 then 'reserved' else 'available' end)::public.vehicle_availability_status,
  case when n = 4 then now() end
from generate_series(1, 5) n;
insert into public.contacts (id, normalized_phone, display_name, email)
values (md5('manual-contact')::uuid, '+5491100008001', 'Existing Name', 'existing@example.invalid');

-- Complete-state hash includes the inquiry allocation counter.
create function pg_temp.manual_state() returns text
language sql as $$
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.profiles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
    (select jsonb_agg(to_jsonb(t) order by inquiry_id, vehicle_id) from public.inquiry_interests t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t),
    (select jsonb_build_array(last_value, is_called) from public.inquiries_creation_sequence_seq)
  )::text);
$$;

create function pg_temp.manual_create(actor integer, phone text, name text, email text,
  vehicle integer, origin public.inquiry_origin) returns uuid
language plpgsql as $$
declare
  response jsonb;
  created uuid;
begin
  perform set_config('request.jwt.claim.sub', md5('manual-actor-' || actor)::uuid::text, true);
  perform set_config('role', 'authenticated', true);
  select public.create_manual_inquiry(phone, name, email,
    case when vehicle is null then null else md5('manual-vehicle-' || vehicle)::uuid end,
    origin) into response;
  perform set_config('role', 'none', true);
  created := (response ->> 'inquiry_id')::uuid;
  return created;
end;
$$;

create function pg_temp.manual_reject(actor integer, phone text, name text, email text,
  vehicle integer, origin public.inquiry_origin, expected_state text, expected_message text,
  label text, api_role text default 'authenticated') returns setof text
language plpgsql as $$
declare
  before_all text := pg_temp.manual_state();
  observed_state text := '00000';
  observed_message text := '';
begin
  perform set_config('request.jwt.claim.sub', md5('manual-actor-' || actor)::uuid::text, true);
  perform set_config('role', api_role, true);
  begin
    perform public.create_manual_inquiry(phone, name, email,
      case when vehicle is null then null else md5('manual-vehicle-' || vehicle)::uuid end,
      origin);
  exception when others then
    get stacked diagnostics observed_state = returned_sqlstate, observed_message = message_text;
  end;
  perform set_config('role', 'none', true);
  return next is(observed_state, expected_state, label || ': SQLSTATE');
  if expected_message is not null then
    return next is(observed_message, expected_message, label || ': exact error');
  end if;
  return next is(pg_temp.manual_state(), before_all, label || ': rejected operation changes nothing');
end;
$$;

-- Seller registers an in-person inquiry for an existing contact and a vehicle.
create temp table first_created as
select pg_temp.manual_create(3, '+5491100008001', 'Typed Name', 'typed@example.invalid',
  1, 'in_person') as id;
select ok((select id is not null from first_created), 'seller creates manual inquiry');
select is((select i.assignee_id from public.inquiries i, first_created c where i.id = c.id),
  md5('manual-actor-3')::uuid, 'manual inquiry is assigned to its creator');
select is((select i.status from public.inquiries i, first_created c where i.id = c.id),
  'new'::public.inquiry_status, 'manual inquiry starts as new');
select is((select i.origin from public.inquiries i, first_created c where i.id = c.id),
  'in_person'::public.inquiry_origin, 'manual origin is stored');
select is((select i.contact_id from public.inquiries i, first_created c where i.id = c.id),
  md5('manual-contact')::uuid, 'existing contact is reused by normalized phone');
select is((select i.originating_vehicle_id from public.inquiries i, first_created c where i.id = c.id),
  md5('manual-vehicle-1')::uuid, 'selected vehicle becomes the originating vehicle');
select is((select i.submitted_name from public.inquiries i, first_created c where i.id = c.id),
  'Typed Name', 'submitted name is retained on the inquiry');
select is((select i.submitted_email from public.inquiries i, first_created c where i.id = c.id),
  'typed@example.invalid', 'submitted email is retained on the inquiry');
select is((select display_name from public.contacts where id = md5('manual-contact')::uuid),
  'Existing Name', 'existing contact name is not overwritten');
select is((select email from public.contacts where id = md5('manual-contact')::uuid),
  'existing@example.invalid', 'existing contact email is not overwritten');
select is((select revision from public.contacts where id = md5('manual-contact')::uuid),
  0::bigint, 'existing contact revision is untouched');
select ok(exists (select 1 from public.inquiry_interests ii, first_created c
  where ii.inquiry_id = c.id and ii.vehicle_id = md5('manual-vehicle-1')::uuid),
  'selected vehicle is recorded as an interest');
select is((select count(*) from public.inquiry_assignment_history h, first_created c
  where h.inquiry_id = c.id and h.reason = 'manual'
    and h.assignee_id = md5('manual-actor-3')::uuid), 1::bigint,
  'assignment history records the manual reason');

-- Owner registers a telephone inquiry without a vehicle and without email.
create temp table second_created as
select pg_temp.manual_create(1, '+5491100008002', 'Phone Customer', null, null, 'phone') as id;
select is((select i.origin from public.inquiries i, second_created c where i.id = c.id),
  'phone'::public.inquiry_origin, 'telephone origin is stored');
select ok((select i.originating_vehicle_id is null from public.inquiries i, second_created c
  where i.id = c.id), 'manual inquiry may omit the originating vehicle');
select ok((select i.submitted_email is null from public.inquiries i, second_created c
  where i.id = c.id), 'manual inquiry may omit email');
select is((select i.assignee_id from public.inquiries i, second_created c where i.id = c.id),
  md5('manual-actor-1')::uuid, 'owner manual inquiry is self-assigned');
select is((select c2.display_name from public.contacts c2
  where c2.normalized_phone = '+5491100008002'), 'Phone Customer',
  'unknown phone creates a new contact');
select ok((select email is null from public.contacts
  where normalized_phone = '+5491100008002'), 'new contact keeps email empty');
select is((select count(*) from public.inquiry_interests ii, second_created c
  where ii.inquiry_id = c.id), 0::bigint, 'inquiry without vehicle records no interest');

-- Admin may register a manual inquiry for draft Available inventory.
create temp table third_created as
select pg_temp.manual_create(2, '+5491100008003', 'Admin Customer',
  'admin@example.invalid', 2, 'in_person') as id;
select ok(exists (select 1 from public.inquiry_interests ii, third_created c
  where ii.inquiry_id = c.id and ii.vehicle_id = md5('manual-vehicle-2')::uuid),
  'admin records a draft Available interest');
select is((select i.assignee_id from public.inquiries i, third_created c where i.id = c.id),
  md5('manual-actor-2')::uuid, 'admin manual inquiry is self-assigned');

-- A second seller reuses the shared contact without overwriting it.
create temp table fourth_created as
select pg_temp.manual_create(3, '+5491100008001', 'Another Typed', 'another@example.invalid',
  null, 'phone') as id;
select is((select display_name from public.contacts where id = md5('manual-contact')::uuid),
  'Existing Name', 'shared contact name survives a different manual submission');
select is((select i.submitted_name from public.inquiries i, fourth_created c where i.id = c.id),
  'Another Typed', 'discrepant manual name is retained on the new inquiry');

-- Rejections keep every row and the allocation counter unchanged.
select * from pg_temp.manual_reject(3, '+5491100008004', 'Web Attempt', null, null,
  'web', '22023', 'manual inquiry origin must be in_person or phone', 'web origin rejected');
select * from pg_temp.manual_reject(5, '+5491100008005', 'Anon', null, null,
  'phone', '42501', null, 'anonymous denied', 'anon');
select * from pg_temp.manual_reject(5, '+5491100008005', 'No Profile', null, null,
  'phone', '42501', 'manual inquiry access denied', 'identity without profile denied');
select * from pg_temp.manual_reject(4, '+5491100008006', 'Inactive', null, null,
  'phone', '42501', 'manual inquiry access denied', 'inactive staff denied');
select * from pg_temp.manual_reject(3, '+5491100008007', '   ', null, null,
  'phone', '22023', 'invalid manual inquiry input', 'blank name rejected');
select * from pg_temp.manual_reject(3, null, 'No Phone', null, null,
  'phone', '22023', 'invalid manual inquiry input', 'missing phone rejected');
select * from pg_temp.manual_reject(3, '1100008008', 'Bad Phone', null, null,
  'phone', '22023', 'invalid manual inquiry input', 'non-normalized phone rejected');
select * from pg_temp.manual_reject(3, '+5491100008008', 'Blank Email', '   ', null,
  'phone', '22023', 'invalid manual inquiry input', 'blank email rejected');
select t.* from unnest(array[3, 4, 5, 99]) vehicle cross join lateral
  pg_temp.manual_reject(3, '+5491100008009', 'Invalid Vehicle', null, vehicle,
    'phone', '22023', 'vehicle must be Available and not deleted',
    'invalid vehicle: ' || vehicle) t;

-- The web submission keeps its own contract: email stays mandatory and origin web.
set local role service_role;
select throws_ok($$select public.submit_inquiry(gen_random_uuid(),
  md5('manual-vehicle-1')::uuid, '+5491100008010', 'Web Customer', '')$$,
  '22023', 'invalid inquiry input', 'web submission still requires email');
select lives_ok($$select public.submit_inquiry(md5('manual-web-submission')::uuid,
  md5('manual-vehicle-1')::uuid, '+5491100008011', 'Web Customer',
  'web@example.invalid')$$, 'web submission still succeeds');
reset role;
select is((select origin from public.inquiries where submission_id = md5('manual-web-submission')::uuid),
  'web'::public.inquiry_origin, 'web submission is recorded with web origin');

-- Direct mutations and unauthenticated execution stay blocked.
grant select on first_created, second_created, third_created, fourth_created to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub', md5('manual-actor-3')::uuid::text, true);
select throws_ok($$insert into public.inquiries (submission_id, contact_id, originating_vehicle_id,
  submitted_name, submitted_email)
  select gen_random_uuid(), md5('manual-contact')::uuid, md5('manual-vehicle-1')::uuid,
    'Direct', 'direct@example.invalid'$$, '42501', null, 'no direct inquiry insert grant');
select ok(exists (select 1 from public.inquiries where id = (select id from first_created)),
  'seller reads own manual inquiry');
select ok(not exists (select 1 from public.inquiries where id = (select id from second_created)),
  'seller cannot read another assignee manual inquiry');
reset role;
select ok(not has_function_privilege('anon',
  'public.create_manual_inquiry(text,text,text,uuid,public.inquiry_origin)', 'EXECUTE'),
  'anon has no manual inquiry execution privilege');
select ok(not exists (select 1 from pg_proc p, lateral aclexplode(p.proacl) a
  where p.oid = 'public.create_manual_inquiry(text,text,text,uuid,public.inquiry_origin)'::regprocedure
    and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'PUBLIC has no manual inquiry execution privilege');
select * from finish();
rollback;
