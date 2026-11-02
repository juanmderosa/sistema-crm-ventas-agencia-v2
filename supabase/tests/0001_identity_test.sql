begin;

create extension if not exists pgtap with schema extensions;

select plan(21);

-- Staff fixtures: one Owner, one Admin, one Seller.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-4000-8000-00000000a001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner1@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-4000-8000-00000000a002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin1@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-4000-8000-00000000a003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'seller1@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-4000-8000-00000000a004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'seller2@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, role, display_name)
values
  ('00000000-0000-4000-8000-00000000a001', 'owner', 'Owner One'),
  ('00000000-0000-4000-8000-00000000a002', 'admin', 'Admin One'),
  ('00000000-0000-4000-8000-00000000a003', 'seller', 'Seller One');

-- S1: exactly three staff roles.
select has_type('public', 'user_role', 'user_role type exists');
select enum_has_labels('public', 'user_role', array['owner', 'admin', 'seller'], 'user_role has exactly owner, admin and seller');

-- S2: one profile per auth user, with required fields.
select has_table('public', 'profiles', 'profiles table exists');
select col_not_null('public', 'profiles', 'role', 'profile role is required');
select col_not_null('public', 'profiles', 'display_name', 'profile display name is required');
select has_fk('public', 'profiles', 'profile references an auth user');
select is(
  (select count(*)::int from public.profiles),
  3,
  'one profile exists per seeded staff account'
);

-- S3: row level security is enabled and enforced for the API roles.
select is(
  (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass),
  true,
  'row level security is enabled on profiles'
);

-- S3: a seller only reads its own profile.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000a003","role":"authenticated"}';

select is((select count(*)::int from public.profiles), 1, 'seller reads exactly one profile');
select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-4000-8000-00000000a001'),
  0,
  'seller cannot read the owner profile'
);

-- S4: a seller cannot mutate staff profiles.
with attempted as (
  update public.profiles set display_name = 'hacked' where id = '00000000-0000-4000-8000-00000000a001' returning 1
)
select is((select count(*)::int from attempted), 0, 'seller cannot update another profile');

-- S6: no public signup insert path.
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok(
  $$ insert into public.profiles (id, role, display_name) values ('00000000-0000-4000-8000-00000000a003', 'owner', 'Anon Owner') $$,
  '42501',
  null,
  'anon cannot insert a profile'
);

-- S3: Owner/Admin read every profile.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}';
select is((select count(*)::int from public.profiles), 3, 'owner reads every profile');

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000a002","role":"authenticated"}';
select is((select count(*)::int from public.profiles), 3, 'admin reads every profile');

-- S4: Owner/Admin can update staff profiles.
with attempted as (
  update public.profiles set display_name = 'Admin Renamed' where id = '00000000-0000-4000-8000-00000000a002' returning 1
)
select is((select count(*)::int from attempted), 1, 'admin can update a profile');

-- S4: a seller cannot promote itself.
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000a003","role":"authenticated"}';
with attempted as (
  update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000a003' returning 1
)
select is((select count(*)::int from attempted), 0, 'seller cannot promote itself');

-- S5: the last active owner is protected.
reset role;
select throws_ok(
  $$ update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000a001' $$,
  '23514',
  null,
  'the last active owner cannot be demoted'
);
select throws_ok(
  $$ update public.profiles set is_active = false where id = '00000000-0000-4000-8000-00000000a001' $$,
  '23514',
  null,
  'the last active owner cannot be deactivated'
);
select throws_ok(
  $$ delete from public.profiles where id = '00000000-0000-4000-8000-00000000a001' $$,
  '23514',
  null,
  'the last active owner cannot be deleted'
);

-- S5: with a second active owner, the first may step down.
insert into public.profiles (id, role, display_name)
values ('00000000-0000-4000-8000-00000000a004', 'owner', 'Owner Two');
select lives_ok(
  $$ update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000a001' $$,
  'an owner may step down while another active owner remains'
);

-- S2: a profile cannot exist without its auth user.
select throws_ok(
  $$ insert into public.profiles (id, role, display_name) values ('00000000-0000-4000-8000-00000000ffff', 'seller', 'Orphan') $$,
  '23503',
  null,
  'a profile requires an existing auth user'
);

select * from finish();
rollback;
