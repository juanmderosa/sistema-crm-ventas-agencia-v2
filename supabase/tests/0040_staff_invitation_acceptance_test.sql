-- SQL-role evidence only; all synthetic fixtures roll back.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create function pg_temp.acceptance_id(kind text, n integer) returns uuid
language sql as $$ select md5('acceptance-' || kind || '-' || n)::uuid $$;
create function pg_temp.acceptance_state() returns text
language plpgsql security definer set search_path = '' as $$
declare r record; contents text; state text := '';
begin
  for r in select schemaname, tablename from pg_catalog.pg_tables
    where schemaname = 'public' or (schemaname = 'auth' and tablename in ('users','identities'))
    order by schemaname, tablename
  loop
    execute pg_catalog.format('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text, %L) from %I.%I t',
      '[]',r.schemaname,r.tablename) into contents;
    state := state || r.schemaname || r.tablename || contents;
  end loop;
  for r in select schemaname, sequencename from pg_catalog.pg_sequences
    where schemaname in ('public','auth') order by schemaname, sequencename
  loop
    execute pg_catalog.format('select jsonb_build_array(last_value,is_called)::text from %I.%I',
      r.schemaname,r.sequencename) into contents;
    state := state || r.schemaname || r.sequencename || contents;
  end loop;
  return pg_catalog.md5(state);
end;
$$;
create function pg_temp.acceptance_command(invitation integer default 1,
  target integer default 1, name text default 'Example Person') returns text language sql as $$
  select format('select public.check_staff_invitation_acceptance(%L::uuid,%L::uuid,%L::text)',
    pg_temp.acceptance_id('invite',invitation),pg_temp.acceptance_id('user',target),name);
$$;

-- Capture outcomes/state before fixture rollback; emit TAP afterwards so its
-- counters survive. Execute as an actual caller, never a definer wrapper.
create function pg_temp.acceptance_probe(command text, description text,
  expected uuid default null, code text default null, message text default null,
  mutation text default null, caller text default 'service_role')
returns setof text language plpgsql as $$
declare
  actual uuid; actual_code text; actual_message text;
  before_state text; after_state text;
begin
  begin
    if mutation is not null then execute mutation; end if;
    before_state := pg_temp.acceptance_state();
    execute format('set local role %I',caller);
    begin
      execute command into actual;
    exception when others then
      get stacked diagnostics actual_code = returned_sqlstate, actual_message = message_text;
    end;
    after_state := pg_temp.acceptance_state();
    raise exception using errcode = 'ZX001';
  exception when sqlstate 'ZX001' then null;
  end;
  return next extensions.is(actual_code,code,description || ': SQLSTATE');
  return next extensions.is(actual_message,message,description || ': exact message');
  return next extensions.is(actual,expected,description || ': exact UUID');
  return next extensions.is(after_state,before_state,description || ': all protected rows and counters unchanged');
end;
$$;

insert into auth.users(id,email) values
  (pg_temp.acceptance_id('actor',1),'acceptance-owner@example.invalid');
insert into public.profiles(id,role,display_name,is_active)
values (pg_temp.acceptance_id('actor',1),'owner','Owner',true);
set local role service_role;
select is(public.manage_staff_invitation_intent(pg_temp.acceptance_id('request',n),
  pg_temp.acceptance_id('invite',n),pg_temp.acceptance_id('actor',1),'create',
  'acceptance-' || n || '@example.invalid',
  (case when n=2 then 'admin' else 'seller' end)::public.user_role),
  pg_temp.acceptance_id('invite',n),'Create prerequisite intent ' || n)
from generate_series(1,3)n;
reset role;
set local role service_role;
select lives_ok(format('select public.prepare_staff_invitation_identity(%L,%L,%L)',
  pg_temp.acceptance_id('invite',n),pg_temp.acceptance_id('actor',1),
  pg_temp.acceptance_id('nonce',n)),'Reserve prerequisite provenance ' || n)
from generate_series(1,3)n;
reset role;
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
select pg_temp.acceptance_id('user',n),'acceptance-' || n || '@example.invalid',now(),
  jsonb_build_object('staff_invitation_id',pg_temp.acceptance_id('invite',n),
    'staff_invitation_provenance',pg_temp.acceptance_id('nonce',n))
from generate_series(1,3)n;
insert into auth.identities(id,user_id,provider_id,provider,identity_data)
select pg_temp.acceptance_id('identity',n),pg_temp.acceptance_id('user',n),
  pg_temp.acceptance_id('user',n)::text,'email',jsonb_build_object(
    'sub',pg_temp.acceptance_id('user',n),'email','acceptance-' || n || '@example.invalid')
