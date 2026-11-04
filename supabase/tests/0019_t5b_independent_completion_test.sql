begin;
set search_path=public,extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();
create temp table checks(label text);
create function pg_temp.checkit(b boolean,label text) returns void language plpgsql as $$
begin
  if b is distinct from true then raise exception 'FAILED: %',label;end if;
  insert into checks values(label);
end$$;
create function pg_temp.id(k text,n int) returns uuid language sql immutable as $$
select md5('completion-'||k||'-'||n)::uuid$$;
create function pg_temp.snapshot(i uuid default null,v uuid default null) returns text language plpgsql as $$
declare t text;j jsonb;allrows jsonb:='[]';cond text;
begin
  foreach t in array array['profiles','vehicles','contacts','inquiries','inquiry_interests',
    'inquiry_assignment_history','reservations','sale_reviews','inquiry_status_history','confirmed_sales'] loop
    cond:=case when t='vehicles' then '(id is distinct from $2)' when t='inquiries' then '(id is distinct from $1)'
      when t in('profiles','contacts') then 'true' else '(inquiry_id is distinct from $1)' end;
    execute 'select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]''::jsonb) from public.'
      ||quote_ident(t)||' x where '||cond into j using i,v;
    allrows:=allrows||jsonb_build_array(jsonb_build_object(t,j));
  end loop;
  return md5(allrows::text);
end$$;
create function pg_temp.call(a int,cmd text,code text default '00000',msg text default '',r text default 'authenticated')
returns jsonb language plpgsql as $$
declare beforehash text:=pg_temp.snapshot();c text:='00000';m text:='';result jsonb;
begin
  perform set_config('request.jwt.claim.sub',pg_temp.id('actor',a)::text,true);
  perform set_config('role',r,true);
  begin execute cmd into result;exception when others then get stacked diagnostics c=returned_sqlstate,m=message_text;end;
  perform set_config('role','none',true);
  perform pg_temp.checkit(c=code and m=msg,'exact result got '||c||'/'||m||' '||r||' actor '||a||' '||cmd);
  if code<>'00000' then perform pg_temp.checkit(beforehash=pg_temp.snapshot(),'unchanged rejected command '||cmd);end if;
  return result;
end$$;
insert into auth.users(id,email)
select md5('completion-actor-'||n)::uuid,'independent'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('completion-actor-'||n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,
  'Independent '||n,n<>5 from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year,publication_status)
select md5('completion-vehicle-'||n)::uuid,'Probe','Model',2024,'published' from generate_series(1,50)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('completion-contact-1')::uuid,'+5491198776611','Probe');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name,submitted_email)
select md5('completion-inquiry-'||n)::uuid,md5('completion-submission-'||n)::uuid,md5('completion-contact-1')::uuid,
  md5('completion-vehicle-'||n)::uuid,md5('completion-actor-3')::uuid,'+5491198776611','Probe','probe@example.invalid'
from generate_series(1,50)n;
insert into public.inquiry_interests(inquiry_id,vehicle_id)
select md5('completion-inquiry-'||i)::uuid,md5('completion-vehicle-'||v)::uuid
from generate_series(1,50)i cross join generate_series(1,50)v;

-- Only this transaction's fixture identities are modified.
update public.profiles set role='owner',is_active=false where id=pg_temp.id('actor',6);
-- Five success shapes, each isolated by a complete unrelated-row hash.
do $$declare
  i int;decision boolean;ownreservation boolean;v uuid;q uuid;rv uuid;b text;
  oldv jsonb;oldi jsonb;oldr jsonb;oldhistory jsonb;oldreservation jsonb;links text;h int;
  ans jsonb;afterv jsonb;afteri jsonb;rr public.reservations%rowtype;sr public.sale_reviews%rowtype;cs public.confirmed_sales%rowtype;
