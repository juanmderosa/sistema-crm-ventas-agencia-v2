begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Synthetic identities; all fixtures roll back, with no real customer data.
insert into auth.users (id, email)
select md5('interest-actor-' || n)::uuid, 'interest-' || n || '@example.invalid'
from generate_series(1, 6) n;
insert into public.profiles (id, role, display_name, is_active)
select md5('interest-actor-' || n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,
  'Interest actor ' || n, n <> 5
from generate_series(1, 5) n;
insert into public.vehicles (id, brand, model, year, publication_status, availability_status, deleted_at)
select md5('interest-vehicle-' || n)::uuid, 'Test', 'Interest ' || n, 2020,
  (case when n = 2 then 'draft' else 'published' end)::public.vehicle_publication_status,
  (case n when 3 then 'reserved' when 4 then 'sold' else 'available' end)::public.vehicle_availability_status,
  case when n = 5 then now() end
from generate_series(1, 8) n;
insert into public.contacts (id, normalized_phone, display_name, email)
values (md5('interest-contact')::uuid, '+5491100007001', 'Synthetic', 'synthetic@example.invalid');
insert into public.inquiries (id, submission_id, contact_id, originating_vehicle_id,
  assignee_id, status, submitted_phone, submitted_name, submitted_email)
select md5('interest-inquiry-' || n)::uuid, md5('interest-submission-' || n)::uuid,
  md5('interest-contact')::uuid, md5('interest-vehicle-1')::uuid,
  case when n <> 6 then md5('interest-actor-3')::uuid end,
  (case n when 2 then 'contacted' when 3 then 'following_up'
    when 4 then 'sale_reported' when 5 then 'closed_without_sale' else 'new' end)::public.inquiry_status,
  '+5491100007001', 'Submitted', 'submitted@example.invalid'
from generate_series(1, 6) n;
insert into public.inquiry_interests (inquiry_id, vehicle_id)
select id, originating_vehicle_id from public.inquiries;
insert into public.vehicle_inquiry_rotation values
  (md5('interest-vehicle-1')::uuid, md5('interest-actor-3')::uuid);
insert into public.inquiry_assignment_history (inquiry_id, assignee_id, reason)
select id, assignee_id, case when assignee_id is null then 'unassigned' else 'rotation' end
from public.inquiries;

-- Read-only observations include complete rows and the inquiry allocation counter.
create function pg_temp.interest_state(include_interests boolean) returns text
language sql as $$
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.profiles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
    (select jsonb_agg(to_jsonb(t) order by vehicle_id, profile_id) from public.vehicle_inquiry_participants t),
    (select jsonb_agg(to_jsonb(t) order by vehicle_id) from public.vehicle_inquiry_rotation t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t),
    (select jsonb_build_array(last_value, is_called) from public.inquiries_creation_sequence_seq),
    case when include_interests then
      (select jsonb_agg(to_jsonb(t) order by inquiry_id, vehicle_id) from public.inquiry_interests t)
    end
  )::text);
$$;

create function pg_temp.interest_case(actor integer, inquiry integer, vehicle integer,
  expected_state text, expected_message text, label text, api_role text default 'authenticated')
returns setof text language plpgsql as $$
declare
  before_all text := pg_temp.interest_state(true);
  before_other text := pg_temp.interest_state(false);
  before_count bigint := (select count(*) from public.inquiry_interests);
  already_present boolean := exists (select 1 from public.inquiry_interests
    where inquiry_id = md5('interest-inquiry-' || inquiry)::uuid
      and vehicle_id = md5('interest-vehicle-' || vehicle)::uuid);
  observed_state text := '00000';
  observed_message text := '';
  response jsonb;
begin
  perform set_config('request.jwt.claim.sub', md5('interest-actor-' || actor)::uuid::text, true);
  perform set_config('role', api_role, true);
  begin
    select public.add_inquiry_interest(md5('interest-inquiry-' || inquiry)::uuid,
      md5('interest-vehicle-' || vehicle)::uuid) into response;
  exception when others then
    get stacked diagnostics observed_state = returned_sqlstate, observed_message = message_text;
  end;
  perform set_config('role', 'none', true);
  return next is(observed_state, expected_state, label || ': SQLSTATE');
  if expected_state = '00000' then
    return next is(response, '{"accepted":true}'::jsonb, label || ': minimal acknowledgement');
    return next is(pg_temp.interest_state(false), before_other, label || ': all other data and counter unchanged');
    return next is((select count(*) from public.inquiry_interests),
      before_count + case when already_present then 0 else 1 end, label || ': exact interest count');
    return next ok(exists (select 1 from public.inquiry_interests
      where inquiry_id = md5('interest-inquiry-' || inquiry)::uuid
        and vehicle_id = md5('interest-vehicle-' || vehicle)::uuid), label || ': requested link exists');
    if already_present then
      return next is(pg_temp.interest_state(true), before_all, label || ': retry preserves original timestamp');
    end if;
  else
    if expected_message is not null then
      return next is(observed_message, expected_message, label || ': exact error');
    end if;
    return next is(pg_temp.interest_state(true), before_all, label || ': rejected operation changes nothing');
  end if;