from generate_series(1,3)n;
set local role service_role;
select is(public.bind_staff_invitation_identity(pg_temp.acceptance_id('invite',n),
  pg_temp.acceptance_id('actor',1),pg_temp.acceptance_id('user',n),pg_temp.acceptance_id('nonce',n)),
  pg_temp.acceptance_id('user',n),'Bind prerequisite identity ' || n)
from generate_series(1,2)n;
reset role;

select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(),
  'Anon execution denied',null,'42501','permission denied for function check_staff_invitation_acceptance',null,'anon');
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(),
  'Authenticated execution denied',null,'42501','permission denied for function check_staff_invitation_acceptance',null,'authenticated');
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(),
  'Bound Seller preflight',pg_temp.acceptance_id('user',1));
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(2,2),
  'Bound Admin preflight',pg_temp.acceptance_id('user',2));
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(1,1,repeat('n',200)),
  'Exactly 200 characters allowed',pg_temp.acceptance_id('user',1));
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(1,1,' Example Person '),
  'Nonblank name is not trimmed or reserved',pg_temp.acceptance_id('user',1));
select result.* from unnest(array[
  pg_temp.acceptance_command(1,1,null),pg_temp.acceptance_command(1,1,''),
  pg_temp.acceptance_command(1,1,'   '),pg_temp.acceptance_command(1,1,repeat('n',201)),
  pg_temp.acceptance_command(null),pg_temp.acceptance_command(1,null)
])commands(command) cross join lateral pg_temp.acceptance_probe(command,
  'Invalid required argument: ' || command,null,'22023','Datos de finalización inválidos.')result;
select result.* from unnest(array[
  pg_temp.acceptance_command(99),pg_temp.acceptance_command(1,2),
  pg_temp.acceptance_command(3,3)
])commands(command) cross join lateral pg_temp.acceptance_probe(command,
  'Unknown/wrong/unbound identity: ' || command,null,'23514',
  'La identidad de la invitación requiere verificación.')result;

create function pg_temp.acceptance_bad(mutation text, description text)
returns setof text language sql as $$
  select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(),description,
    null,'23514','La identidad de la invitación requiere verificación.',mutation);
$$;
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(),'Pending revoked invitation',
  null,'23514','La invitación fue revocada. Cree una nueva invitación.',
  $$update public.staff_invitation_intents set revoked_at=now() where id=pg_temp.acceptance_id('invite',1)$$);
select * from pg_temp.acceptance_bad(
  $$update auth.users set raw_app_meta_data='{}' where id=pg_temp.acceptance_id('user',1)$$,
  'Missing server-owned provenance');
select result.* from (values
  ('email_confirmed_at=null','Unconfirmed email'),
  ('email=''ACCEPTANCE-1@example.invalid''','Noncanonical Auth email'),
  ('email=''changed@example.invalid''','Changed Auth email'),
  ('deleted_at=now()','Deleted identity'),
  ('banned_until=now()+interval ''1 day''','Banned identity'),
  ('is_anonymous=true','Anonymous identity'),
  ('is_sso_user=true','SSO identity'),
  ('email_change=''changed@example.invalid''','Pending email change'),
  ('raw_app_meta_data=raw_app_meta_data-''staff_invitation_id''','Missing invitation marker'),
  ('raw_app_meta_data=raw_app_meta_data-''staff_invitation_provenance''','Missing provenance marker'),
  ('raw_app_meta_data=jsonb_set(raw_app_meta_data,''{staff_invitation_id}'',to_jsonb(pg_temp.acceptance_id(''invite'',2)))','Changed invitation marker'),
  ('raw_app_meta_data=jsonb_set(raw_app_meta_data,''{staff_invitation_provenance}'',to_jsonb(pg_temp.acceptance_id(''nonce'',2)))','Changed provenance marker')
)cases(assignment,description) cross join lateral pg_temp.acceptance_bad(
  'update auth.users set ' || assignment || ' where id=pg_temp.acceptance_id(''user'',1)',description)result;
select result.* from (values
  ('provider=''google''','Missing email provider'),
  ('provider_id=''unrelated''','Wrong provider UUID'),
  ('identity_data=identity_data-''sub''','Missing identity subject'),
  ('identity_data=jsonb_set(identity_data,''{sub}'',to_jsonb(pg_temp.acceptance_id(''user'',2)))','Changed identity subject'),
  ('identity_data=jsonb_set(identity_data,''{email}'',''"ACCEPTANCE-1@example.invalid"'')','Noncanonical identity email'),
  ('identity_data=jsonb_set(identity_data,''{email}'',''"changed@example.invalid"'')','Changed identity email')
)cases(assignment,description) cross join lateral pg_temp.acceptance_bad(
  'update auth.identities set ' || assignment || ' where user_id=pg_temp.acceptance_id(''user'',1)',description)result;
