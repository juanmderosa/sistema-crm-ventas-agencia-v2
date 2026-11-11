-- Phase 1: planned binding contract, intentionally missing RPCs until parent observes RED.
-- Auth writes below are synthetic fixture setup only; everything rolls back.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create function pg_temp.binding_state(include_bindings boolean default true) returns text
language plpgsql security definer set search_path = '' as $$
declare
  relation record;
  contents text;
  state text := '';
begin
  for relation in select schemaname, tablename from pg_catalog.pg_tables
    where schemaname in ('public', 'auth')
      and (include_bindings or tablename <> 'staff_invitation_identity_bindings')
    order by schemaname, tablename
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text, %L) from %I.%I t',
      '[]', relation.schemaname, relation.tablename) into contents;
    state := state || relation.schemaname || relation.tablename || contents;
  end loop;
  return md5(state);
end;
$$;
create function pg_temp.binding_id(kind text, n integer) returns uuid language sql as $$
  select md5('binding-'||kind||'-'||n)::uuid;
$$;
create function pg_temp.binding_command(action text, invitation integer default 1,
 actor integer default 1, provenance integer default 1, target integer default 1)
returns text language sql as $$
  select case action when 'prepare' then format(
    'select public.prepare_staff_invitation_identity(%L::uuid,%L::uuid,%L::uuid)',
    pg_temp.binding_id('invite',invitation),pg_temp.binding_id('actor',actor),pg_temp.binding_id('nonce',provenance))
  else format('select public.bind_staff_invitation_identity(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
    pg_temp.binding_id('invite',invitation),pg_temp.binding_id('actor',actor),
    pg_temp.binding_id('user',target),pg_temp.binding_id('nonce',provenance)) end;
$$;
create function pg_temp.binding_denied(command text, code text, message text, description text)
returns setof text language plpgsql as $$
declare before_state text := pg_temp.binding_state();
begin
  return next extensions.throws_ok(command,code,message,description);
  return next extensions.is(pg_temp.binding_state(),before_state,description||': all public/Auth rows unchanged');
end;
$$;
create function pg_temp.binding_prepared(invitation integer, actor integer, provenance integer,
 bound_user integer, candidate integer, description text) returns setof text language plpgsql as $$
declare actual jsonb;
begin
  execute pg_temp.binding_command('prepare',invitation,actor,provenance) into actual;
  return next extensions.is(actual,jsonb_build_object(
    'invitation_id',pg_temp.binding_id('invite',invitation),
    'email','binding-'||invitation||'@example.invalid',
    'role',case when invitation=2 then 'admin' else 'seller' end,
    'provenance',pg_temp.binding_id('nonce',provenance),
    'user_id',pg_temp.binding_id('user',bound_user),
    'candidate_user_id',pg_temp.binding_id('user',candidate)),description||': exact private JSON');
end;
$$;
create function pg_temp.binding_bound(description text) returns setof text language plpgsql as $$
declare actual uuid;
begin
  execute pg_temp.binding_command('bind') into actual;
  return next extensions.is(actual,pg_temp.binding_id('user',1),description);
end;
$$;

insert into auth.users(id,email)
select pg_temp.binding_id('actor',n),'binding-actor-'||n||'@example.invalid'
from generate_series(1,6)n;
insert into public.profiles(id,role,display_name,is_active)
select pg_temp.binding_id('actor',n),
 (case n when 1 then 'owner' when 2 then 'admin' when 3 then 'seller'
 when 4 then 'owner' else 'admin' end)::public.user_role,
 'Binding actor '||n,n<4 from generate_series(1,5)n;

-- Only the existing public intent API creates intents and their request history.
set local role service_role;
select is(public.manage_staff_invitation_intent(pg_temp.binding_id('request',n),
 pg_temp.binding_id('invite',n),pg_temp.binding_id('actor',1),'create',
 'binding-'||n||'@example.invalid',
 (case when n=2 then 'admin' else 'seller' end)::public.user_role),
 pg_temp.binding_id('invite',n),'Create prerequisite intent '||n)
from generate_series(1,4)n;