begin
  for i in 1..5 loop
    decision:=i<=2;ownreservation:=i in(2,3);v:=pg_temp.id('vehicle',i);q:=pg_temp.id('inquiry',i);
    if ownreservation then perform pg_temp.call(3,format('select public.reserve_inquiry_vehicle(%L,%L)',q,v));end if;
    perform pg_temp.call(3,format('select public.report_inquiry_sale(%L,%L)',q,v));
    if i=5 then perform pg_temp.call(3,format('select public.reserve_inquiry_vehicle(%L,%L)',pg_temp.id('inquiry',20),v));end if;
    select id into rv from public.sale_reviews where inquiry_id=q;
    b:=pg_temp.snapshot(q,case when decision or ownreservation then v else null end);
    select to_jsonb(t) into oldv from public.vehicles t where id=v;
    select to_jsonb(t) into oldi from public.inquiries t where id=q;
    select to_jsonb(t) into oldr from public.sale_reviews t where id=rv;
    select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') into oldhistory from public.inquiry_status_history t where inquiry_id=q;
    select count(*) into h from public.inquiry_status_history where inquiry_id=q;
    select to_jsonb(t) into oldreservation from public.reservations t where inquiry_id=q;
    select md5(jsonb_build_array(
      (select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from public.inquiry_interests t),
      (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t))::text) into links;
    ans:=pg_temp.call(1,format('select public.resolve_sale_review(%L,%L)',rv,decision));
    perform pg_temp.checkit(b=pg_temp.snapshot(q,case when decision or ownreservation then v else null end),'success shape '||i||' unrelated rows byte-identical');
    perform pg_temp.checkit(links=(select md5(jsonb_build_array(
      (select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from public.inquiry_interests t),
      (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t))::text)),
      'shape '||i||' all interests and assignment history byte-identical');
    select to_jsonb(t) into afterv from public.vehicles t where id=v;
    select to_jsonb(t) into afteri from public.inquiries t where id=q;
    perform pg_temp.checkit((oldv-'availability_status'-'updated_at')=(afterv-'availability_status'-'updated_at'),'shape '||i||' selected vehicle only allowed fields');
    perform pg_temp.checkit(afterv->>'availability_status'=case when decision then 'sold' when ownreservation then 'available' when i=5 then 'reserved' else 'available' end,'shape '||i||' expected inventory state');
    perform pg_temp.checkit((oldi-'status'-'updated_at')=(afteri-'status'-'updated_at') and afteri->>'status'=case when decision then 'sale_reported' else 'closed_without_sale' end,'shape '||i||' inquiry fields/status');
    select * into sr from public.sale_reviews where id=rv;
    perform pg_temp.checkit((oldr-'status'-'resolved_at'-'resolved_by')=(to_jsonb(sr)-'status'-'resolved_at'-'resolved_by')
      and sr.status=case when decision then 'confirmed' else 'rejected' end and sr.resolved_by=pg_temp.id('actor',1)
      and sr.resolved_at is not null,'shape '||i||' resolved task fields');
    perform pg_temp.checkit(ans->>'review_id'=rv::text and ans->>'status'=sr.status,'shape '||i||' exact response linkage');
    perform pg_temp.checkit(h+case when decision then 0 else 1 end=(select count(*) from public.inquiry_status_history where inquiry_id=q),'shape '||i||' history count');
    perform pg_temp.checkit(not exists(select 1 from jsonb_array_elements(oldhistory) x
      where not exists(select 1 from public.inquiry_status_history t where to_jsonb(t)=x)),'shape '||i||' old target history preserved');
    if decision then
      select * into strict cs from public.confirmed_sales where inquiry_id=q;
      perform pg_temp.checkit(cs.vehicle_id=v and cs.review_id=rv and cs.contact_id=pg_temp.id('contact',1)
        and cs.confirmed_by=pg_temp.id('actor',1) and cs.responsible_id=pg_temp.id('actor',3)
        and cs.confirmed_at is not null and ans->>'sale_id'=cs.id::text,'shape '||i||' ledger attribution');
    else
      perform pg_temp.checkit(not exists(select 1 from public.confirmed_sales where inquiry_id=q) and ans->>'sale_id' is null,'shape '||i||' no sale');
      perform pg_temp.checkit(exists(select 1 from public.inquiry_status_history where inquiry_id=q and review_id=rv
        and from_status='sale_reported' and to_status='closed_without_sale' and actor_id=pg_temp.id('actor',1)),
        'shape '||i||' rejection correction history');
    end if;
    if ownreservation then
      select * into strict rr from public.reservations where inquiry_id=q;
      perform pg_temp.checkit((oldreservation-'status'-'ended_at'-'cancelled_by'-'completed_by')=
        (to_jsonb(rr)-'status'-'ended_at'-'cancelled_by'-'completed_by'),'shape '||i||' reservation immutable fields preserved');
      perform pg_temp.checkit(rr.vehicle_id=v and rr.contact_id=pg_temp.id('contact',1) and rr.created_by=pg_temp.id('actor',3)
        and rr.ended_at is not null and rr.status::text=case when decision then 'completed' else 'cancelled' end
        and (case when decision then rr.completed_by=pg_temp.id('actor',1) and rr.cancelled_by is null
          else rr.cancelled_by=pg_temp.id('actor',1) and rr.completed_by is null end),'shape '||i||' reservation terminal attribution');
    else perform pg_temp.checkit(not exists(select 1 from public.reservations where inquiry_id=q),'shape '||i||' no invented reservation');end if;
  end loop;
