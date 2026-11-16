-- Synthetic SQL-role fixtures only; no provider calls or persistent accounts.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create function pg_temp.rid(kind text, n integer default 1) returns uuid
language sql as $$ select md5('bound-resend-' || kind || '-' || n)::uuid $$;
create function pg_temp.state() returns text
language plpgsql security definer set search_path = '' as $$
declare r record; contents text; state text := '';
begin
  for r in select schemaname,tablename from pg_catalog.pg_tables
    where schemaname='public' or (schemaname='auth' and tablename in ('users','identities'))
    order by schemaname,tablename
  loop
    execute pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text,%L) from %I.%I t',
      '[]',r.schemaname,r.tablename) into contents;
    state := state || r.schemaname || r.tablename || contents;
  end loop;
  for r in select schemaname,sequencename from pg_catalog.pg_sequences
    where schemaname in ('public','auth') order by schemaname,sequencename
  loop
    execute pg_catalog.format('select jsonb_build_array(last_value,is_called)::text from %I.%I',
      r.schemaname,r.sequencename) into contents;
    state := state || r.schemaname || r.sequencename || contents;
  end loop;
  return pg_catalog.md5(state);
end;
$$;
create function pg_temp.cmd(request integer default 10, invitation integer default 1,
  actor integer default 1) returns text language sql as $$
  select format('select public.prepare_bound_staff_invitation_resend(%L,%L,%L)',
    pg_temp.rid('request',request),pg_temp.rid('invite',invitation),pg_temp.rid('actor',actor));
$$;
create function pg_temp.payload(n integer default 1) returns jsonb language sql as $$
  select jsonb_build_object('invitation_id',pg_temp.rid('invite',n),'email','bound-'||n||'@example.invalid',
    'role',case when n=2 then 'admin' else 'seller' end,'provenance',pg_temp.rid('nonce',n),
    'user_id',pg_temp.rid('user',n),'candidate_user_id',pg_temp.rid('user',n));
$$;
-- Execute as the real caller, roll fixture changes back before emitting TAP.
create function pg_temp.probe(command text, description text, expected jsonb default null,
  code text default null, message text default null, mutation text default null,
  caller text default 'service_role', journal_request integer default null,
  journal_invitation integer default 1, journal_actor integer default 1,
  journal_action text default 'bound_resend') returns setof text language plpgsql as $$
declare actual jsonb; actual_code text; actual_message text; before_state text; after_state text;
  expected_state text;
begin
  begin
    if mutation is not null then execute mutation; end if;
    before_state := pg_temp.state();
    if journal_request is not null then
      insert into public.staff_invitation_requests(id,invitation_id,actor_id,action)
      values(pg_temp.rid('request',journal_request),pg_temp.rid('invite',journal_invitation),
        pg_temp.rid('actor',journal_actor),journal_action);
      expected_state := pg_temp.state();
      delete from public.staff_invitation_requests where id=pg_temp.rid('request',journal_request);
    else expected_state := before_state;
    end if;
    execute format('set local role %I',caller);
    begin execute command into actual;
    exception when others then
      get stacked diagnostics actual_code=returned_sqlstate,actual_message=message_text;
    end;
    after_state := pg_temp.state();
    raise exception using errcode='ZX001';
  exception when sqlstate 'ZX001' then null;
  end;
  return next extensions.is(actual_code,code,description||': SQLSTATE');
  return next extensions.is(actual_message,message,description||': exact message');
  return next extensions.is(actual,expected,description||': exact response');
  return next extensions.is(after_state,expected_state,description||': exact protected rows/counters');
end;
$$;
insert into auth.users(id,email) select pg_temp.rid('actor',n),'bound-actor-'||n||'@example.invalid'
from generate_series(1,4)n;
insert into public.profiles(id,role,display_name,is_active)
select pg_temp.rid('actor',n),(case n when 1 then 'owner' when 2 then 'admin'
  when 3 then 'seller' else 'owner' end)::public.user_role,'Actor',true from generate_series(1,4)n;
