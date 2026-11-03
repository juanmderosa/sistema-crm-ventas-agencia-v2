begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select has_function('public', 'report_inquiry_sale', array['uuid', 'uuid']);
-- Deterministic disposable actors include inactive and profile-less identities.
insert into auth.users (id, email)
select md5('sale-actor-' || n)::uuid, 'sale-' || n || '@example.invalid'
from generate_series(1, 6) n;
insert into public.profiles (id, role, display_name, is_active)
select md5('sale-actor-' || n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,
  'Sale actor ' || n, n <> 5 from generate_series(1, 5) n;
insert into public.vehicles (id, brand, model, year, publication_status, sale_enabled, deleted_at)
select md5('sale-vehicle-' || n)::uuid, 'Test', 'Sale ' || n, 2020, 'published', n <> 5,
  case when n = 6 then now() end from generate_series(1, 8) n;
insert into public.contacts (id, normalized_phone, display_name)
values (md5('sale-contact')::uuid, '+5491188887777', 'Sale contact');
insert into public.inquiries (id, submission_id, contact_id, originating_vehicle_id,
  assignee_id, submitted_phone, submitted_name, submitted_email)
select md5('sale-inquiry-' || n)::uuid, md5('sale-submission-' || n)::uuid,
  md5('sale-contact')::uuid, md5('sale-vehicle-1')::uuid,
  md5('sale-actor-' || case when n = 2 then 4 else 3 end)::uuid,
  '+5491188887777', 'Submitted', 'sale@example.invalid'
from generate_series(1, 6) n;
insert into public.inquiry_interests (inquiry_id, vehicle_id)
select md5('sale-inquiry-' || i)::uuid, md5('sale-vehicle-' || v)::uuid
from generate_series(1, 6) i cross join generate_series(1, 6) v;

create function pg_temp.sale_state() returns text language sql as $$
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.sale_reviews t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_status_history t)
  )::text);
$$;
create function pg_temp.report_sale(actor integer, inquiry integer, vehicle integer,
  expected text, label text, api_role text default 'authenticated')
returns setof text language plpgsql as $$
declare before_all text := pg_temp.sale_state(); observed text := '00000';
begin
  perform set_config('request.jwt.claim.sub', md5('sale-actor-' || actor)::uuid::text, true);
  perform set_config('role', api_role, true);
  begin
    perform public.report_inquiry_sale(md5('sale-inquiry-' || inquiry)::uuid,
      md5('sale-vehicle-' || vehicle)::uuid);
  exception when others then get stacked diagnostics observed = returned_sqlstate;
  end;
  perform set_config('role', 'none', true);
  return next is(observed, expected, label || ': SQLSTATE');
  if expected <> '00000' then
    return next is(pg_temp.sale_state(), before_all, label || ': rejected state unchanged');
  end if;
end;
$$;

select * from pg_temp.report_sale(4,1,1,'42501','coworker denied');
select * from pg_temp.report_sale(5,1,1,'42501','inactive denied');
select * from pg_temp.report_sale(6,1,1,'42501','profile-less denied');
select * from pg_temp.report_sale(3,1,1,'42501','anonymous denied','anon');
select * from pg_temp.report_sale(3,99,1,'42501','missing inquiry denied');
select * from pg_temp.report_sale(3,1,5,'22023','blocked vehicle denied');
select * from pg_temp.report_sale(3,1,6,'22023','deleted vehicle denied');
select * from pg_temp.report_sale(3,1,7,'22023','unlisted interest denied');
select * from pg_temp.report_sale(3,1,99,'22023','missing vehicle denied');
select * from pg_temp.report_sale(3,1,2,'00000','seller reports added interest without reservation');
select is((select availability_status::text from public.vehicles where id=md5('sale-vehicle-2')::uuid),
  'available', 'report does not sell or reserve inventory');
select is((select status::text from public.inquiries where id=md5('sale-inquiry-1')::uuid),
  'sale_reported', 'report closes inquiry as reported, not confirmed');
