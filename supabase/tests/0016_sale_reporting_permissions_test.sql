begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id,email)
select md5('bounded-actor-'||n)::uuid,'bounded-'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('bounded-actor-'||n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
  'Bounded actor '||n,n not in (5,6,7) from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year,publication_status,sale_enabled,deleted_at,availability_status)
select md5('bounded-vehicle-'||n)::uuid,'Bounded','Vehicle '||n,2024,
  (case when n=10 then 'draft' else 'published' end)::public.vehicle_publication_status,
  n<>6,case when n=7 then now() end,
  (case when n=9 then 'sold' else 'available' end)::public.vehicle_availability_status from generate_series(1,30)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('bounded-contact')::uuid,'+5491199988877','Bounded contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name,submitted_email)
select md5('bounded-inquiry-'||n)::uuid,md5('bounded-submission-'||n)::uuid,md5('bounded-contact')::uuid,md5('bounded-vehicle-1')::uuid,
  md5('bounded-actor-'||case when n=2 then 4 else 3 end)::uuid,'+5491199988877','Bounded','bounded@example.invalid'
from generate_series(1,30)n;
insert into public.inquiry_interests(inquiry_id,vehicle_id)
select md5('bounded-inquiry-'||i)::uuid,md5('bounded-vehicle-'||v)::uuid
from generate_series(1,30)i cross join generate_series(1,9)v where v<>8;
create function pg_temp.bounded_state() returns text language sql as $$
select md5(jsonb_build_array(
  (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.sale_reviews t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_status_history t),
  (select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from public.inquiry_interests t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t)
)::text);
$$;
create function pg_temp.check_call(actor int, command text, code text, message text,
  label text, api_role text default 'authenticated') returns text language plpgsql as $$
declare b text:=pg_temp.bounded_state(); c text:='00000'; m text:=''; result text;
begin
  perform set_config('request.jwt.claim.sub',md5('bounded-actor-'||actor)::uuid::text,true);
  perform set_config('role',api_role,true);
  begin execute command into result;
  exception when others then get stacked diagnostics c=returned_sqlstate,m=message_text; end;
  perform set_config('role','none',true);
  if c<>code or (message is not null and m<>message) then
    raise exception '% expected %/% got %/%',label,code,message,c,m;
  end if;
  if code<>'00000' and b<>pg_temp.bounded_state() then
    raise exception '% changed persisted state',label;
  end if;
  return ok(true,label);
end $$;
create function pg_temp.report_command(i int,v int) returns text language sql as $$
select format('select public.report_inquiry_sale(%L::uuid,%L::uuid)',md5('bounded-inquiry-'||i),md5('bounded-vehicle-'||v));
$$;
create function pg_temp.check_visibility(actor int,expected int,api_role text default 'authenticated')
returns text language plpgsql as $$
declare a int; b int; c text; msg text;
begin
  perform set_config('request.jwt.claim.sub',md5('bounded-actor-'||actor)::uuid::text,true);
  perform set_config('role',api_role,true);
  begin
    select count(*) into a from public.sale_reviews
    where inquiry_id in(select md5('bounded-inquiry-'||n)::uuid from generate_series(1,5)n);
    select count(*) into b from public.inquiry_status_history
    where inquiry_id in(select md5('bounded-inquiry-'||n)::uuid from generate_series(1,5)n);
  exception when others then get stacked diagnostics c=returned_sqlstate,msg=message_text; end;
  perform set_config('role','none',true);
  if api_role='anon' then
    if c is distinct from '42501' or msg is distinct from 'permission denied for table sale_reviews' then
      raise exception 'anonymous visibility unexpected %/%',c,msg;
    end if;
  elsif c is not null or a is distinct from expected or b is distinct from expected then
    raise exception 'actor % visibility %/% expected %',actor,a,b,expected;
  end if;
  return ok(true,'review/history visibility actor='||actor||' role='||api_role);
