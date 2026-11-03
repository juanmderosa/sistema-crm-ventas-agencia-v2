begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Synthetic identities and inventory; every fixture rolls back.
insert into auth.users (id, email)
select md5('block-actor-' || n)::uuid, 'block-' || n || '@example.invalid'
from generate_series(1, 5) n;
insert into public.profiles (id, role, display_name, is_active)
select md5('block-actor-' || n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' when 4 then 'owner' else 'seller' end)::public.user_role,
  'Block actor ' || n, n <> 4
from generate_series(1, 4) n;
insert into public.vehicles (id, brand, model, year, publication_status, availability_status, deleted_at)
values
  (md5('block-vehicle-1')::uuid, 'Test', 'Block 1', 2020, 'published', 'available', null),
  (md5('block-vehicle-2')::uuid, 'Test', 'Block 2', 2020, 'draft', 'available', null),
  (md5('block-vehicle-3')::uuid, 'Test', 'Block 3', 2020, 'published', 'available', null),
  (md5('block-vehicle-4')::uuid, 'Test', 'Block 4', 2020, 'published', 'available', now()),
  (md5('block-vehicle-5')::uuid, 'Test', 'Block 5', 2020, 'published', 'sold', null),
  (md5('block-vehicle-6')::uuid, 'Test', 'Block 6', 2020, 'published', 'available', null);
insert into public.contacts (id, normalized_phone, display_name, email)
values (md5('block-contact')::uuid, '+5491100030001', 'Block Contact', 'block@example.invalid');
insert into public.inquiries (id, submission_id, contact_id, originating_vehicle_id,
  assignee_id, status, submitted_phone, submitted_name, submitted_email)
values (md5('block-inquiry')::uuid, md5('block-submission')::uuid, md5('block-contact')::uuid,
  md5('block-vehicle-3')::uuid, md5('block-actor-3')::uuid, 'new',
  '+5491100030001', 'Block Contact', 'block@example.invalid');
insert into public.inquiry_interests (inquiry_id, vehicle_id)
values (md5('block-inquiry')::uuid, md5('block-vehicle-3')::uuid);

create function pg_temp.block_state() returns text
language sql as $$
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t)
  )::text);
$$;

create function pg_temp.block_actor(n integer) returns text
language sql as $$
  select md5('block-actor-' || n)::uuid::text;
$$;

create function pg_temp.block_try(actor integer, vehicle integer, blocked boolean,
  expected_state text, expected_message text, label text, api_role text default 'authenticated')
returns setof text
language plpgsql as $$
declare
  before_all text := pg_temp.block_state();
  observed_state text := '00000';
  observed_message text := '';
begin
  perform set_config('request.jwt.claim.sub', pg_temp.block_actor(actor), true);
  perform set_config('role', api_role, true);
  begin
    perform public.set_vehicle_sale_blocked(
      case when vehicle is null then null else md5('block-vehicle-' || vehicle)::uuid end,
      blocked);
  exception when others then
    get stacked diagnostics observed_state = returned_sqlstate,
      observed_message = message_text;
  end;
  perform set_config('role', 'none', true);
  return next is(observed_state, expected_state, label || ': SQLSTATE');
  if expected_message is not null then
    return next is(observed_message, expected_message, label || ': exact error');
  end if;
  if expected_state = '00000' then
    return next is((select sale_enabled from public.vehicles
      where id = md5('block-vehicle-' || vehicle)::uuid), not blocked,
      label || ': sale flag follows the request');
  else
    return next is(pg_temp.block_state(), before_all,
      label || ': rejected operation changes nothing');
  end if;
end;
$$;

-- A real reservation on vehicle 3 anchors the blocking rejection.
select set_config('request.jwt.claim.sub', pg_temp.block_actor(1), true);
set local role authenticated;
select public.reserve_inquiry_vehicle(md5('block-inquiry')::uuid, md5('block-vehicle-3')::uuid);
reset role;

select is((select sale_enabled from public.vehicles where id = md5('block-vehicle-5')::uuid),
  true, 'existing vehicles are sale enabled by default');

select set_config('request.jwt.claim.sub', '', true);
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select is((select count(*)::int from public.vehicles), 4,
  'public catalog shows published, non-deleted, enabled vehicles');
reset role;

-- Owner blocks published inventory; availability and publication are untouched.
select * from pg_temp.block_try(1, 1, true, '00000', null, 'owner blocks published vehicle');
select is((select availability_status from public.vehicles where id = md5('block-vehicle-1')::uuid),
  'available'::public.vehicle_availability_status, 'blocking does not change availability');
select is((select publication_status from public.vehicles where id = md5('block-vehicle-1')::uuid),
  'published'::public.vehicle_publication_status, 'blocking does not change publication');

select set_config('request.jwt.claim.sub', '', true);
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select is((select count(*)::int from public.vehicles), 3,
  'blocked vehicle leaves the public catalog');
select is((select count(*)::int from public.vehicles where id = md5('block-vehicle-1')::uuid),
  0, 'blocked vehicle is not readable by an anonymous visitor');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', pg_temp.block_actor(1), true);
select is((select count(*)::int from public.vehicles), 6,
  'active staff keep the complete private inventory');