-- First call is deliberately a real public RPC invocation: expected missing-function RED.
select * from pg_temp.binding_prepared(1,1,1,null,null,'Owner reserves Seller provenance');
reset role;
select ok(has_function_privilege('service_role',signature,'EXECUTE'),'Service RPC grant: '||signature)
from unnest(array['public.prepare_staff_invitation_identity(uuid,uuid,uuid)',
 'public.bind_staff_invitation_identity(uuid,uuid,uuid,uuid)'])signature;
select ok(not has_function_privilege(r,signature,'EXECUTE'),r||' cannot execute '||signature)
from unnest(array['anon','authenticated'])r cross join unnest(array[
 'public.prepare_staff_invitation_identity(uuid,uuid,uuid)',
 'public.bind_staff_invitation_identity(uuid,uuid,uuid,uuid)'])signature;
select ok(not has_table_privilege(r,'public.staff_invitation_identity_bindings',privilege),
 r||' has no binding table '||privilege)
from unnest(array['anon','authenticated','service_role'])r
cross join unnest(array['SELECT','INSERT','UPDATE','DELETE'])privilege;
select ok(not has_table_privilege('service_role','public.profiles','INSERT'),'No broad profile insertion grant');
set local role anon;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare'),'42501',
 'permission denied for function prepare_staff_invitation_identity','Anon prepare denied');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind'),'42501',
 'permission denied for function bind_staff_invitation_identity','Anon bind denied');
set local role authenticated;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare'),'42501',
 'permission denied for function prepare_staff_invitation_identity','Authenticated prepare denied');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind'),'42501',
 'permission denied for function bind_staff_invitation_identity','Authenticated bind denied');
set local role service_role;
select * from pg_temp.binding_denied('select * from public.staff_invitation_identity_bindings','42501',
 'permission denied for table staff_invitation_identity_bindings','Service cannot read binding table directly');

-- Every rejection hashes all public and Auth rows, including counters/history tables.
select result.* from generate_series(3,6)actors(n)
cross join lateral pg_temp.binding_denied(pg_temp.binding_command('prepare',1,n),'42501',
 'No tiene permiso para gestionar esta invitación.','Seller/inactive/absent actor prepare '||n)result;
select result.* from generate_series(3,6)actors(n)
cross join lateral pg_temp.binding_denied(pg_temp.binding_command('bind',1,n),'42501',
 'No tiene permiso para gestionar esta invitación.','Seller/inactive/absent actor bind '||n)result;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',2,2,2),'42501',
 'No tiene permiso para gestionar esta invitación.','Admin cannot prepare Admin identity');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',2,2,2,2),'42501',
 'No tiene permiso para gestionar esta invitación.','Admin cannot bind Admin identity');
select * from pg_temp.binding_denied(
 $$select public.manage_staff_invitation_intent(pg_temp.binding_id('request',5),
 pg_temp.binding_id('invite',5),pg_temp.binding_id('actor',1),'create','binding-5@example.invalid','owner')$$,
 '42501','No tiene permiso para gestionar esta invitación.','No Owner invitation namespace');
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',99),'23514',
 'La invitación no existe.','Missing invitation prepare');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',99),'23514',
 'La invitación no existe.','Missing invitation bind');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',3,1,3,3),'23514',
 'Prepare la identidad de la invitación antes de vincularla.','Bind before prepare');
select result.* from unnest(array[
 'select public.prepare_staff_invitation_identity(null,pg_temp.binding_id(''actor'',1),pg_temp.binding_id(''nonce'',1))',
 'select public.prepare_staff_invitation_identity(pg_temp.binding_id(''invite'',1),null,pg_temp.binding_id(''nonce'',1))',
 'select public.prepare_staff_invitation_identity(pg_temp.binding_id(''invite'',1),pg_temp.binding_id(''actor'',1),null)',
 'select public.bind_staff_invitation_identity(null,pg_temp.binding_id(''actor'',1),pg_temp.binding_id(''user'',1),pg_temp.binding_id(''nonce'',1))',
 'select public.bind_staff_invitation_identity(pg_temp.binding_id(''invite'',1),null,pg_temp.binding_id(''user'',1),pg_temp.binding_id(''nonce'',1))',
 'select public.bind_staff_invitation_identity(pg_temp.binding_id(''invite'',1),pg_temp.binding_id(''actor'',1),null,pg_temp.binding_id(''nonce'',1))',
 'select public.bind_staff_invitation_identity(pg_temp.binding_id(''invite'',1),pg_temp.binding_id(''actor'',1),pg_temp.binding_id(''user'',1),null)'
])commands(command) cross join lateral pg_temp.binding_denied(command,'22023',
 'Datos de vinculación inválidos.','Null required argument: '||command)result;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',1,1,9),'23514',
 'La procedencia no coincide con la invitación.','Reserved marker cannot be replaced');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',1,1,9),'23514',
 'La procedencia no coincide con la invitación.','Bind wrong nonce');
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',3,1,1),'23514',
 'La procedencia no coincide con la invitación.','Marker cannot be reused across intents');