set local role service_role;
select is(public.manage_staff_invitation_intent(pg_temp.rid('request',n),pg_temp.rid('invite',n),
  pg_temp.rid('actor'),'create','bound-'||n||'@example.invalid',
  (case when n=2 then 'admin' else 'seller' end)::public.user_role),pg_temp.rid('invite',n),
  'Legacy create prerequisite '||n) from generate_series(1,4)n;
select lives_ok(format('select public.prepare_staff_invitation_identity(%L,%L,%L)',
  pg_temp.rid('invite',n),pg_temp.rid('actor'),pg_temp.rid('nonce',n)),
  'Reserve prerequisite '||n) from generate_series(1,3)n;
reset role;
insert into auth.users(id,email,raw_app_meta_data)
select pg_temp.rid('user',n),'bound-'||n||'@example.invalid',jsonb_build_object(
  'staff_invitation_id',pg_temp.rid('invite',n),'staff_invitation_provenance',pg_temp.rid('nonce',n))
from generate_series(1,2)n;
insert into auth.identities(id,user_id,provider_id,provider,identity_data)
select pg_temp.rid('identity',n),pg_temp.rid('user',n),pg_temp.rid('user',n)::text,'email',
  jsonb_build_object('sub',pg_temp.rid('user',n),'email','bound-'||n||'@example.invalid')
from generate_series(1,2)n;
set local role service_role;
select is(public.bind_staff_invitation_identity(pg_temp.rid('invite',n),pg_temp.rid('actor'),
  pg_temp.rid('user',n),pg_temp.rid('nonce',n)),pg_temp.rid('user',n),'Bind prerequisite '||n)
from generate_series(1,2)n;
reset role;
-- Direct interface call is the meaningful missing-function RED boundary.
set local role service_role;
select is(public.prepare_bound_staff_invitation_resend(pg_temp.rid('request',10),
  pg_temp.rid('invite'),pg_temp.rid('actor')),pg_temp.payload(),'Unconfirmed passwordless same UUID');
reset role;
select is((select count(*)::integer from public.staff_invitation_requests where action='bound_resend'),1,
  'Exactly one new journal row');
select * from pg_temp.probe(pg_temp.cmd(),'Exact retry',pg_temp.payload());
select * from pg_temp.probe(pg_temp.cmd(11),'New unconfirmed request changes only journal',
  pg_temp.payload(),journal_request=>11);
select * from pg_temp.probe(pg_temp.cmd(11),'New confirmed request changes only journal',
  pg_temp.payload(),mutation=>$$update auth.users set email_confirmed_at=now()
    where id=pg_temp.rid('user')$$,journal_request=>11);
select * from pg_temp.probe(pg_temp.cmd(),'Confirmation does not change retry payload',pg_temp.payload(),
  mutation => $$update auth.users set email_confirmed_at=now() where id=pg_temp.rid('user')$$);
select * from pg_temp.probe(pg_temp.cmd(11,2),'Owner resends Admin',pg_temp.payload(2),journal_request=>11,journal_invitation=>2);
select * from pg_temp.probe(pg_temp.cmd(11,1,2),'Admin resends Seller',pg_temp.payload(),journal_request=>11,journal_actor=>2);
select * from pg_temp.probe(pg_temp.cmd(),'Anon denied',code=>'42501',
  message=>'permission denied for function prepare_bound_staff_invitation_resend',caller=>'anon');
select * from pg_temp.probe(pg_temp.cmd(),'Authenticated denied',code=>'42501',
  message=>'permission denied for function prepare_bound_staff_invitation_resend',caller=>'authenticated');
select results_eq($$select has_table_privilege(r,t,'SELECT') or has_table_privilege(r,t,'INSERT')
  or has_table_privilege(r,t,'UPDATE') or has_table_privilege(r,t,'DELETE')
  from unnest(array['anon','authenticated','service_role'])r cross join unnest(array[
  'public.staff_invitation_intents','public.staff_invitation_requests',
  'public.staff_invitation_identity_bindings','public.staff_invitation_completions'])t$$,
  $$select false from generate_series(1,12)$$,'No raw table grants');