select is((select count(*) from public.sale_reviews where inquiry_id=md5('sale-inquiry-1')::uuid
  and vehicle_id=md5('sale-vehicle-2')::uuid and status='pending'
  and reported_by=md5('sale-actor-3')::uuid and contact_id=md5('sale-contact')::uuid),
  1::bigint, 'pending task binds exact inquiry, vehicle, contact and reporter');
select is((select count(*) from public.inquiry_status_history where inquiry_id=md5('sale-inquiry-1')::uuid
  and from_status='new' and to_status='sale_reported' and actor_id=md5('sale-actor-3')::uuid),
  1::bigint, 'status transition preserves actor and prior state');
select * from pg_temp.report_sale(3,1,2,'00000','identical report retry');
select is((select count(*) from public.sale_reviews),1::bigint,'retry creates no duplicate task');
select is((select count(*) from public.inquiry_status_history),1::bigint,'retry creates no duplicate history');
select set_config('request.jwt.claim.sub', md5('sale-actor-4')::uuid::text, true);
set local role authenticated;
select public.reserve_inquiry_vehicle(md5('sale-inquiry-2')::uuid,md5('sale-vehicle-2')::uuid);
reset role;
select * from pg_temp.report_sale(3,1,2,'00000','identical pending retry survives competing reservation');
select is((select count(*) from public.sale_reviews),1::bigint,'competing-reservation retry creates no task');
select is((select count(*) from public.inquiry_status_history),1::bigint,'competing-reservation retry creates no history');
select is((select count(*) from public.reservations where inquiry_id=md5('sale-inquiry-2')::uuid
  and vehicle_id=md5('sale-vehicle-2')::uuid and status='active'),1::bigint,
  'retry preserves competing active reservation');
select set_config('request.jwt.claim.sub', md5('sale-actor-4')::uuid::text, true);
set local role authenticated;
select public.cancel_reservation((select id from public.reservations
  where inquiry_id=md5('sale-inquiry-2')::uuid and status='active'));
reset role;
select * from pg_temp.report_sale(3,1,1,'22023','different retry denied');

select set_config('request.jwt.claim.sub', md5('sale-actor-4')::uuid::text, true);
set local role authenticated;
select public.reserve_inquiry_vehicle(md5('sale-inquiry-2')::uuid,md5('sale-vehicle-3')::uuid);
reset role;
select * from pg_temp.report_sale(3,3,3,'22023','competing reservation denied');
select * from pg_temp.report_sale(4,2,2,'22023','own reservation requires reserved vehicle');
select * from pg_temp.report_sale(4,2,3,'00000','own reserved interest can be reported');
select is((select status::text from public.reservations where inquiry_id=md5('sale-inquiry-2')::uuid and status='active'),
  'active','report retains active reservation');
select is((select availability_status::text from public.vehicles where id=md5('sale-vehicle-3')::uuid),
  'reserved','report preserves Reserved availability');
select * from pg_temp.report_sale(1,3,1,'00000','Owner can report another assignee inquiry');
select * from pg_temp.report_sale(2,4,4,'00000','Admin can report another assignee inquiry');
update public.inquiries set status='closed_without_sale' where id=md5('sale-inquiry-5')::uuid;
select * from pg_temp.report_sale(3,5,1,'22023','closed inquiry denied');

select set_config('request.jwt.claim.sub', md5('sale-actor-3')::uuid::text, true);
set local role authenticated;
select is((select count(*) from public.sale_reviews),3::bigint,'seller reads only own inquiry reviews');
select throws_ok($$update public.sale_reviews set status='confirmed'$$,'42501',null,
  'seller cannot resolve task directly');
select throws_ok($$delete from public.inquiry_status_history$$,'42501',null,'history cannot be deleted');
reset role;
select set_config('request.jwt.claim.sub', md5('sale-actor-1')::uuid::text, true);
set local role authenticated;
select is((select count(*) from public.sale_reviews),4::bigint,'Owner sees global review queue');
select throws_ok($$update public.sale_reviews set status='confirmed'$$,'42501',null,
  'Owner must use controlled review resolution');
reset role;
select set_config('request.jwt.claim.sub', md5('sale-actor-5')::uuid::text, true);
set local role authenticated;
select is((select count(*) from public.sale_reviews),0::bigint,'inactive staff sees no review');
reset role;
select * from finish();
rollback;
