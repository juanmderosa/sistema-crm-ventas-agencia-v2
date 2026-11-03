begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Independent verification probes for S17/S18/S19/S19a (manual inquiry creation).
insert into auth.users (id, email)
select md5('v-actor-'||n)::uuid, 'v'||n||'@example.invalid' from generate_series(1,4) n;
insert into public.profiles (id, role, display_name, is_active)
select md5('v-actor-'||n)::uuid,
  (case n when 1 then 'owner' else 'seller' end)::public.user_role, 'V '||n, n <> 3
from generate_series(1,3) n;
insert into public.vehicles (id, brand, model, year, publication_status, availability_status)
select md5('v-veh-'||n)::uuid, 'Brand', 'V '||n, 2024, 'published',
  (case when n = 3 then 'sold' else 'available' end)::public.vehicle_availability_status from generate_series(1,3) n;
insert into public.vehicle_inquiry_rotation (vehicle_id, last_assignee_id)
values (md5('v-veh-1')::uuid, md5('v-actor-2')::uuid);
insert into public.contacts (id, normalized_phone, display_name, email)
values (md5('v-c1')::uuid, '+5491100050001', 'V Stored', 'v1@example.invalid');
insert into public.contacts (id, normalized_phone, display_name, email)
values (md5('v-c2')::uuid, '+5491100050002', 'V No Email', null);

create function pg_temp.vstate() returns text language sql as $f$
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.profiles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
    (select jsonb_agg(to_jsonb(t) order by inquiry_id, vehicle_id) from public.inquiry_interests t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t),
    (select jsonb_agg(to_jsonb(t) order by vehicle_id) from public.vehicle_inquiry_rotation t),
    (select jsonb_build_array(last_value, is_called) from public.inquiries_creation_sequence_seq)
  )::text);
$f$;
create function pg_temp.vactor(n integer) returns text language sql as $f$
  select md5('v-actor-'||n)::uuid::text;
$f$;
create function pg_temp.vcreate(actor integer, phone text, name text, email text,
  vehicle integer, origin public.inquiry_origin) returns uuid
language plpgsql as $f$
declare response jsonb;
begin
  perform set_config('request.jwt.claim.sub', pg_temp.vactor(actor), true);
  perform set_config('role', 'authenticated', true);
  select public.create_manual_inquiry(phone, name, email,
    case when vehicle is null then null else md5('v-veh-'||vehicle)::uuid end, origin) into response;
  perform set_config('role', 'none', true);
  return (response ->> 'inquiry_id')::uuid;
end $f$;
create function pg_temp.vreject(actor integer, phone text, name text, email text,
  vehicle integer, origin public.inquiry_origin, label text) returns text