select result.* from (values (pg_temp.cmd(11,2,2)),(pg_temp.cmd(11,1,3)),
  (pg_temp.cmd(11,99,3)),(pg_temp.cmd(11,1,99)))v(command)
cross join lateral pg_temp.probe(command,'Current actor denied',code=>'42501',
  message=>'No tiene permiso para gestionar esta invitación.')result;
select result.* from unnest(array['is_active=false','role=''seller'''])v(assignment)
cross join lateral pg_temp.probe(pg_temp.cmd(),'Retry reauthorizes actor',code=>'42501',
  message=>'No tiene permiso para gestionar esta invitación.',mutation=>
  'update public.profiles set '||assignment||' where id=pg_temp.rid(''actor'')')result;
select * from pg_temp.probe(pg_temp.cmd(11,2),'Demoted Owner cannot resend Admin',code=>'42501',
  message=>'No tiene permiso para gestionar esta invitación.',mutation=>
  $$update public.profiles set role='admin' where id=pg_temp.rid('actor')$$);
select result.* from unnest(array[pg_temp.cmd(null),pg_temp.cmd(11,null),pg_temp.cmd(11,1,null)])v(command)
cross join lateral pg_temp.probe(command,'Null argument',code=>'22023',message=>'Datos de invitación inválidos.')result;
select * from pg_temp.probe(pg_temp.cmd(11,99),'Missing invitation',code=>'23514',message=>'La invitación no existe.');
select result.* from unnest(array[3,4])n cross join lateral pg_temp.probe(pg_temp.cmd(11,n),
  'Reserved/unbound invitation',code=>'23514',message=>'La identidad de la invitación requiere verificación.')result;
select * from pg_temp.probe(pg_temp.cmd(),'Revoked retry',code=>'23514',
  message=>'La invitación fue revocada. Cree una nueva invitación.',mutation=>
  $$update public.staff_invitation_intents set revoked_at=now() where id=pg_temp.rid('invite')$$);
select * from pg_temp.probe(pg_temp.cmd(),'Permanent completion without profile',code=>'23514',
  message=>'La identidad de la invitación requiere verificación.',mutation=>
  $$insert into public.staff_invitation_completions(invitation_id,user_id,initial_display_name)
  values(pg_temp.rid('invite'),pg_temp.rid('user'),'Completed')$$);
select result.* from unnest(array[true,false])active cross join lateral pg_temp.probe(pg_temp.cmd(),
  'Existing active/inactive profile',code=>'23514',message=>'La identidad de la invitación requiere verificación.',
  mutation=>format('insert into public.profiles(id,role,display_name,is_active) values(%L,''seller'',''Existing'',%L)',
    pg_temp.rid('user'),active))result;
select result.* from (values
  ('raw_app_meta_data=''{}''','Missing markers'),('deleted_at=now()','Deleted'),
  ('banned_until=now()+interval ''1 day''','Banned'),('is_anonymous=true','Anonymous'),
  ('is_sso_user=true','SSO'),('email_change=''other@example.invalid''','Email change'),
  ('email=''other@example.invalid''','Changed email'))v(assignment,description)
cross join lateral pg_temp.probe(pg_temp.cmd(),description,code=>'23514',
  message=>'La identidad de la invitación requiere verificación.',mutation=>
  'update auth.users set '||assignment||' where id=pg_temp.rid(''user'')')result;
select * from pg_temp.probe(pg_temp.cmd(),'Binding UUID mismatch',code=>'23514',
  message=>'La identidad de la invitación requiere verificación.',mutation=>
  $$update public.staff_invitation_identity_bindings set user_id=pg_temp.rid('actor',4)
  where invitation_id=pg_temp.rid('invite')$$);
select * from pg_temp.probe(pg_temp.cmd(),'Identity mismatch',code=>'23514',
  message=>'La identidad de la invitación requiere verificación.',mutation=>
  $$update auth.identities set provider_id='wrong' where user_id=pg_temp.rid('user')$$);
select * from pg_temp.probe(pg_temp.cmd(),'Competing marker',code=>'23514',
  message=>'La identidad de la invitación requiere verificación.',mutation=>
  $$insert into auth.users(id,email,raw_app_meta_data) select pg_temp.rid('extra'),
  'extra@example.invalid',raw_app_meta_data from auth.users where id=pg_temp.rid('user')$$);
