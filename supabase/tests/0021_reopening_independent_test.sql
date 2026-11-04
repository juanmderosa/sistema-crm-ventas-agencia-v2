begin;
set search_path=public,extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id,email)
select md5('independent-actor-'||n)::uuid,'independent-'||n||'@example.invalid' from generate_series(1,8)n;
insert into profiles(id,role,display_name,is_active)
select md5('independent-actor-'||n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' when 5 then 'owner' when 6 then 'admin' else 'seller' end)::user_role,
  'Independent '||n,n<5 from generate_series(1,7)n;
insert into vehicles(id,brand,model,year,publication_status)
select md5('independent-vehicle-'||n)::uuid,'Independent','Model '||n,2024,'published' from generate_series(1,20)n;
insert into contacts(id,normalized_phone,display_name)
values(md5('independent-contact')::uuid,'+5491176762345','Independent');
insert into inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name)
select md5('independent-inquiry-'||n)::uuid,md5('independent-submission-'||n)::uuid,md5('independent-contact')::uuid,
  md5('independent-vehicle-'||n)::uuid,md5('independent-actor-3')::uuid,'+5491176762345','Independent'
from generate_series(1,20)n;
insert into inquiry_interests(inquiry_id,vehicle_id)
select id,originating_vehicle_id from inquiries where id in(
  select md5('independent-inquiry-'||n)::uuid from generate_series(1,20)n);
update inquiries set status='closed_without_sale' where id in(
  select md5('independent-inquiry-'||n)::uuid from generate_series(1,12)n);
-- Only this fixture's rows are prepared; all public operations use actual roles.
do $$declare n int;begin
  for n in 13..18 loop
    perform set_config('request.jwt.claim.sub',md5('independent-actor-3')::uuid::text,true);
    perform set_config('role','authenticated',true);
    perform report_inquiry_sale(md5('independent-inquiry-'||n)::uuid,md5('independent-vehicle-'||n)::uuid);
    perform set_config('role','none',true);
  end loop;
  for n in 13..15 loop
    perform set_config('request.jwt.claim.sub',md5('independent-actor-1')::uuid::text,true);
    perform set_config('role','authenticated',true);
    perform resolve_sale_review((select id from sale_reviews where inquiry_id=md5('independent-inquiry-'||n)::uuid),n<>15);
    perform set_config('role','none',true);
  end loop;
end$$;
create function pg_temp.snap(skip uuid default null) returns text language plpgsql as $$
declare t text;a jsonb='{}';v jsonb;begin
  for t in select tablename from pg_tables where schemaname='public' loop
    if t='inquiries' then
      execute 'select coalesce(jsonb_agg(x order by x::text),''[]'') from (select to_jsonb(z) x from public.inquiries z where id is distinct from $1) q' into v using skip;
    elsif t='inquiry_status_history' then
      execute 'select coalesce(jsonb_agg(x order by x::text),''[]'') from (select to_jsonb(z) x from public.inquiry_status_history z where inquiry_id is distinct from $1) q' into v using skip;
    else
      execute format('select coalesce(jsonb_agg(x order by x::text),''[]'') from (select to_jsonb(z) x from public.%I z) q',t) into v;
    end if;
    a=a||jsonb_build_object(t,v);
  end loop;
  return md5(a::text);
end$$;
create function pg_temp.probe(a int,n int,c text,m text,rr text default 'authenticated')
returns text language plpgsql as $$
declare i uuid=md5('independent-inquiry-'||n)::uuid;b text;h jsonb;old public.inquiry_status;
  j jsonb;ec text='00000';em text='';begin
  b=pg_temp.snap(case when c='00000' then i else null end);
  select status into old from inquiries where id=i;
  select coalesce(jsonb_agg(to_jsonb(t)),'[]') into h from inquiry_status_history t where inquiry_id=i;
  perform set_config('request.jwt.claim.sub',md5('independent-actor-'||a)::uuid::text,true);
  perform set_config('role',rr,true);
  begin j=public.reopen_inquiry(i);
  exception when others then get stacked diagnostics ec=returned_sqlstate,em=message_text;end;
  perform set_config('role','none',true);
  if ec<>c or (c<>'00000' and em<>m) then raise exception 'Wrong result actor %, inquiry %: % %',a,n,ec,em;end if;
  if b<>pg_temp.snap(case when c='00000' then i else null end) then raise exception 'State changed unexpectedly';end if;
  if c='00000' then
    if j<>jsonb_build_object('inquiry_id',i,'status','following_up')
      or (select status from inquiries where id=i)<>'following_up' then raise exception 'response/state mismatch';end if;
    if (select count(*) from inquiry_status_history where inquiry_id=i)<>jsonb_array_length(h)+1 then raise exception 'history count';end if;
    if exists(select 1 from jsonb_array_elements(h)x where not exists(
      select 1 from inquiry_status_history t where to_jsonb(t)=x)) then raise exception 'lost history';end if;
    if (select count(*) from inquiry_status_history where inquiry_id=i and from_status=old
      and to_status='following_up' and actor_id=md5('independent-actor-'||a)::uuid)<>1 then raise exception 'attribution';end if;
  end if;
  return ok(true,'independent reopening actor='||a||' inquiry='||n||' SQLSTATE='||ec);
end$$;
select pg_temp.probe(4,1,'42501','inquiry reopening access denied');
select pg_temp.probe(5,1,'42501','inquiry reopening access denied');
select pg_temp.probe(6,1,'42501','inquiry reopening access denied');
select pg_temp.probe(7,1,'42501','inquiry reopening access denied');
select pg_temp.probe(8,1,'42501','inquiry reopening access denied');
select pg_temp.probe(1,1,'42501','permission denied for function reopen_inquiry','anon');
select pg_temp.probe(1,1,'42501','permission denied for function reopen_inquiry','service_role');
select pg_temp.probe(3,999,'42501','inquiry reopening access denied');
select pg_temp.probe(3,20,'22023','inquiry is not closed');
select pg_temp.probe(3,13,'42501','inquiry reopening access denied');
select pg_temp.probe(3,16,'42501','inquiry reopening access denied');
select pg_temp.probe(1,16,'22023','resolve the pending sale review before reopening the inquiry');
select pg_temp.probe(2,16,'22023','resolve the pending sale review before reopening the inquiry');
select pg_temp.probe(3,1,'00000','');
select pg_temp.probe(1,2,'00000','');
select pg_temp.probe(2,3,'00000','');
select pg_temp.probe(1,13,'00000','');
select pg_temp.probe(2,14,'00000','');
select pg_temp.probe(3,15,'00000','');
select pg_temp.probe(3,1,'22023','inquiry is not closed');
select ok((select count(*) from confirmed_sales)=2 and
  (select count(*) from vehicles where availability_status='sold')=2,'confirmed sales and Sold inventory retained');
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('independent-actor-4')::uuid::text,true);
select is((select count(*) from inquiry_status_history),0::bigint,'coworker reopening history stays private');
reset role;
select * from finish();
rollback;