end$$;
select pg_temp.call(6,format('select public.resolve_sale_review(%L,true)',
  (select id from public.sale_reviews where inquiry_id=pg_temp.id('inquiry',1))),'42501','sale resolution access denied');
set local role authenticated;
select set_config('request.jwt.claim.sub',pg_temp.id('actor',6)::text,true);
select set_config('completion.inactive_read',(select count(*)::text from public.confirmed_sales),true);
reset role;
select pg_temp.checkit(current_setting('completion.inactive_read')='0','inactive Owner cannot read ledger');
-- Owner INSERT already exercised; cover the remaining application roles.
do $$declare a int;r text;c text;m text;cmd text;begin
  cmd:='insert into public.vehicles(brand,model,year,availability_status) values(''Completion'',''Direct'',2024,''sold'') returning to_jsonb(vehicles.*)';
  for a in 2..5 loop
    r:=case a when 4 then 'service_role' when 5 then 'anon' else 'authenticated' end;
    c:=case when a in(2,3) then '22023' else '42501' end;
    m:=case when a in(2,3) then 'confirm an inquiry sale before marking the vehicle Sold' else 'permission denied for table vehicles' end;
    perform pg_temp.call(a,cmd,c,m,r);
  end loop;
end$$;
-- Privileged maintenance does not grant its exemption to application roles.
insert into public.vehicles(id,brand,model,year,availability_status)
values(pg_temp.id('vehicle',60),'Completion','Historical',2020,'sold');
update public.vehicles set model='Historical maintained' where id=pg_temp.id('vehicle',60);
select pg_temp.checkit(exists(select 1 from public.vehicles where id=pg_temp.id('vehicle',60)
  and availability_status='sold' and model='Historical maintained') and not exists(
    select 1 from public.confirmed_sales where vehicle_id=pg_temp.id('vehicle',60)),
  'database owner historical fixture maintenance permitted');
select pg_temp.call(1,format('update public.vehicles set availability_status=''sold'' where id=%L returning to_jsonb(vehicles.*)',pg_temp.id('vehicle',10)),
  '22023','confirm an inquiry sale before marking the vehicle Sold');
select pg_temp.call(1,format('update public.vehicles set availability_status=''sold'' where id=%L returning to_jsonb(vehicles.*)',pg_temp.id('vehicle',10)),
  '42501','permission denied for table vehicles','service_role');
do $$declare i int;rv uuid;msg text;begin
  for i in 7..8 loop
    perform pg_temp.call(3,format('select public.report_inquiry_sale(%L,%L)',pg_temp.id('inquiry',i),pg_temp.id('vehicle',i)));
    select id into rv from public.sale_reviews where inquiry_id=pg_temp.id('inquiry',i);
    if i=7 then
      perform pg_temp.call(1,format('update public.vehicles set deleted_at=now() where id=%L returning to_jsonb(vehicles.*)',pg_temp.id('vehicle',i)));
      msg:='vehicle must exist and be enabled for sale';
    else
      delete from public.inquiry_interests where inquiry_id=pg_temp.id('inquiry',i) and vehicle_id=pg_temp.id('vehicle',i);
      msg:='vehicle is not an interest of this inquiry';
    end if;
    perform pg_temp.call(1,format('select public.resolve_sale_review(%L,true)',rv),'22023',msg);
    perform pg_temp.checkit(exists(select 1 from public.sale_reviews where id=rv and status='pending'
      and resolved_by is null and resolved_at is null),'eligibility rejection '||i||' retains pending task');
  end loop;
end$$;
select ok(true,label) from checks;
select * from finish();
rollback;