reset role;
create temporary table binding_retry_before as select pg_temp.binding_state() as state;
grant select on binding_retry_before to service_role;
set local role service_role;
select * from pg_temp.binding_prepared(1,2,1,null,null,'Admin can prepare Seller exact reservation');
select is(pg_temp.binding_state(),(select state from binding_retry_before),'Reservation retry has no writes');
select * from pg_temp.binding_prepared(2,1,2,null,null,'Owner prepares Admin');
select * from pg_temp.binding_prepared(3,2,3,null,null,'Admin prepares Seller');
reset role;
select is((select count(*)::integer from public.staff_invitation_identity_bindings
 where user_id is null and bound_at is null),3,'Reservations have neither bound user nor bound timestamp');

-- An unrelated existing Auth user cannot be adopted, even before reserving a marker.
reset role;
savepoint unrelated;
insert into auth.users(id,email) values(pg_temp.binding_id('user',4),'binding-4@example.invalid');
set local role service_role;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',4,1,4),'23514',
 'La identidad de la invitación requiere verificación.','Unrelated existing Auth prevents reservation');
reset role;
update auth.users set raw_app_meta_data=jsonb_build_object(
 'staff_invitation_id',pg_temp.binding_id('invite',4),
 'staff_invitation_provenance',pg_temp.binding_id('nonce',4)) where id=pg_temp.binding_id('user',4);
set local role service_role;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',4,1,4),'23514',
 'La identidad de la invitación requiere verificación.','Unreserved app markers cannot justify adopting existing Auth');
reset role;
rollback to savepoint unrelated;
savepoint revoked_unprepared;
set local role service_role;
select is(public.manage_staff_invitation_intent(pg_temp.binding_id('request',6),pg_temp.binding_id('invite',4),
 pg_temp.binding_id('actor',1),'revoke','binding-4@example.invalid','seller'),pg_temp.binding_id('invite',4),
 'Explicitly revoke before preparation');
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',4,1,4),'23514',
 'La invitación fue revocada. Cree una nueva invitación.','Revoked unprepared intent cannot reserve provenance');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',4,1,4,4),'23514',
 'La invitación fue revocada. Cree una nueva invitación.','Revoked unprepared intent cannot bind');
reset role;
rollback to savepoint revoked_unprepared;

-- The supported Admin create call must write these app markers atomically.
-- Unconfirmed, passwordless Auth with one email-provider identity is valid for BINDING only.
insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data,is_anonymous,is_sso_user)
select pg_temp.binding_id('user',n),'binding-'||n||'@example.invalid',
 jsonb_build_object('provider','email','providers',jsonb_build_array('email'),
 'staff_invitation_id',pg_temp.binding_id('invite',n),
 'staff_invitation_provenance',pg_temp.binding_id('nonce',n)),
 '{}'::jsonb,false,false from generate_series(1,3)n;
insert into auth.identities(id,user_id,provider_id,provider,identity_data)
select pg_temp.binding_id('identity',n),pg_temp.binding_id('user',n),pg_temp.binding_id('user',n)::text,
 'email',jsonb_build_object('sub',pg_temp.binding_id('user',n),'email','binding-'||n||'@example.invalid')
