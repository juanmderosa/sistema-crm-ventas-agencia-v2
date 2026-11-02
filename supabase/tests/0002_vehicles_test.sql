begin;

create extension if not exists pgtap with schema extensions;

select plan(15);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-4000-8000-00000000b001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-4000-8000-00000000b002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'seller@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb),
  ('00000000-0000-4000-8000-00000000b003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'inactive@example.invalid', 'x', now(), '{}'::jsonb, '{}'::jsonb);

insert into public.profiles (id, role, display_name, is_active)
values
  ('00000000-0000-4000-8000-00000000b001', 'owner', 'Owner', true),
  ('00000000-0000-4000-8000-00000000b002', 'seller', 'Seller', true),
  ('00000000-0000-4000-8000-00000000b003', 'seller', 'Former Seller', false);

insert into public.vehicles (id, brand, model, year, publication_status, availability_status, deleted_at)
values
  ('00000000-0000-4000-8000-00000000c001', 'Toyota', 'Corolla', 2020, 'published', 'available', null),
  ('00000000-0000-4000-8000-00000000c002', 'Ford', 'Ranger', 2021, 'draft', 'available', null),
  ('00000000-0000-4000-8000-00000000c003', 'Fiat', 'Cronos', 2019, 'published', 'sold', null),
  ('00000000-0000-4000-8000-00000000c004', 'VW', 'Gol', 2018, 'published', 'available', now());

-- Structure.
select has_table('public', 'vehicles', 'vehicles table exists');
select enum_has_labels('public', 'vehicle_publication_status', array['draft', 'published'], 'publication status has draft and published');
select enum_has_labels('public', 'vehicle_availability_status', array['available', 'reserved', 'sold'], 'availability status has available, reserved and sold');
select is(
  (select relrowsecurity from pg_class where oid = 'public.vehicles'::regclass),
  true,
  'row level security is enabled on vehicles'
);

-- Anonymous visitors only see published, non-deleted rows.
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select is(
  (select count(*)::int from public.vehicles),
  2,
  'anon sees only the published available vehicle and the sold detail page'
);
select is(
  (select count(*)::int from public.vehicles where id = '00000000-0000-4000-8000-00000000c002'),
  0,
  'anon cannot see a draft vehicle'
);
select is(
  (select count(*)::int from public.vehicles where id = '00000000-0000-4000-8000-00000000c004'),
  0,
  'anon cannot see a soft-deleted vehicle'
);

-- Active sellers see the whole inventory, including drafts.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000b002","role":"authenticated"}';
select is((select count(*)::int from public.vehicles), 4, 'active seller reads all vehicles');

-- Sellers cannot mutate inventory directly.
select throws_ok(
  $$ insert into public.vehicles (brand, model, year) values ('Chevrolet', 'Onix', 2022) $$,
  '42501',
  null,
  'seller cannot insert a vehicle'
);
with attempted as (
  update public.vehicles set availability_status = 'sold' where id = '00000000-0000-4000-8000-00000000c001' returning 1
)
select is((select count(*)::int from attempted), 0, 'seller cannot mark a vehicle sold');
with attempted as (
  update public.vehicles set deleted_at = now() where id = '00000000-0000-4000-8000-00000000c001' returning 1
)
select is((select count(*)::int from attempted), 0, 'seller cannot soft-delete a vehicle');

-- A deactivated seller loses inventory access beyond public rows.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000b003","role":"authenticated"}';
select is((select count(*)::int from public.vehicles), 2, 'inactive seller sees only public rows');

-- Owner/Admin own inventory writes.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-00000000b001","role":"authenticated"}';
select lives_ok(
  $$ insert into public.vehicles (brand, model, year) values ('Chevrolet', 'Onix', 2022) $$,
  'owner can insert a vehicle'
);
with attempted as (
  update public.vehicles set publication_status = 'published' where id = '00000000-0000-4000-8000-00000000c002' returning 1
)
select is((select count(*)::int from attempted), 1, 'owner can publish a draft vehicle');

reset role;
select throws_ok(
  $$ insert into public.vehicles (brand, model, year) values ('Fiat', 'Uno', 1800) $$,
  '23514',
  null,
  'the year constraint rejects an impossible year'
);

select * from finish();
rollback;