select result.* from unnest(array[pg_temp.cmd(1),pg_temp.cmd(10,2),pg_temp.cmd(10,1,4)])v(command)
cross join lateral pg_temp.probe(command,'Shared request collision',code=>'23514',
  message=>'El identificador de solicitud ya tiene otros datos.')result;
create function pg_temp.oldcmd(request integer, invitation integer, action text) returns text language sql as $$
  select format('select to_jsonb(public.manage_staff_invitation_intent(%L,%L,%L,%L,%L,%L))',
    pg_temp.rid('request',request),pg_temp.rid('invite',invitation),pg_temp.rid('actor'),action,
    'bound-'||invitation||'@example.invalid','seller');
$$;
select result.* from unnest(array['create','resend','revoke'])action cross join lateral
  pg_temp.probe(pg_temp.oldcmd(10,1,action),'Old command rejects new request ID: '||action,
    code=>'23514',message=>'El identificador de solicitud ya tiene otros datos.')result;
select result.* from unnest(array['resend','revoke'])action cross join lateral
  pg_temp.probe(pg_temp.cmd(11),'New command rejects old action request',code=>'23514',
    message=>'El identificador de solicitud ya tiene otros datos.',mutation=>format(
      'insert into public.staff_invitation_requests(id,invitation_id,actor_id,action) values(%L,%L,%L,%L)',
      pg_temp.rid('request',11),pg_temp.rid('invite'),pg_temp.rid('actor'),action))result;
select * from pg_temp.probe(pg_temp.oldcmd(11,1,'resend'),'Legacy bound resend retry fails closed',
  code=>'23514',message=>'La identidad existente requiere verificación antes de continuar.',mutation=>
  $$insert into public.staff_invitation_requests(id,invitation_id,actor_id,action)
  values(pg_temp.rid('request',11),pg_temp.rid('invite'),pg_temp.rid('actor'),'resend')$$);
select result.* from (values(1,'create'),(11,'create'),(11,'resend'))v(request,action)
cross join lateral pg_temp.probe(pg_temp.oldcmd(request,1,action),'Legacy bound Auth fail closed',
  code=>'23514',message=>'La identidad existente requiere verificación antes de continuar.')result;
select * from pg_temp.probe(pg_temp.oldcmd(11,4,'resend'),'Legacy unbound resend',
  to_jsonb(pg_temp.rid('invite',4)),journal_request=>11,journal_invitation=>4,journal_action=>'resend');
set local role service_role;
select is(public.manage_staff_invitation_intent(pg_temp.rid('request',12),pg_temp.rid('invite'),
  pg_temp.rid('actor'),'revoke','bound-1@example.invalid','seller'),pg_temp.rid('invite'),
  'Legacy revoke works with bound Auth');
reset role;
select * from pg_temp.probe(pg_temp.oldcmd(12,1,'revoke'),'Legacy revoke exact retry',to_jsonb(pg_temp.rid('invite')));
select ok((select revoked_at is not null from public.staff_invitation_intents
  where id=pg_temp.rid('invite')),'Legacy revoke persists revocation');
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.rid('user')::text,true);
select is(public.is_active_staff(),false,'Resend grants no operational access');
select is(public.current_staff_role(),null::public.user_role,'Resend grants no assignment role');
reset role;
-- Restore pending fixture for insertion-failure proof, not a product workaround.
update public.staff_invitation_intents set revoked_at=null where id=pg_temp.rid('invite');
create function pg_temp.reject_request() returns trigger language plpgsql as $$
begin raise exception 'synthetic journal failure' using errcode='23514'; end;
$$;
create trigger reject_bound_request before insert on public.staff_invitation_requests
for each row when (new.action='bound_resend') execute function pg_temp.reject_request();
select * from pg_temp.probe(pg_temp.cmd(11),'Journal failure rolls back every effect',code=>'23514',
  message=>'synthetic journal failure');
select * from finish();
rollback;