from generate_series(1,3)n;
create temporary table binding_protected_before as select pg_temp.binding_state(false) as state;
grant select on binding_protected_before to service_role;
create temporary table binding_candidate_before as select pg_temp.binding_state() as state;
grant select on binding_candidate_before to service_role;
set local role service_role;
select * from pg_temp.binding_prepared(1,1,1,null,1,'Lost create response recovers verified candidate privately');
select is(pg_temp.binding_state(),(select state from binding_candidate_before),'Candidate recovery performs no writes');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',1,1,1,2),'23514',
 'La identidad de la invitación requiere verificación.','Wrong UUID cannot bind another valid candidate');
select * from pg_temp.binding_denied(
 $$select public.manage_staff_invitation_intent(pg_temp.binding_id('request',1),pg_temp.binding_id('invite',1),
 pg_temp.binding_id('actor',1),'create','binding-1@example.invalid','seller')$$,'23514',
 'La identidad existente requiere verificación antes de continuar.','Intent create retry stays conservative');
select * from pg_temp.binding_denied(
 $$select public.manage_staff_invitation_intent(pg_temp.binding_id('request',5),pg_temp.binding_id('invite',1),
 pg_temp.binding_id('actor',2),'resend','binding-1@example.invalid','seller')$$,'23514',
 'La identidad existente requiere verificación antes de continuar.','Intent resend stays conservative');
reset role;

-- Each fixture mutation probes BOTH candidate recovery and binding through public RPCs.
-- A fixture subtransaction restores the candidate; emit TAP only AFTER rollback
-- so pgTAP counters are never rolled back together with the fixture.
create function pg_temp.binding_bad_fixture(mutation text, description text)
returns setof text language plpgsql as $$
declare
  action text;
  code text;
  message text;
  before_state text;
  outcomes jsonb := '[]';
  outcome jsonb;
begin
  begin
    execute mutation;
    execute 'set local role service_role';
    foreach action in array array['prepare','bind'] loop
      code := null;
      message := null;
      before_state := pg_temp.binding_state();
      begin
        execute pg_temp.binding_command(action);
      exception when others then
        get stacked diagnostics code = returned_sqlstate, message = message_text;
      end;
      outcomes := outcomes || jsonb_build_array(jsonb_build_object(
        'action',action,'code',code,'message',message,
        'before',before_state,'after',pg_temp.binding_state()));
    end loop;
    raise exception using errcode='ZX001';
  exception when sqlstate 'ZX001' then null;
  end;
  for outcome in select value from jsonb_array_elements(outcomes) loop
    return next extensions.is(outcome->>'code','23514',description||': '||(outcome->>'action')||' SQLSTATE');
    return next extensions.is(outcome->>'message','La identidad de la invitación requiere verificación.',
      description||': exact message');
    return next extensions.is(outcome->>'after',outcome->>'before',description||': all public/Auth rows unchanged');
  end loop;
