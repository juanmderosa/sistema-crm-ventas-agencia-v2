-- Disposable migrated database only. No mail or genuine Auth claim is made.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create function pg_temp.invitation_state(include_intents boolean default true) returns text
language plpgsql security definer set search_path = '' as $$
declare
  relation record;
  contents text;
  state text := '';
begin
  for relation in select schemaname, tablename from pg_catalog.pg_tables
    where schemaname in ('public', 'auth')
      and (include_intents or tablename not in ('staff_invitation_intents','staff_invitation_requests'))
    order by schemaname, tablename
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text, %L) from %I.%I t',
      '[]', relation.schemaname, relation.tablename) into contents;
    state := state || relation.schemaname || relation.tablename || contents;
  end loop;
  return md5(state);
end;
$$;
create function pg_temp.invitation_command(request integer, invitation integer,
 actor integer, action text, email text default 'invited@example.invalid', target text default 'seller')
returns text language sql as $$
  select format('select public.manage_staff_invitation_intent(%L::uuid,%L::uuid,%L::uuid,%L,%L,%L::public.user_role)',
    md5('invite-request-'||request), md5('invite-'||invitation), md5('invite-actor-'||actor), action, email, target);
$$;
create function pg_temp.invitation_ok(command text, expected integer, description text)
returns setof text language plpgsql as $$
declare result uuid;
begin
  execute command into result;
  return next extensions.is(result, md5('invite-'||expected)::uuid, description);
end;
$$;
create function pg_temp.invitation_retry(command text, expected integer, description text)
returns setof text language plpgsql as $$
declare before_state text := pg_temp.invitation_state();
begin
  return query select * from pg_temp.invitation_ok(command, expected, description);
  return next extensions.is(pg_temp.invitation_state(), before_state, description||': no additional writes');
end;
$$;
create function pg_temp.invitation_denied(command text, code text, message text)
returns setof text language plpgsql as $$
declare before_state text := pg_temp.invitation_state();
begin
  return next extensions.throws_ok(command, code, message, message);
  return next extensions.is(pg_temp.invitation_state(), before_state, 'Rejection preserves all public/Auth rows');
end;
$$;

insert into auth.users(id,email)
select md5('invite-actor-'||n)::uuid,'invite-actor-'||n||'@example.invalid'
from generate_series(1,6)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('invite-actor-'||n)::uuid,
 (case n when 1 then 'owner' when 2 then 'admin' when 3 then 'seller'
 when 4 then 'owner' else 'admin' end)::public.user_role,
 'Invitation actor '||n,n<4 from generate_series(1,5)n;

select ok(not has_function_privilege(r,
 'public.manage_staff_invitation_intent(uuid,uuid,uuid,text,text,public.user_role)','EXECUTE'),r||' has no RPC grant')
from unnest(array['anon','authenticated'])r;
select ok(has_function_privilege('service_role',
 'public.manage_staff_invitation_intent(uuid,uuid,uuid,text,text,public.user_role)','EXECUTE'),'service has narrow RPC grant');
select ok(not has_table_privilege(r,t,privilege),r||' has no '||privilege||' on '||t)
from unnest(array['anon','authenticated','service_role'])r
cross join unnest(array['public.staff_invitation_intents','public.staff_invitation_requests'])t
cross join unnest(array['SELECT','INSERT','UPDATE','DELETE'])privilege;
select ok(not has_table_privilege('service_role','public.profiles','INSERT'),'no broad profile insertion grant');
create temporary table invitation_protected_before as select pg_temp.invitation_state(false) as state;
grant select on invitation_protected_before to service_role;
set local role anon;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'create'),
 '42501','permission denied for function manage_staff_invitation_intent');
set local role authenticated;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'create'),
 '42501','permission denied for function manage_staff_invitation_intent');
set local role service_role;
select * from pg_temp.invitation_denied('select * from public.staff_invitation_intents',
 '42501','permission denied for table staff_invitation_intents');
select result.*
from generate_series(3,6) as actors(n)
cross join lateral pg_temp.invitation_denied(pg_temp.invitation_command(1,1,n,'create'),
 '42501','No tiene permiso para gestionar esta invitación.') as result;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,2,'create','invited@example.invalid','admin'),
 '42501','No tiene permiso para gestionar esta invitación.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'create','invited@example.invalid','owner'),
 '42501','No tiene permiso para gestionar esta invitación.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'create',' INVITED@example.invalid'),
 '22023','Datos de invitación inválidos.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'accept'),
 '22023','Datos de invitación inválidos.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'resend'),
 '23514','La invitación no existe.');
