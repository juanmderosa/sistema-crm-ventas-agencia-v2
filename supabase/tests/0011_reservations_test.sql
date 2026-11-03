begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Synthetic identities, inventory and inquiries; every fixture rolls back.
insert into auth.users (id, email)
select md5('res-actor-' || n)::uuid, 'res-' || n || '@example.invalid'
from generate_series(1, 6) n;
insert into public.profiles (id, role, display_name, is_active)
select md5('res-actor-' || n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,
  'Reservation actor ' || n, n <> 5
from generate_series(1, 5) n;
insert into public.vehicles (id, brand, model, year, publication_status, availability_status,
  deleted_at, sale_enabled)
select md5('res-vehicle-' || n)::uuid, 'Test', 'Reservation ' || n, 2020, 'published',
  (case n when 3 then 'sold' else 'available' end)::public.vehicle_availability_status,
  case when n = 4 then now() end, n <> 6
from generate_series(1, 8) n;
insert into public.contacts (id, normalized_phone, display_name, email)
values (md5('res-contact-1')::uuid, '+5491100010001', 'Contact One', 'one@example.invalid'),
  (md5('res-contact-2')::uuid, '+5491100010002', 'Contact Two', 'two@example.invalid'),
  (md5('res-contact-3')::uuid, '+5491100010003', 'Contact Three', 'three@example.invalid'),
  (md5('res-contact-4')::uuid, '+5491100010004', 'Contact Four', 'four@example.invalid');
insert into public.inquiries (id, submission_id, contact_id, originating_vehicle_id,
  assignee_id, status, submitted_phone, submitted_name, submitted_email)
select md5('res-inquiry-' || n)::uuid, md5('res-submission-' || n)::uuid,
  md5('res-contact-' || (case when n > 2 then 1 else n end))::uuid,
  md5('res-vehicle-1')::uuid,
  (case when n = 2 then md5('res-actor-4')::uuid else md5('res-actor-3')::uuid end),
  (case n when 3 then 'closed_without_sale' when 4 then 'sale_reported' else 'new' end)::public.inquiry_status,
  '+5491100010001', 'Submitted', 'submitted@example.invalid'
from generate_series(1, 4) n;
insert into public.inquiry_interests (inquiry_id, vehicle_id)
select id, originating_vehicle_id from public.inquiries;
insert into public.inquiry_interests (inquiry_id, vehicle_id) values
  (md5('res-inquiry-1')::uuid, md5('res-vehicle-2')::uuid),
  (md5('res-inquiry-1')::uuid, md5('res-vehicle-3')::uuid),
  (md5('res-inquiry-1')::uuid, md5('res-vehicle-4')::uuid),
  (md5('res-inquiry-1')::uuid, md5('res-vehicle-5')::uuid),
  (md5('res-inquiry-1')::uuid, md5('res-vehicle-6')::uuid),
  (md5('res-inquiry-2')::uuid, md5('res-vehicle-2')::uuid),
  (md5('res-inquiry-2')::uuid, md5('res-vehicle-7')::uuid);

-- Complete-state hash includes reservation history and the inquiry counter.
create function pg_temp.res_state() returns text
language sql as $$
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
    (select jsonb_agg(to_jsonb(t) order by inquiry_id, vehicle_id) from public.inquiry_interests t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
    (select jsonb_build_array(last_value, is_called) from public.inquiries_creation_sequence_seq)
  )::text);
$$;

create function pg_temp.res_actor(n integer) returns text
language sql as $$
  select md5('res-actor-' || n)::uuid::text;
$$;

create function pg_temp.res_reserve(actor integer, inquiry integer, vehicle integer,
  expected_state text, expected_message text, label text, api_role text default 'authenticated')
returns setof text language plpgsql as $$
declare
  before_all text := pg_temp.res_state();
  observed_state text := '00000';
  observed_message text := '';
begin
  perform set_config('request.jwt.claim.sub', pg_temp.res_actor(actor), true);
  perform set_config('role', api_role, true);
  begin
    perform public.reserve_inquiry_vehicle(md5('res-inquiry-' || inquiry)::uuid,
      md5('res-vehicle-' || vehicle)::uuid);
  exception when others then
    get stacked diagnostics observed_state = returned_sqlstate, observed_message = message_text;
  end;
  perform set_config('role', 'none', true);
  return next is(observed_state, expected_state, label || ': SQLSTATE');
  if expected_state = '00000' then
    return next is((select count(*) from public.reservations
      where inquiry_id = md5('res-inquiry-' || inquiry)::uuid
        and vehicle_id = md5('res-vehicle-' || vehicle)::uuid
        and status = 'active'), 1::bigint, label || ': one active reservation');
    return next is((select availability_status from public.vehicles
      where id = md5('res-vehicle-' || vehicle)::uuid),
      'reserved'::public.vehicle_availability_status, label || ': vehicle becomes Reserved');
    return next is((select r.contact_id from public.reservations r
      where r.vehicle_id = md5('res-vehicle-' || vehicle)::uuid and r.status = 'active'),
      (select contact_id from public.inquiries where id = md5('res-inquiry-' || inquiry)::uuid),
      label || ': reservation copies the inquiry contact');
    return next is((select r.created_by from public.reservations r
      where r.vehicle_id = md5('res-vehicle-' || vehicle)::uuid and r.status = 'active'),
      md5('res-actor-' || actor)::uuid, label || ': reservation records its creator');
  else
    if expected_message is not null then
      return next is(observed_message, expected_message, label || ': exact error');
    end if;
    return next is(pg_temp.res_state(), before_all, label || ': rejected operation changes nothing');
  end if;