end;
$$;
select result.* from (values
 ('update auth.users set raw_app_meta_data=''{}'', raw_user_meta_data=jsonb_build_object(''staff_invitation_id'',pg_temp.binding_id(''invite'',1),''staff_invitation_provenance'',pg_temp.binding_id(''nonce'',1)) where id=pg_temp.binding_id(''user'',1)', 'Copied user metadata is not provenance'),
 ('update auth.users set raw_app_meta_data=raw_app_meta_data-''staff_invitation_id'' where id=pg_temp.binding_id(''user'',1)', 'Missing app invitation marker'),
 ('update auth.users set raw_app_meta_data=raw_app_meta_data-''staff_invitation_provenance'' where id=pg_temp.binding_id(''user'',1)', 'Missing app provenance marker'),
 ('update auth.users set raw_app_meta_data=jsonb_set(raw_app_meta_data,''{staff_invitation_id}'',to_jsonb(pg_temp.binding_id(''invite'',2))) where id=pg_temp.binding_id(''user'',1)', 'Wrong app invitation UUID'),
 ('update auth.users set raw_app_meta_data=jsonb_set(raw_app_meta_data,''{staff_invitation_provenance}'',to_jsonb(pg_temp.binding_id(''nonce'',2))) where id=pg_temp.binding_id(''user'',1)', 'Wrong app provenance UUID'),
 ('update auth.users set raw_app_meta_data=jsonb_set(raw_app_meta_data,''{staff_invitation_id}'',to_jsonb(upper(pg_temp.binding_id(''invite'',1)::text))) where id=pg_temp.binding_id(''user'',1)', 'Noncanonical marker UUID'),
 ('update auth.users set raw_app_meta_data=jsonb_set(raw_app_meta_data,''{staff_invitation_provenance}'',to_jsonb(upper(pg_temp.binding_id(''nonce'',1)::text))) where id=pg_temp.binding_id(''user'',1)', 'Noncanonical provenance UUID'),
 ('update auth.users set email=''other@example.invalid'' where id=pg_temp.binding_id(''user'',1)', 'Wrong Auth email'),
 ('update auth.users set email=''BINDING-1@example.invalid'' where id=pg_temp.binding_id(''user'',1)', 'Noncanonical Auth email'),
 ('update auth.users set deleted_at=now() where id=pg_temp.binding_id(''user'',1)', 'Deleted Auth row'),
 ('update auth.users set banned_until=now()+interval ''1 day'' where id=pg_temp.binding_id(''user'',1)', 'Currently banned Auth row'),
 ('update auth.users set is_anonymous=true where id=pg_temp.binding_id(''user'',1)', 'Anonymous Auth row'),
 ('update auth.users set is_sso_user=true where id=pg_temp.binding_id(''user'',1)', 'SSO Auth row'),
 ('update auth.users set email_change=''other@example.invalid'' where id=pg_temp.binding_id(''user'',1)', 'Pending email change'),
 ('delete from auth.identities where user_id=pg_temp.binding_id(''user'',1)', 'Missing email identity'),
 ('update auth.identities set identity_data=jsonb_set(identity_data,''{email}'',''"other@example.invalid"'') where user_id=pg_temp.binding_id(''user'',1)', 'Wrong identity email'),
 ('update auth.identities set identity_data=jsonb_set(identity_data,''{email}'',''"BINDING-1@example.invalid"'') where user_id=pg_temp.binding_id(''user'',1)', 'Noncanonical identity email'),
 ('update auth.identities set provider_id=''unrelated'' where user_id=pg_temp.binding_id(''user'',1)', 'Wrong email provider UUID'),
 ('update auth.identities set identity_data=jsonb_set(identity_data,''{sub}'',to_jsonb(pg_temp.binding_id(''user'',2))) where user_id=pg_temp.binding_id(''user'',1)', 'Wrong identity subject UUID'),
 ('insert into auth.identities(id,user_id,provider_id,provider,identity_data) values(pg_temp.binding_id(''extra'',1),pg_temp.binding_id(''user'',1),''linked-google'',''google'',''{"email":"binding-1@example.invalid"}'')', 'Linked provider identity'),
 ('insert into auth.identities(id,user_id,provider_id,provider,identity_data) values(pg_temp.binding_id(''extra'',1),pg_temp.binding_id(''user'',1),''second-email'',''email'',''{"email":"binding-1@example.invalid"}'')', 'Multiple email identities'),
 ('insert into auth.users(id,email,raw_app_meta_data) select pg_temp.binding_id(''extra'',1),''another@example.invalid'',raw_app_meta_data from auth.users where id=pg_temp.binding_id(''user'',1)', 'Same marker on another user'),
 ('insert into auth.users(id,email) values(pg_temp.binding_id(''extra'',1),''BINDING-1@example.invalid'')', 'Ambiguous case-insensitive Auth email matches'),
 ('insert into auth.identities(id,user_id,provider_id,provider,identity_data) values(pg_temp.binding_id(''extra'',1),pg_temp.binding_id(''user'',2),''conflicting-google'',''google'',''{"email":"binding-1@example.invalid"}'')', 'Email identity belongs to another user'),
 ('insert into public.profiles(id,role,display_name,is_active) values(pg_temp.binding_id(''user'',1),''seller'',''Already active'',true)', 'Existing active profile'),
 ('insert into public.profiles(id,role,display_name,is_active) values(pg_temp.binding_id(''user'',1),''seller'',''Already inactive'',false)', 'Existing inactive profile')
)cases(mutation,description)
cross join lateral pg_temp.binding_bad_fixture(mutation,description)result;