end;
$$;

select * from pg_temp.interest_case(3, 1, 2, '00000', null, 'seller adds draft Available interest');
select * from pg_temp.interest_case(3, 1, 2, '00000', null, 'identical retry');
select * from pg_temp.interest_case(3, 2, 2, '00000', null, 'Contacted is active');
select * from pg_temp.interest_case(3, 3, 2, '00000', null, 'Following up is active');
select * from pg_temp.interest_case(3, 1, 6, '00000', null, 'seller adds published Available interest');
select * from pg_temp.interest_case(1, 1, 7, '00000', null, 'Owner adds to another assignee inquiry');
select * from pg_temp.interest_case(2, 1, 8, '00000', null, 'Admin adds to another assignee inquiry');
select t.* from generate_series(1, 2) actor cross join lateral
pg_temp.interest_case(actor, 6, 2, '00000', null, 'administrative unassigned inquiry: ' || actor) t;
select t.* from generate_series(4, 6) actor cross join lateral
pg_temp.interest_case(actor, 1, 6, '42501', 'inquiry interest access denied', 'unauthorized identity: ' || actor) t;
select * from pg_temp.interest_case(3, 6, 6, '42501', 'inquiry interest access denied', 'seller cannot handle unassigned inquiry');
select t.* from generate_series(1, 3) actor cross join generate_series(4, 5) inquiry cross join lateral
pg_temp.interest_case(actor, inquiry, 6, '22023', 'inquiry is not active', 'closed inquiry: ' || actor || '/' || inquiry) t;
select t.* from generate_series(3, 5) vehicle cross join lateral
pg_temp.interest_case(3, 1, vehicle, '22023', 'vehicle must be Available and not deleted', 'invalid vehicle: ' || vehicle) t;
select * from pg_temp.interest_case(3, 1, 99, '22023', 'vehicle must be Available and not deleted', 'missing vehicle');
select * from pg_temp.interest_case(3, 99, 6, '42501', 'inquiry interest access denied', 'missing inquiry');
select * from pg_temp.interest_case(3, 1, 6, '42501', null, 'anonymous denied', 'anon');
update public.profiles set is_active = false where id = md5('interest-actor-2')::uuid;
select * from pg_temp.interest_case(2, 1, 6, '42501', 'inquiry interest access denied', 'inactive Admin denied');
update public.profiles set is_active = true where id = md5('interest-actor-2')::uuid;
-- An existing interest does not authorize a late retry after state changes.
update public.vehicles set availability_status = 'reserved' where id = md5('interest-vehicle-2')::uuid;
select * from pg_temp.interest_case(3, 1, 2, '22023', 'vehicle must be Available and not deleted', 'late unavailable retry');

set local role authenticated;
select set_config('request.jwt.claim.sub', md5('interest-actor-3')::uuid::text, true);
select is((select count(*) from public.inquiries), 5::bigint, 'seller still sees own inquiries only');
select throws_ok($$insert into public.inquiry_interests (inquiry_id, vehicle_id)
  values (md5('interest-inquiry-1')::uuid, md5('interest-vehicle-8')::uuid)$$,
  '42501', null, 'no direct insert grant');
select throws_ok($$delete from public.inquiry_interests$$, '42501', null, 'no interest removal grant');
reset role;
select ok(not has_function_privilege('anon', 'public.add_inquiry_interest(uuid,uuid)', 'EXECUTE'), 'anon has no execution privilege');
select ok(not exists (select 1 from pg_proc p, lateral aclexplode(p.proacl) a
  where p.oid = 'public.add_inquiry_interest(uuid,uuid)'::regprocedure
    and a.grantee = 0 and a.privilege_type = 'EXECUTE'), 'PUBLIC has no execution privilege');
select * from finish();
rollback;