select * from pg_temp.invitation_ok(pg_temp.invitation_command(1,1,1,'create'),1,'Owner creates Seller intent');
select * from pg_temp.invitation_retry(pg_temp.invitation_command(1,1,1,'create'),1,'Exact create retry');
select * from pg_temp.invitation_ok(pg_temp.invitation_command(2,1,2,'resend'),1,'Admin resends same Seller intent');
select * from pg_temp.invitation_retry(pg_temp.invitation_command(2,1,2,'resend'),1,'Exact resend retry');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,2,'create'),
 '23514','El identificador de solicitud ya tiene otros datos.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(2,1,2,'revoke'),
 '23514','El identificador de solicitud ya tiene otros datos.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(3,2,2,'create'),
 '23514','Ya existe una invitación pendiente. Use el reenvío explícito.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(3,1,1,'resend','invited@example.invalid','admin'),
 '23514','La invitación no coincide con los datos indicados.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(3,1,1,'resend','different@example.invalid'),
 '23514','La invitación no coincide con los datos indicados.');
select * from pg_temp.invitation_ok(pg_temp.invitation_command(4,3,1,'create','admin-invite@example.invalid','admin'),3,'Owner creates Admin intent');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(5,3,2,'revoke','admin-invite@example.invalid','admin'),
 '42501','No tiene permiso para gestionar esta invitación.');

-- Existing active accounts and unbound Auth-only partial states both fail closed.
select result.*
from generate_series(1,6) as actors(n)
cross join lateral pg_temp.invitation_denied(pg_temp.invitation_command(6,4,1,'create','invite-actor-'||n||'@example.invalid'),
 '23514','La identidad existente requiere verificación antes de continuar.') as result;
reset role;
savepoint linked_identity;
insert into auth.identities(id,user_id,provider_id,provider,identity_data)
values(md5('invitation-linked-identity')::uuid,md5('invite-actor-6')::uuid,
 'synthetic-invitation-linked','google','{"email":"linked-invite@example.invalid"}');
set local role service_role;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(6,4,1,'create','linked-invite@example.invalid'),
 '23514','La identidad existente requiere verificación antes de continuar.');
reset role;
rollback to savepoint linked_identity;
savepoint auth_partial;
insert into auth.users(id,email) values(md5('invitation-partial')::uuid,'invited@example.invalid');
insert into auth.identities(id,user_id,provider_id,provider,identity_data)
values(md5('invitation-partial-identity')::uuid,md5('invitation-partial')::uuid,
 md5('invitation-partial')::uuid::text,'email','{"email":"invited@example.invalid"}');
set local role service_role;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(2,1,2,'resend'),
 '23514','La identidad existente requiere verificación antes de continuar.');
select * from pg_temp.invitation_ok(pg_temp.invitation_command(7,1,2,'revoke'),1,'Revocation remains possible after Auth creation');
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('invitation-partial')::uuid::text,true);
select is(public.is_active_staff(),false,'Auth-only pending identity has no operational access');
select is(public.current_staff_role(),null::public.user_role,'Pending identity has no routing staff role');
reset role;
rollback to savepoint auth_partial;

-- Recheck authorization on retries, not just first creation.
savepoint actor_changed;
update public.profiles set is_active=false where id=md5('invite-actor-2')::uuid;
set local role service_role;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(2,1,2,'resend'),
 '42501','No tiene permiso para gestionar esta invitación.');
reset role;
rollback to savepoint actor_changed;
savepoint actor_demoted;
update public.profiles set role='seller' where id=md5('invite-actor-2')::uuid;
set local role service_role;
select * from pg_temp.invitation_denied(pg_temp.invitation_command(2,1,2,'resend'),
 '42501','No tiene permiso para gestionar esta invitación.');
reset role;
rollback to savepoint actor_demoted;
set local role service_role;
select * from pg_temp.invitation_ok(pg_temp.invitation_command(8,1,2,'revoke'),1,'Explicit revocation');
select * from pg_temp.invitation_retry(pg_temp.invitation_command(8,1,2,'revoke'),1,'Exact revoke retry');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(1,1,1,'create'),
 '23514','La invitación fue revocada. Cree una nueva invitación.');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(9,1,1,'resend'),
 '23514','La invitación fue revocada. Cree una nueva invitación.');
select * from pg_temp.invitation_ok(pg_temp.invitation_command(10,2,2,'create'),2,'New explicit action uses a new invitation ID');
select * from pg_temp.invitation_denied(pg_temp.invitation_command(9,1,1,'resend'),
 '23514','La invitación fue revocada. Cree una nueva invitación.');

select is(pg_temp.invitation_state(false),(select state from invitation_protected_before),
 'Successful lifecycle changes no Auth, profiles, routing, commercial or other public data');

-- Existing profile update API, role helper and Owner guard remain unchanged.
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('invite-actor-2')::uuid::text,true);
with changed as (update public.profiles set display_name='Renamed seller'
 where id=md5('invite-actor-3')::uuid returning 1)
select is((select count(*)::integer from changed),1,'Admin retains Seller management');
select * from pg_temp.invitation_denied(
 $$update public.profiles set role='admin' where id=md5('invite-actor-3')::uuid$$,
 '42501','new row violates row-level security policy for table "profiles"');
reset role;
update public.profiles set is_active=false where role='owner' and id<>md5('invite-actor-1')::uuid;
select * from pg_temp.invitation_denied(
 $$update public.profiles set is_active=false where id=md5('invite-actor-1')::uuid$$,
 '23514','the last active owner cannot be demoted or deactivated');
select * from finish();
rollback;