language plpgsql as $f$
declare before_all text := pg_temp.vstate(); observed text; unchanged boolean;
begin
  perform set_config('request.jwt.claim.sub', pg_temp.vactor(actor), true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.create_manual_inquiry(phone, name, email,
      case when vehicle is null then null else md5('v-veh-'||vehicle)::uuid end, origin);
    observed := '00000';
  exception when others then
    get stacked diagnostics observed = returned_sqlstate;
  end;
  perform set_config('role', 'none', true);
  unchanged := pg_temp.vstate() = before_all;
  return label || ' => ' || observed || ' unchanged=' || unchanged::text;
end $f$;

-- S18/S17: seller registers a telephone inquiry with an Available vehicle
create temp table c1 as
select pg_temp.vcreate(2, '+5491100050001', 'Typed Name', null, 1, 'phone') as id;
select is((select i.assignee_id from public.inquiries i, c1 where i.id = c1.id),
  md5('v-actor-2')::uuid, 'S18 manual inquiry is self-assigned');
select is((select i.origin from public.inquiries i, c1 where i.id = c1.id),
  'phone'::public.inquiry_origin, 'S17 manual origin is stored');
select is((select count(*) from public.inquiry_interests ii, c1 where ii.inquiry_id = c1.id),
  1::bigint, 'S17 chosen vehicle becomes an interest');
select is((select last_assignee_id from public.vehicle_inquiry_rotation
  where vehicle_id = md5('v-veh-1')::uuid), md5('v-actor-2')::uuid,
  'S18 rotation cursor is not advanced by manual entry');
select is((select h.reason from public.inquiry_assignment_history h, c1 where h.inquiry_id = c1.id),
  'manual', 'S18 assignment history records the manual reason');

-- S19: recognized contact is reused without overwriting; submitted data stays on the inquiry
select is((select c.display_name || '|' || c.email || '|' || c.revision::text
  from public.contacts c where c.id = md5('v-c1')::uuid),
  'V Stored|v1@example.invalid|0', 'S19 recognized contact is not overwritten');
select is((select i.submitted_name || '|' || coalesce(i.submitted_email, '<null>')
  from public.inquiries i, c1 where i.id = c1.id),
  'Typed Name|<null>', 'S19 submitted name survives without email');

-- S19/S19a: owner creates without vehicle, without email; new contact stays email-less
create temp table c2 as
select pg_temp.vcreate(1, '+5491100050003', 'Phone Customer', 'free text', null, 'phone') as id;
select is((select count(*) from public.inquiry_interests ii, c2 where ii.inquiry_id = c2.id),
  0::bigint, 'S19a inquiry without vehicle records no interest');
select is((select i.originating_vehicle_id is null and i.assignee_id = md5('v-actor-1')::uuid
  from public.inquiries i, c2 where i.id = c2.id), true, 'S19a null vehicle keeps self assignment');
grant select on c1, c2 to authenticated;
select is((select email from public.contacts where id = md5('v-c2')::uuid),
  null::text, 'S19 existing contact email is never backfilled');

-- S19: optional email accepts free text (no invented format) and rejects blanks
select ok(pg_temp.vcreate(2, '+5491100050004', 'Free Text', 'not-an-email', null, 'in_person') is not null,
  'S19 email format is not invented');
select is(pg_temp.vreject(2, '+5491100050004', 'Blank', '', null, 'phone', 'empty email'),
  'empty email => 22023 unchanged=true', 'S19 empty email is rejected atomically');
select is(pg_temp.vreject(2, '+5491100050004', 'Blank', '   ', null, 'phone', 'whitespace email'),
  'whitespace email => 22023 unchanged=true', 'S19 whitespace email is rejected atomically');

-- S17/S19: origin, name and phone boundaries
select is(pg_temp.vreject(2, '+5491100050004', 'Forge', null, null, 'web', 'web origin'),
  'web origin => 22023 unchanged=true', 'S17 web origin cannot be forged manually');
select is(pg_temp.vreject(2, '+5491100050004', '   ', null, null, 'phone', 'blank name'),
  'blank name => 22023 unchanged=true', 'S19 blank name is rejected atomically');
select is(pg_temp.vreject(2, '11000050004', 'Phone', null, null, 'phone', 'unnormalized'),
  'unnormalized => 22023 unchanged=true', 'S19 unnormalized phone is rejected');
select is(pg_temp.vreject(2, '+1234567890123456', 'Phone', null, null, 'phone', 'too long'),
  'too long => 22023 unchanged=true', 'S19 phone past the shape limit is rejected');
select ok(pg_temp.vcreate(2, '+123456789012345', 'Max Phone', null, null, 'phone') is not null,
  'S19 fifteen-digit phone is accepted');

-- S17: active staff only; rejected calls change nothing
select is(pg_temp.vreject(3, '+5491100050005', 'Inactive', null, null, 'phone', 'inactive'),
  'inactive => 42501 unchanged=true', 'S17 inactive staff is denied atomically');
select is(pg_temp.vreject(4, '+5491100050005', 'No Profile', null, null, 'phone', 'no profile'),
  'no profile => 42501 unchanged=true', 'S17 identity without profile is denied atomically');
select is(pg_temp.vreject(2, '+5491100050005', 'Sold', null, 3, 'phone', 'sold vehicle'),
  'sold vehicle => 22023 unchanged=true', 'S17 sold vehicle is rejected atomically');
-- A non-staff identity must not learn inventory state from the rejection message.
select is(pg_temp.vreject(4, '+5491100050005', 'No Profile', null, 3, 'phone', 'no profile sold'),
  'no profile sold => 42501 unchanged=true', 'S17 inventory state stays hidden from non-staff');

-- S19 interactions: web contract and continuity
set local role service_role;
select throws_ok($$select public.submit_inquiry(gen_random_uuid(), md5('v-veh-1')::uuid,
  '+5491100050006', 'Web Customer', '')$$, '22023', 'invalid inquiry input',
  'S19 web submission still requires email');
select lives_ok($$select public.submit_inquiry(md5('v-web-1')::uuid, md5('v-veh-1')::uuid,
  '+5491100050001', 'Web Customer', 'web@example.invalid')$$,
  'S17 web submission still succeeds after manual entry');
reset role;
select is((select origin from public.inquiries where submission_id = md5('v-web-1')::uuid),
  'web'::public.inquiry_origin, 'S17 web origin is preserved');
select is((select assignee_id from public.inquiries where submission_id = md5('v-web-1')::uuid),
  md5('v-actor-2')::uuid, 'S18 continuity follows the manual inquiry without advancing rotation');
select is((select count(*) from public.vehicle_inquiry_rotation
  where vehicle_id = md5('v-veh-1')::uuid and last_assignee_id = md5('v-actor-2')::uuid),
  1::bigint, 'S18 rotation cursor still points at the prior assignee');

-- S19a: existing interest operation accepts the manual inquiry
select set_config('request.jwt.claim.sub', pg_temp.vactor(2), true);
set local role authenticated;
select lives_ok(format('select public.add_inquiry_interest(%L::uuid, %L::uuid)',
  (select id from c1), md5('v-veh-2')::uuid), 'S19a manual inquiry accepts another interest');
select ok(not exists (select 1 from public.inquiries where id = (select id from c2)),
  'S19 unrelated seller cannot read another assignee manual inquiry');
reset role;

-- S17/S19: no broad mutations, no unauthenticated execution
select ok(not has_function_privilege('anon',
  'public.create_manual_inquiry(text,text,text,uuid,public.inquiry_origin)', 'EXECUTE'),
  'S17 anon cannot execute manual creation');
select ok(not has_table_privilege('authenticated', 'public.inquiries', 'INSERT'),
  'S17 authenticated has no direct inquiry insert');
select ok(not has_table_privilege('authenticated', 'public.contacts', 'UPDATE'),
  'S17 authenticated has no direct contact update');
select * from finish();
rollback;