set local role service_role;
select * from pg_temp.binding_bound('Owner binds unconfirmed passwordless Seller without activation');
select * from pg_temp.binding_prepared(1,2,1,1,1,'Bound prepare returns same verified UUID');
reset role;
select * from pg_temp.binding_bad_fixture(
 $$update auth.users set raw_app_meta_data='{}' where id=pg_temp.binding_id('user',1)$$,
 'Bound retry rechecks current provenance');
create temporary table binding_bound_before as select pg_temp.binding_state() as state;
grant select on binding_bound_before to service_role;
set local role service_role;
select * from pg_temp.binding_bound('Same-user same-marker bind retry returns immutable UUID');
select is(pg_temp.binding_state(),(select state from binding_bound_before),'Exact bind retry has no writes');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',1,1,1,2),'23514',
 'La identidad vinculada no coincide con la solicitud.','Bound identity cannot be replaced');
select is(public.bind_staff_invitation_identity(pg_temp.binding_id('invite',2),pg_temp.binding_id('actor',1),
 pg_temp.binding_id('user',2),pg_temp.binding_id('nonce',2)),pg_temp.binding_id('user',2),'Owner binds Admin');
select is(public.bind_staff_invitation_identity(pg_temp.binding_id('invite',3),pg_temp.binding_id('actor',2),
 pg_temp.binding_id('user',3),pg_temp.binding_id('nonce',3)),pg_temp.binding_id('user',3),'Admin binds Seller');
select is(pg_temp.binding_state(false),(select state from binding_protected_before),
 'Successful preparation/recovery/binding preserves Auth, intents, requests, profiles and routing');
reset role;

-- Retry authorization is current, even after successful binding.
savepoint actor_inactive;
update public.profiles set is_active=false where id=pg_temp.binding_id('actor',2);
set local role service_role;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',1,2),'42501',
 'No tiene permiso para gestionar esta invitación.','Inactive Admin cannot recover bound identity');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',1,2),'42501',
 'No tiene permiso para gestionar esta invitación.','Inactive Admin cannot retry binding');
reset role;
rollback to savepoint actor_inactive;
savepoint actor_demoted;
update public.profiles set role='seller' where id=pg_temp.binding_id('actor',2);
set local role service_role;
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare',1,2),'42501',
 'No tiene permiso para gestionar esta invitación.','Demoted Admin cannot recover bound identity');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind',1,2),'42501',
 'No tiene permiso para gestionar esta invitación.','Demoted Admin cannot retry binding');
reset role;
rollback to savepoint actor_demoted;

-- Revocation uses the existing command; binding and intent history survive it.
set local role service_role;
select is(public.manage_staff_invitation_intent(pg_temp.binding_id('request',5),pg_temp.binding_id('invite',1),
 pg_temp.binding_id('actor',2),'revoke','binding-1@example.invalid','seller'),pg_temp.binding_id('invite',1),
 'Existing explicit revoke still works after binding');
select * from pg_temp.binding_denied(pg_temp.binding_command('prepare'),'23514',
 'La invitación fue revocada. Cree una nueva invitación.','Revoked prepare denied');
select * from pg_temp.binding_denied(pg_temp.binding_command('bind'),'23514',
 'La invitación fue revocada. Cree una nueva invitación.','Revoked bind retry denied');
reset role;
select is((select count(*)::integer from public.staff_invitation_intents),4,'All intent rows retained');
select is((select count(*)::integer from public.staff_invitation_requests),5,'Only explicit intent commands enter history');
select is((select count(*)::integer from public.staff_invitation_identity_bindings),3,'One binding per prepared intent retained');
select is((select count(*)::integer from public.staff_invitation_identity_bindings
 where user_id is not null and bound_at is not null),3,'Only verified bindings have user and timestamp');
select is((select count(*)::integer from public.profiles where id in
 (pg_temp.binding_id('user',1),pg_temp.binding_id('user',2),pg_temp.binding_id('user',3))),0,
 'Binding never inserts active OR inactive staff profiles');
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.binding_id('user',3)::text,true);
select is(public.is_active_staff(),false,'Bound pending identity has no operational access');
select is(public.current_staff_role(),null::public.user_role,'Bound pending identity has no staff role for routing');
reset role;
select * from finish();
rollback;
