-- Run only in an isolated migrated test database. Everything rolls back.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Hash both account stores, including timestamps and password fields, without
-- exposing their contents to the test output. Synthetic fixtures only.
create function pg_temp.bootstrap_state() returns text
language sql security definer set search_path = '' as $$
  select md5(
    coalesce((select jsonb_agg(to_jsonb(p) order by id)::text from public.profiles p),'[]') ||
    coalesce((select jsonb_agg(to_jsonb(u) order by id)::text from auth.users u),'[]') ||
    coalesce((select jsonb_agg(to_jsonb(i) order by id)::text from auth.identities i),'[]')
  );
$$;
create function pg_temp.bootstrap_rejected(command text, code text, message text)
returns setof text language plpgsql as $$
declare before_state text := pg_temp.bootstrap_state();
begin
  return next extensions.throws_ok(command, code, null, message);
  return next extensions.is(pg_temp.bootstrap_state(), before_state, message || ': unchanged account stores');
end;
$$;

insert into auth.users(id, email, encrypted_password, email_confirmed_at,
 banned_until, email_change, is_anonymous, is_sso_user)
select md5('owner-bootstrap-' || n)::uuid,
 'owner-bootstrap-' || n || '@example.invalid',
 case when n=8 then '' else 'synthetic-not-a-real-password-hash' end,
 case when n=3 then null else now() end,
 case when n=4 then now()+interval '1 day' else null end,
 case when n=5 then 'different@example.invalid' else '' end,
 n=6, n=7 from generate_series(1,12)n;
insert into auth.identities(id, user_id, provider_id, provider, identity_data)
select md5('owner-bootstrap-identity-' || n)::uuid,
 md5('owner-bootstrap-' || n)::uuid,
 md5('owner-bootstrap-' || n)::uuid::text,
 'email', jsonb_build_object('sub',md5('owner-bootstrap-' || n)::uuid::text,
 'email','owner-bootstrap-' || n || '@example.invalid')
from generate_series(1,12)n where n<>9;
insert into auth.identities(id,user_id,provider_id,provider,identity_data)
values (md5('owner-bootstrap-linked')::uuid,md5('owner-bootstrap-10')::uuid,
 'synthetic-linked','google','{"email":"owner-bootstrap-10@example.invalid"}');
insert into public.profiles(id,role,display_name)
values (md5('owner-bootstrap-2')::uuid,'admin','Existing administrator');

select ok(not has_function_privilege('anon',
 'public.bootstrap_initial_owner(text,uuid,text,boolean)','EXECUTE'),'anon has no bootstrap grant');
select ok(not has_function_privilege('authenticated',
 'public.bootstrap_initial_owner(text,uuid,text,boolean)','EXECUTE'),'authenticated has no bootstrap grant');
select ok(has_function_privilege('service_role',
 'public.bootstrap_initial_owner(text,uuid,text,boolean)','EXECUTE'),'service has the narrow grant');
select ok(not has_table_privilege('service_role','public.profiles','SELECT'),'no service profile read grant');
select ok(not has_table_privilege('service_role','public.profiles','INSERT'),'no generic profile insert grant');

set local role anon;
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid')$$,
 '42501','anonymous bootstrap is denied');
set local role authenticated;
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid')$$,
 '42501','authenticated bootstrap is denied');
set local role service_role;
select * from pg_temp.bootstrap_rejected($$select * from public.profiles$$,
 '42501','service cannot read profiles directly');
select * from pg_temp.bootstrap_rejected(
 $$insert into public.profiles(id,role,display_name) values(md5('owner-bootstrap-1')::uuid,'owner','Bypass')$$,
 '42501','service cannot bypass finalization with direct insert');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner(' INVALID ')$$,'22023','noncanonical input denied');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',null,'Name',true)$$,
 '22023','finalization requires explicit identity');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-1')::uuid,' ',true)$$,
 '22023','finalization requires a nonblank name');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('missing@example.invalid',md5('missing')::uuid,'Name',true)$$,
 '23514','missing identity cannot be finalized');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-2')::uuid)$$,
 '23514','email and explicit ID identifying different accounts are denied');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('other@example.invalid',md5('owner-bootstrap-1')::uuid)$$,
 '23514','wrong email for existing ID is denied');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-2@example.invalid',md5('owner-bootstrap-2')::uuid,'Name',true)$$,
 '23514','existing administrator profile is never elevated');
