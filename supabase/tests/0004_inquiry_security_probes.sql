-- Independent adversarial probes retained as rollback regression tests.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

create temp table probe_ids as select n, gen_random_uuid() id from generate_series(1,10) n;
grant select on probe_ids to authenticated, anon;
insert into auth.users(id) select id from probe_ids where n <= 6;
insert into public.profiles(id,role,display_name,is_active)
select id, (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,'Probe',n<>5 from probe_ids where n<=5;
insert into public.vehicles(id,brand,model,year) select id,'Probe','Probe',2026 from probe_ids where n=7;
insert into public.contacts(id,normalized_phone,display_name,email) select id,'+541155550987','Probe','probe@example.invalid' from probe_ids where n=8;
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_email)
select gen_random_uuid(),gen_random_uuid(),c.id,v.id,a.id,'Probe','probe@example.invalid' from probe_ids c,probe_ids v,probe_ids a where c.n=8 and v.n=7 and a.n in(3,4,5);
insert into public.inquiry_interests(inquiry_id,vehicle_id) select i.id,i.originating_vehicle_id from public.inquiries i join probe_ids c on c.id=i.contact_id and c.n=8;

create function pg_temp.fingerprint() returns text language sql as $$
select md5(string_agg(payload,'|' order by payload)) from (
  select row_to_json(t)::text payload from public.contacts t union all
  select row_to_json(t)::text from public.inquiries t union all
  select row_to_json(t)::text from public.inquiry_interests t union all
  select row_to_json(t)::text from public.vehicles t
) s
$$;

do $$
declare
  actor int; uid uuid; expected int; actual int;
  tbl text; stmt text; before_hash text;
begin
  for actor in 0..6 loop
    select id into uid from probe_ids where n=actor;
    perform set_config('request.jwt.claims',json_build_object('sub',uid,'role',case when actor=0 then 'anon' else 'authenticated' end)::text,true);
    execute 'set local role ' || case when actor=0 then 'anon' else 'authenticated' end;
    if actor>0 then
      expected:=case when actor in(1,2) then 3 when actor in(3,4) then 1 else 0 end;
      select count(*) into actual from public.inquiries where contact_id=(select id from probe_ids where n=8);
      if actual<>expected then raise exception 'inquiry leak actor %, got % expected %',actor,actual,expected; end if;
      select count(*) into actual from public.inquiry_interests where vehicle_id=(select id from probe_ids where n=7);
      if actual<>expected then raise exception 'interest leak actor %',actor; end if;
      select count(*) into actual from public.contacts where id=(select id from probe_ids where n=8);
      if actual<>(case when expected>0 then 1 else 0 end) then raise exception 'contact leak actor %',actor; end if;
    else
      foreach tbl in array array['contacts','inquiries','inquiry_interests'] loop
        begin
          execute format('select * from public.%I',tbl);
          raise exception 'anon read allowed';
        exception when insufficient_privilege then null;
        end;
      end loop;
    end if;
    reset role;
    foreach tbl in array array['contacts','inquiries','inquiry_interests'] loop
      foreach stmt in array array[format('insert into public.%I default values',tbl),format('update public.%I set created_at=now()',tbl),format('delete from public.%I',tbl)] loop
        before_hash:=pg_temp.fingerprint();
        execute 'set local role ' || case when actor=0 then 'anon' else 'authenticated' end;
        begin
          execute stmt;
          raise exception 'write allowed: actor % %',actor,stmt;
        exception when insufficient_privilege then null;
        end;
        reset role;
        if pg_temp.fingerprint() is distinct from before_hash then raise exception 'mutation after denied write'; end if;
      end loop;
    end loop;
  end loop;
end $$;
select pass('seven identities: read isolation and 63 denied writes with unchanged data hashes');

do $$
declare stmt text; h text; phone text;
begin
  foreach stmt in array array[
    'delete from public.contacts where id=(select id from probe_ids where n=8)',
    'delete from public.vehicles where id=(select id from probe_ids where n=7)',
    'delete from public.profiles where id=(select id from probe_ids where n=3)',
    'delete from public.inquiries where contact_id=(select id from probe_ids where n=8)'
  ] loop
    h:=pg_temp.fingerprint();
    begin
      execute stmt;
      raise exception 'history deletion allowed';
    exception when foreign_key_violation then null;
    end;
    if pg_temp.fingerprint() is distinct from h then raise exception 'mutation after FK denial'; end if;
  end loop;
  if (select count(distinct creation_sequence) from public.inquiries where contact_id=(select id from probe_ids where n=8))<>3 then raise exception 'sequence duplicate'; end if;
  if exists(select 1 from public.vehicles where id=(select id from probe_ids where n=7) and availability_status<>'available') then raise exception 'inventory side effect'; end if;
  foreach phone in array array['','0','01112345678','+012345','+54 1112345678','+5412345678901234x','+1234567890123456'] loop
    h:=pg_temp.fingerprint();
    begin
      insert into public.contacts(normalized_phone,display_name,email) values(phone,'Probe','probe@example.invalid');
      raise exception 'invalid phone accepted';
    exception when check_violation then null;
    end;
    if pg_temp.fingerprint() is distinct from h then raise exception 'phone rejection mutated data'; end if;
  end loop;
end $$;
select pass('history guards, sequence, inventory and rejected phone input preserve invariants');
select * from finish();
rollback;