select * from pg_temp.acceptance_bad(
  $$insert into auth.identities(id,user_id,provider_id,provider,identity_data)
  values(pg_temp.acceptance_id('extra',1),pg_temp.acceptance_id('user',1),'extra','google','{}')$$,
  'Multiple provider identities');
select * from pg_temp.acceptance_bad(
  $$insert into auth.users(id,email) values(pg_temp.acceptance_id('extra',1),'ACCEPTANCE-1@example.invalid')$$,
  'Ambiguous normalized Auth email');
select * from pg_temp.acceptance_bad(
  $$insert into auth.users(id,email,raw_app_meta_data) select pg_temp.acceptance_id('extra',1),
  'extra@example.invalid',raw_app_meta_data from auth.users where id=pg_temp.acceptance_id('user',1)$$,
  'Ambiguous app provenance');
select * from pg_temp.acceptance_bad(
  $$update auth.identities set identity_data=jsonb_set(identity_data,'{email}',
  '"ACCEPTANCE-1@example.invalid"') where user_id=pg_temp.acceptance_id('user',2)$$,
  'Ambiguous normalized identity email');
select result.* from unnest(array[true,false])active(value)
cross join lateral pg_temp.acceptance_bad(format(
  'insert into public.profiles(id,role,display_name,is_active) values(%L,''seller'',''Existing'',%L)',
  pg_temp.acceptance_id('user',1),value),'Existing operational or inactive profile: ' || value)result;
select is((select count(*)::integer from public.profiles
  where id in (pg_temp.acceptance_id('user',1),pg_temp.acceptance_id('user',2))),0,
  'All pending preflight calls leave no operational profile');
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.acceptance_id('user',1)::text,true);
select is(public.is_active_staff(),false,'Pending preflight grants no access');
select is(public.current_staff_role(),null::public.user_role,'Pending preflight grants no assignment role');
reset role;

-- Acceptance does not re-authorize the original inviter.
insert into auth.users(id,email) values(pg_temp.acceptance_id('actor',2),'other-owner@example.invalid');
insert into public.profiles(id,role,display_name,is_active)
values(pg_temp.acceptance_id('actor',2),'owner','Other Owner',true);
update public.profiles set role='seller',is_active=false where id=pg_temp.acceptance_id('actor',1);
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(2,2),
  'Admin acceptance survives inviter authorization loss',pg_temp.acceptance_id('user',2));
set local role service_role;
select is(public.complete_staff_invitation(pg_temp.acceptance_id('invite',n),
  pg_temp.acceptance_id('user',n),' Example Person '),pg_temp.acceptance_id('user',n),
  'Existing completion still accepts after preflight ' || n) from generate_series(1,2)n;
reset role;
select is((select role::text from public.profiles where id=pg_temp.acceptance_id('user',1)),
  'seller','Completion preserves invited Seller role');
select is((select role::text from public.profiles where id=pg_temp.acceptance_id('user',2)),
  'admin','Completion preserves invited Admin role');
update public.profiles set role='admin',is_active=false,display_name='Later name'
where id=pg_temp.acceptance_id('user',1);
update public.profiles set role='seller',is_active=false,display_name='Later name'
where id=pg_temp.acceptance_id('user',2);
update public.staff_invitation_intents set revoked_at=now()
where id in (pg_temp.acceptance_id('invite',1),pg_temp.acceptance_id('invite',2));
update auth.users set raw_app_meta_data='{}',email_confirmed_at=null
where id in (pg_temp.acceptance_id('user',1),pg_temp.acceptance_id('user',2));
select result.* from generate_series(1,2)n cross join lateral pg_temp.acceptance_probe(
  pg_temp.acceptance_command(n,n,' Example Person '),'Completed exact retry ' || n,
  pg_temp.acceptance_id('user',n))result;
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(1,1,'Example Person'),
  'Completed retry must retain original untrimmed name',null,'23514',
  'La identidad de la invitación requiere verificación.');
select * from pg_temp.acceptance_probe(pg_temp.acceptance_command(1,2,' Example Person '),
  'Completed retry must retain original bound UUID',null,'23514',
  'La identidad de la invitación requiere verificación.');
select set_config('acceptance_test.before',pg_temp.acceptance_state(),true);
set local role service_role;
select is(public.complete_staff_invitation(pg_temp.acceptance_id('invite',1),
  pg_temp.acceptance_id('user',1),' Example Person '),pg_temp.acceptance_id('user',1),
  'Existing completed retry returns original UUID');
select is(pg_temp.acceptance_state(),current_setting('acceptance_test.before'),
  'Existing completed retry leaves all protected rows and counters unchanged');
reset role;
select * from finish();
rollback;