select is((select sale_enabled from public.vehicles where id = md5('block-vehicle-1')::uuid),
  false, 'blocked state stays visible to staff');
reset role;

-- Owner enables it again and it returns to the public catalog.
select * from pg_temp.block_try(1, 1, false, '00000', null, 'owner enables the vehicle');
select set_config('request.jwt.claim.sub', '', true);
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select is((select count(*)::int from public.vehicles), 4,
  'enabled vehicle returns to the public catalog');
reset role;

-- Admin may block draft inventory without publishing it.
select * from pg_temp.block_try(2, 2, true, '00000', null, 'admin blocks draft vehicle');
select is((select publication_status from public.vehicles where id = md5('block-vehicle-2')::uuid),
  'draft'::public.vehicle_publication_status, 'blocking a draft keeps it a draft');

-- Only Owner and Admin may change the sale flag.
select * from pg_temp.block_try(3, 1, true, '42501', 'vehicle sale access denied',
  'seller cannot block');
select * from pg_temp.block_try(4, 1, true, '42501', 'vehicle sale access denied',
  'inactive owner cannot block');
select * from pg_temp.block_try(5, 1, true, '42501', 'vehicle sale access denied',
  'identity without profile cannot block');
select * from pg_temp.block_try(5, 1, true, '42501', null,
  'anonymous caller cannot block', 'anon');
select * from pg_temp.block_try(1, 1, null, '22023', 'invalid vehicle sale input',
  'missing block flag rejected');

-- An active reservation must be resolved explicitly before blocking.
select * from pg_temp.block_try(1, 3, true, '22023',
  'cancel the active reservation before blocking the vehicle',
  'blocking a reserved vehicle is rejected');
select * from pg_temp.block_try(2, 3, true, '22023',
  'cancel the active reservation before blocking the vehicle',
  'admin blocking a reserved vehicle is rejected');

-- The generic Owner/Admin inventory update cannot bypass that rule.
set local role authenticated;
select set_config('request.jwt.claim.sub', pg_temp.block_actor(1), true);
select throws_ok($$update public.vehicles set sale_enabled = false
  where id = md5('block-vehicle-3')::uuid$$, '22023',
  'cancel the active reservation before blocking the vehicle',
  'direct owner update cannot bypass blocking');
reset role;
select throws_ok($$update public.vehicles set sale_enabled = false
  where id = md5('block-vehicle-3')::uuid$$, '22023',
  'cancel the active reservation before blocking the vehicle',
  'service role cannot bypass blocking');
select is((select sale_enabled from public.vehicles where id = md5('block-vehicle-3')::uuid),
  true, 'bypassed attempts leave the sale flag unchanged');

-- Missing and soft-deleted inventory is rejected.
select * from pg_temp.block_try(1, 99, true, '22023', 'vehicle not found or deleted',
  'missing vehicle rejected');
select * from pg_temp.block_try(1, 4, true, '22023', 'vehicle not found or deleted',
  'soft-deleted vehicle cannot be blocked');
select * from pg_temp.block_try(1, 5, true, '00000', null, 'sold vehicle can be blocked');
select is((select availability_status from public.vehicles where id = md5('block-vehicle-5')::uuid),
  'sold'::public.vehicle_availability_status, 'blocking a sold vehicle keeps it sold');

-- Cancelling the reservation releases the block, and a blocked vehicle cannot be reserved.
select set_config('request.jwt.claim.sub', pg_temp.block_actor(1), true);
set local role authenticated;
select public.cancel_reservation(
  (select id from public.reservations where vehicle_id = md5('block-vehicle-3')::uuid
    and status = 'active'));
reset role;
select * from pg_temp.block_try(1, 3, true, '00000', null,
  'blocking succeeds once the reservation is cancelled');
select throws_ok($$select public.reserve_inquiry_vehicle(
  md5('block-inquiry')::uuid, md5('block-vehicle-3')::uuid)$$, '22023',
  'vehicle must be Available and enabled for sale',
  'blocked vehicle cannot be reserved');
select * from pg_temp.block_try(1, 3, false, '00000', null, 'owner enables the vehicle again');
select set_config('request.jwt.claim.sub', pg_temp.block_actor(3), true);
set local role authenticated;
select lives_ok($$select public.reserve_inquiry_vehicle(
  md5('block-inquiry')::uuid, md5('block-vehicle-3')::uuid)$$,
  'enabled vehicle can be reserved again');
reset role;
select is((select count(*) from public.reservations
  where vehicle_id = md5('block-vehicle-3')::uuid and status = 'active'), 1::bigint,
  'only one active reservation exists after unblocking');

-- Execution privileges stay controlled.
select ok(not has_function_privilege('anon',
  'public.set_vehicle_sale_blocked(uuid, boolean)', 'EXECUTE'),
  'anon has no blocking execution privilege');
select ok(not exists (select 1 from pg_proc p, lateral aclexplode(p.proacl) a
  where p.oid = 'public.set_vehicle_sale_blocked(uuid, boolean)'::regprocedure
    and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'PUBLIC has no blocking execution privilege');
select ok(has_function_privilege('authenticated',
  'public.set_vehicle_sale_blocked(uuid, boolean)', 'EXECUTE'),
  'authenticated staff may call the controlled operation');
select * from finish();
rollback;