end $$;
create function pg_temp.report_positive(actor int,i int,v int,label text) returns text language plpgsql as $$
declare before_unchanged text; after_unchanged text; r text; review uuid;
begin
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t where id<>md5('bounded-inquiry-'||i)::uuid)
  )::text) into before_unchanged;
  r:=pg_temp.check_call(actor,pg_temp.report_command(i,v),'00000',null,label);
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
    (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t where id<>md5('bounded-inquiry-'||i)::uuid)
  )::text) into after_unchanged;
  if before_unchanged is distinct from after_unchanged then
    raise exception '% altered inventory/reservations/other inquiries',label;
  end if;
  select id into strict review from public.sale_reviews
  where inquiry_id=md5('bounded-inquiry-'||i)::uuid and vehicle_id=md5('bounded-vehicle-'||v)::uuid
    and contact_id=md5('bounded-contact')::uuid and reported_by=md5('bounded-actor-'||actor)::uuid and status='pending';
  if (select count(*) from public.inquiry_status_history where review_id=review
    and inquiry_id=md5('bounded-inquiry-'||i)::uuid and actor_id=md5('bounded-actor-'||actor)::uuid
    and from_status='new' and to_status='sale_reported')<>1 then
    raise exception '% incorrect history',label;
  end if;
  if not exists(select 1 from public.inquiries where id=md5('bounded-inquiry-'||i)::uuid and status='sale_reported') then
    raise exception '% inquiry not reported',label;
  end if;
  return r;
end $$;
select pg_temp.report_positive(3,1,2,'seller own added interest');
select pg_temp.report_positive(4,2,3,'coworker own');
select pg_temp.report_positive(1,3,1,'Owner other inquiry');
select pg_temp.report_positive(2,4,4,'Admin other inquiry');
select pg_temp.check_call(3,format('select public.reserve_inquiry_vehicle(%L,%L)',md5('bounded-inquiry-5'),md5('bounded-vehicle-5')),'00000',null,'own reserve');
select pg_temp.report_positive(3,5,5,'own reserved report');
select pg_temp.check_visibility(3,4);
select pg_temp.check_visibility(4,1);
select pg_temp.check_visibility(1,5);
select pg_temp.check_visibility(2,5);
select pg_temp.check_visibility(n,0) from generate_series(5,8)n;
select pg_temp.check_visibility(3,0,'anon');
select pg_temp.check_call(n,pg_temp.report_command(6,1),'42501','sale access denied','inactive/no-profile report '||n) from generate_series(5,8)n;
select pg_temp.check_call(4,pg_temp.report_command(6,1),'42501','sale access denied','coworker report denied');
select pg_temp.check_call(3,pg_temp.report_command(6,1),'42501','permission denied for function report_inquiry_sale','anonymous report','anon');
select pg_temp.check_call(3,pg_temp.report_command(6,6),'22023','vehicle must exist and be enabled for sale','blocked');
select pg_temp.check_call(3,pg_temp.report_command(6,7),'22023','vehicle must exist and be enabled for sale','deleted');
select pg_temp.check_call(3,pg_temp.report_command(6,8),'22023','vehicle is not an interest of this inquiry','noninterest');
select pg_temp.check_call(3,pg_temp.report_command(6,9),'22023','vehicle must be Available or reserved by this inquiry','sold');
select pg_temp.check_call(3,pg_temp.report_command(5,1),'22023','report the vehicle reserved by this inquiry','own reservation wrong target');
select pg_temp.check_call(3,format('select public.reserve_inquiry_vehicle(%L,%L)',md5('bounded-inquiry-7'),md5('bounded-vehicle-1')),'00000',null,'competing reserve fixture');
select pg_temp.check_call(3,pg_temp.report_command(6,1),'22023','vehicle must be Available or reserved by this inquiry','competing reservation report');
select pg_temp.check_call(a,format('%s public.%I %s',op,t,suffix),'42501','permission denied for table '||t,
  'direct mutation actor='||a||' '||op||' '||t,case when a=0 then 'anon' else 'authenticated' end)
from generate_series(0,8)a cross join (values('sale_reviews'),('inquiry_status_history'))tables(t)
cross join (values('update','set id=id'),('delete from',''),('insert into','default values'))commands(op,suffix);
select pg_temp.check_call(0,'select count(*) from public.inquiry_status_history','42501','permission denied for table inquiry_status_history','anonymous history','anon');
select ok(
  (select count(*) from public.sale_reviews where inquiry_id in(select md5('bounded-inquiry-'||n)::uuid from generate_series(1,5)n)
    and status='pending' and contact_id=md5('bounded-contact')::uuid)=5
  and (select count(*) from public.inquiry_status_history where inquiry_id in(select md5('bounded-inquiry-'||n)::uuid from generate_series(1,5)n)
    and from_status='new' and to_status='sale_reported')=5
  and (select availability_status='reserved' from public.vehicles where id=md5('bounded-vehicle-5')::uuid)
  and (select status='active' from public.reservations where inquiry_id=md5('bounded-inquiry-5')::uuid),
  'exact linkage/history and reserved inventory retained');
select * from finish();
rollback;