end;
$$;

-- Seller reserves an Available interest from the own active inquiry.
select * from pg_temp.res_reserve(3, 1, 1, '00000', null, 'seller reserves own interest');
select * from pg_temp.res_reserve(3, 1, 2, '23505', 'an active reservation already exists',
  'same inquiry cannot hold a second reservation');
select * from pg_temp.res_reserve(4, 2, 1, '22023', 'vehicle must be Available and enabled for sale',
  'another inquiry cannot take a vehicle already reserved');
select * from pg_temp.res_reserve(4, 1, 2, '42501', 'reservation access denied',
  'seller cannot reserve from a coworker inquiry');
select * from pg_temp.res_reserve(1, 2, 2, '00000', null, 'Owner reserves on another assignee inquiry');
select * from pg_temp.res_reserve(2, 2, 7, '23505', 'an active reservation already exists',
  'Admin cannot add a second reservation to the same inquiry');
select * from pg_temp.res_reserve(3, 4, 1, '22023', 'inquiry is not active',
  'sale-reported inquiry cannot reserve');
select * from pg_temp.res_reserve(3, 3, 1, '22023', 'inquiry is not active',
  'closed inquiry cannot reserve');
select * from pg_temp.res_reserve(5, 1, 1, '42501', 'reservation access denied', 'inactive seller denied');
select * from pg_temp.res_reserve(6, 1, 1, '42501', 'reservation access denied',
  'identity without profile denied');
select * from pg_temp.res_reserve(3, 99, 1, '42501', 'reservation access denied', 'missing inquiry denied');
select * from pg_temp.res_reserve(3, 1, 3, '22023', 'vehicle must be Available and enabled for sale',
  'Sold vehicle rejected');
select * from pg_temp.res_reserve(3, 1, 4, '22023', 'vehicle must be Available and enabled for sale',
  'soft-deleted vehicle rejected');
select * from pg_temp.res_reserve(3, 1, 6, '22023', 'vehicle must be Available and enabled for sale',
  'blocked vehicle rejected');
select * from pg_temp.res_reserve(3, 1, 5, '23505', 'an active reservation already exists',
  'second reservation needs the first cancelled');
select * from pg_temp.res_reserve(3, 1, 8, '22023', 'vehicle is not an interest of this inquiry',
  'unlisted vehicle is rejected');
select * from pg_temp.res_reserve(4, 2, 3, '22023', 'vehicle must be Available and enabled for sale',
  'Sold vehicle rejected for a different inquiry');

-- Cancellation restores availability and retains history.
create temp table active_one as
select id from public.reservations where inquiry_id = md5('res-inquiry-1')::uuid
  and vehicle_id = md5('res-vehicle-1')::uuid and status = 'active';

create function pg_temp.res_cancel(actor integer, reservation uuid,
  expected_state text, expected_message text, label text, api_role text default 'authenticated')
returns setof text language plpgsql as $$
declare
  before_all text := pg_temp.res_state();
  observed_state text := '00000';
  observed_message text := '';
begin
  perform set_config('request.jwt.claim.sub', pg_temp.res_actor(actor), true);
  perform set_config('role', api_role, true);
  begin
    perform public.cancel_reservation(reservation);
  exception when others then
    get stacked diagnostics observed_state = returned_sqlstate, observed_message = message_text;
  end;
  perform set_config('role', 'none', true);
  return next is(observed_state, expected_state, label || ': SQLSTATE');
  if expected_state = '00000' then
    return next is((select status from public.reservations where id = reservation),
      'cancelled'::public.reservation_status, label || ': reservation is cancelled');
    return next ok((select ended_at is not null and cancelled_by = md5('res-actor-' || actor)::uuid
      from public.reservations where id = reservation), label || ': cancellation is attributed');
    return next is((select availability_status from public.vehicles v
      join public.reservations r on r.vehicle_id = v.id where r.id = reservation),
      'available'::public.vehicle_availability_status, label || ': vehicle returns to Available');
  else
    if expected_message is not null then
      return next is(observed_message, expected_message, label || ': exact error');
    end if;
    return next is(pg_temp.res_state(), before_all, label || ': rejected operation changes nothing');
  end if;
end;
$$;