select result.*
from generate_series(3,10) as fixtures(n)
cross join lateral pg_temp.bootstrap_rejected(
 format('select public.bootstrap_initial_owner(%L,%L::uuid,%L,true)',
 'owner-bootstrap-'||n||'@example.invalid',md5('owner-bootstrap-'||n)::uuid,'Name'),
 '23514','reject unverified/conflicting Auth fixture '||n) as result;

reset role;
savepoint changed_identity;
update auth.identities set identity_data='{"email":"other@example.invalid"}'
where user_id=md5('owner-bootstrap-1')::uuid;
set local role service_role;
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-1')::uuid,'Name',true)$$,
 '23514','mismatched identity email is denied');
reset role;
rollback to savepoint changed_identity;

savepoint inactive_owner;
insert into public.profiles(id,role,display_name,is_active)
values(md5('owner-bootstrap-12')::uuid,'owner','Inactive owner',false);
set local role service_role;
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-1')::uuid,'Name',true)$$,
 '23514','inactive Owner requires exceptional resolution, not initial provisioning');
reset role;
rollback to savepoint inactive_owner;

create temporary table bootstrap_before as select pg_temp.bootstrap_state() as state,
 md5((select jsonb_agg(to_jsonb(u) order by id)::text from auth.users u) ||
     (select jsonb_agg(to_jsonb(i) order by id)::text from auth.identities i)) as auth_state;
grant select on bootstrap_before to service_role;
set local role service_role;
select is(public.bootstrap_initial_owner('missing@example.invalid'),'missing','preflight permits new identity');
select is(public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid'),'auth_only','preflight detects Auth-only state without returning identity data');
select is(public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-1')::uuid),
 'auth_only','explicit recovery preflight accepts exact identity');
select is(pg_temp.bootstrap_state(),(select state from bootstrap_before),'preflights do not mutate account stores');
select is(public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-1')::uuid,' Initial Owner ',true),
 'created','service finalizes verified Auth-only identity');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-1@example.invalid',md5('owner-bootstrap-1')::uuid,'Initial Owner',true)$$,
 '23514','ordinary rerun with active Owner is denied');
select * from pg_temp.bootstrap_rejected(
 $$select public.bootstrap_initial_owner('owner-bootstrap-11@example.invalid',md5('owner-bootstrap-11')::uuid,'Another Owner',true)$$,
 '23514','different identity cannot create second bootstrap Owner');
reset role;
select is(md5((select jsonb_agg(to_jsonb(u) order by id)::text from auth.users u) ||
              (select jsonb_agg(to_jsonb(i) order by id)::text from auth.identities i)),
 (select auth_state from bootstrap_before),'successful recovery preserves every Auth user and identity field');
select is((select count(*)::int from public.profiles where role='owner' and is_active),1,'exactly one active Owner');
select is((select display_name from public.profiles where id=md5('owner-bootstrap-1')::uuid),'Initial Owner','profile links exact intended identity and normalized name');
select is((select role::text from public.profiles where id=md5('owner-bootstrap-2')::uuid),'admin','existing staff role preserved');
select is((select encrypted_password from auth.users where id=md5('owner-bootstrap-1')::uuid),
 'synthetic-not-a-real-password-hash','recovery never changes existing password');
select * from pg_temp.bootstrap_rejected(
 $$update public.profiles set is_active=false where id=md5('owner-bootstrap-1')::uuid$$,
 '23514','existing last-active-Owner deactivation guard preserved');
select * from pg_temp.bootstrap_rejected(
 $$update public.profiles set role='admin' where id=md5('owner-bootstrap-1')::uuid$$,
 '23514','existing last-active-Owner demotion guard preserved');
select * from finish();
rollback;