select * from pg_temp.res_cancel(4, (select id from active_one), '42501',
  'reservation access denied', 'seller cannot cancel a coworker reservation');
select * from pg_temp.res_cancel(5, (select id from active_one), '42501',
  'reservation access denied', 'inactive seller cannot cancel through a stale session');
select * from pg_temp.res_cancel(3, (select id from active_one), '00000', null,
  'creator seller cancels the own reservation');
select is((select count(*) from public.reservations
  where vehicle_id = md5('res-vehicle-1')::uuid and status = 'active'), 0::bigint,
  'no active reservation remains after cancellation');
select * from pg_temp.res_cancel(3, (select id from active_one), '22023',
  'reservation is not active', 'second cancellation rejected');
select * from pg_temp.res_reserve(3, 1, 5, '00000', null,
  'cancelling first lets the same inquiry reserve another vehicle');

-- Direct state changes cannot bypass reservation invariants.
create temp table admin_reserved as
select id from public.reservations where vehicle_id = md5('res-vehicle-2')::uuid and status = 'active';

set local role authenticated;
select set_config('request.jwt.claim.sub', pg_temp.res_actor(4), true);
with changed as (
  update public.vehicles set availability_status = 'available'
  where id = md5('res-vehicle-2')::uuid returning 1
)
select is((select count(*) from changed), 0::bigint,
  'seller direct inventory update affects no row');
reset role;

select throws_ok($$update public.vehicles set availability_status = 'sold'
  where id = md5('res-vehicle-2')::uuid$$, '22023',
  'cancel the active reservation before changing availability',
  'active reservation blocks selling through the inventory path');
select throws_ok($$update public.vehicles set deleted_at = now()
  where id = md5('res-vehicle-2')::uuid$$, '22023',
  'cancel the active reservation before deleting the vehicle',
  'active reservation blocks soft deletion');
select throws_ok($$update public.inquiries set assignee_id = md5('res-actor-3')::uuid
  where id = md5('res-inquiry-2')::uuid$$, '22023',
  'cancel the active reservation before reassigning the inquiry',
  'active reservation blocks reassignment');
select throws_ok($$update public.inquiries set contact_id = md5('res-contact-3')::uuid
  where id = md5('res-inquiry-2')::uuid$$, '22023',
  'cancel the active reservation before changing the inquiry contact',
  'active reservation blocks changing the inquiry contact');
select throws_ok($$update public.inquiries set status = 'closed_without_sale'
  where id = md5('res-inquiry-2')::uuid$$, '22023',
  'cancel the active reservation before closing the inquiry without a sale',
  'active reservation blocks closure without sale');
update public.inquiries set status = 'sale_reported' where id = md5('res-inquiry-2')::uuid;
select is((select status from public.inquiries where id = md5('res-inquiry-2')::uuid),
  'sale_reported'::public.inquiry_status, 'reporting a sale stays allowed while reserved');

-- Owner cancels any active reservation, including one they did not create.
select * from pg_temp.res_cancel(1, (select id from admin_reserved), '00000', null,
  'Owner cancels another creator reservation');
update public.vehicles set deleted_at = now() where id = md5('res-vehicle-2')::uuid;
select ok((select deleted_at is not null from public.vehicles where id = md5('res-vehicle-2')::uuid),
  'soft deletion succeeds once the reservation is cancelled');
create temp table seller_reserved as
select id from public.reservations
where vehicle_id = md5('res-vehicle-5')::uuid and status = 'active';
select * from pg_temp.res_cancel(1, (select id from seller_reserved), '00000', null,
  'Owner cancels a seller-created reservation');

-- Read isolation and privilege boundaries.
grant select on active_one, admin_reserved, seller_reserved to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub', pg_temp.res_actor(4), true);
select is((select count(*) from public.reservations
  where inquiry_id = md5('res-inquiry-1')::uuid), 0::bigint,
  'seller cannot read a coworker reservation');
select throws_ok($$insert into public.reservations (inquiry_id, vehicle_id, contact_id, created_by)
  values (md5('res-inquiry-2')::uuid, md5('res-vehicle-7')::uuid,
    md5('res-contact-2')::uuid, md5('res-actor-4')::uuid)$$,
  '42501', null, 'no direct reservation insert grant');
select throws_ok($$update public.reservations set status = 'cancelled'$$,
  '42501', null, 'no direct reservation update grant');
reset role;
select set_config('request.jwt.claim.sub', pg_temp.res_actor(1), true);
set local role authenticated;
select ok((select count(*) from public.reservations) > 0, 'Owner reads reservation history');
reset role;
select ok(not has_function_privilege('anon',
  'public.reserve_inquiry_vehicle(uuid,uuid)', 'EXECUTE'), 'anon cannot reserve');
select ok(not has_function_privilege('anon',
  'public.cancel_reservation(uuid)', 'EXECUTE'), 'anon cannot cancel');
select * from finish();
rollback;
