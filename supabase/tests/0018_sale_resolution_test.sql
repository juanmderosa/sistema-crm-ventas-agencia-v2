begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','resolve_sale_review',array['uuid','boolean']);
insert into auth.users(id,email)
select md5('resolve-actor-'||n)::uuid,'resolve-'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('resolve-actor-'||n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
  'Resolution actor '||n,n not in (5,6,7) from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year,publication_status)
select md5('resolve-vehicle-'||n)::uuid,'Test','Resolve '||n,2024,'published' from generate_series(1,12)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('resolve-contact')::uuid,'+5491187654321','Resolution contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name)
select md5('resolve-inquiry-'||n)::uuid,md5('resolve-submission-'||n)::uuid,md5('resolve-contact')::uuid,
  md5('resolve-vehicle-1')::uuid,md5('resolve-actor-'||case when n=2 then 4 else 3 end)::uuid,
  '+5491187654321','Submitted' from generate_series(1,12)n;
insert into public.inquiry_interests(inquiry_id,vehicle_id)
select md5('resolve-inquiry-'||i)::uuid,md5('resolve-vehicle-'||v)::uuid
from generate_series(1,12)i cross join generate_series(1,12)v;
create function pg_temp.resolution_state() returns text language sql as $$
select md5(jsonb_build_array(
  (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.sale_reviews t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.confirmed_sales t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_status_history t),
  (select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from public.inquiry_interests t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t)
)::text) $$;
create function pg_temp.resolution_call(actor int,command text,expected text,label text,
  api_role text default 'authenticated') returns setof text language plpgsql as $$
declare before_all text:=pg_temp.resolution_state(); observed text:='00000';
begin
  perform set_config('request.jwt.claim.sub',md5('resolve-actor-'||actor)::uuid::text,true);
  perform set_config('role',api_role,true);
  begin execute command;
  exception when others then get stacked diagnostics observed=returned_sqlstate; end;
  perform set_config('role','none',true);
  return next is(observed,expected,label||': SQLSTATE');
  if expected<>'00000' then return next is(pg_temp.resolution_state(),before_all,label||': complete unchanged state'); end if;
end $$;
create function pg_temp.resolution_command(i int,confirmation boolean) returns text language sql as $$
select format('select public.resolve_sale_review(%L::uuid,%L::boolean)',
  (select id from public.sale_reviews where inquiry_id=md5('resolve-inquiry-'||i)::uuid),confirmation);
$$;
create function pg_temp.report_command(i int,v int) returns text language sql as $$
select format('select public.report_inquiry_sale(%L,%L)',md5('resolve-inquiry-'||i),md5('resolve-vehicle-'||v));
$$;
create function pg_temp.reserve_command(i int,v int) returns text language sql as $$
select format('select public.reserve_inquiry_vehicle(%L,%L)',md5('resolve-inquiry-'||i),md5('resolve-vehicle-'||v));
$$;
select * from pg_temp.resolution_call(3,pg_temp.report_command(1,1),'00000','report unreserved sale');
select pg_temp.resolution_call(n,pg_temp.resolution_command(1,true),'42501','nonadmin resolution denied '||n)
from generate_series(3,8)n;
select * from pg_temp.resolution_call(1,pg_temp.resolution_command(1,true),'42501','anonymous resolution denied','anon');
select * from pg_temp.resolution_call(1,'select public.resolve_sale_review(null,true)','22023','missing review input');
select * from pg_temp.resolution_call(1,pg_temp.resolution_command(1,null),'22023','missing decision');
select * from pg_temp.resolution_call(1,pg_temp.resolution_command(1,true),'00000','Owner confirms unreserved sale');
select is((select availability_status::text from public.vehicles where id=md5('resolve-vehicle-1')::uuid),'sold','explicit confirmation sells vehicle');
select is((select count(*) from public.confirmed_sales where vehicle_id=md5('resolve-vehicle-1')::uuid
  and inquiry_id=md5('resolve-inquiry-1')::uuid and contact_id=md5('resolve-contact')::uuid
  and confirmed_by=md5('resolve-actor-1')::uuid and responsible_id=md5('resolve-actor-3')::uuid),1::bigint,
  'confirmed sale retains concrete commercial attribution');
select is((select status from public.sale_reviews where inquiry_id=md5('resolve-inquiry-1')::uuid),'confirmed','confirmation resolves task');
select is((select status::text from public.inquiries where id=md5('resolve-inquiry-1')::uuid),'sale_reported','confirmed inquiry remains Venta concretada');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(1,true),'00000','confirmation retry is idempotent');
select is((select count(*) from public.confirmed_sales),1::bigint,'retry does not count unit twice');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(1,false),'22023','cannot reverse confirmed sale by rejection');
select * from pg_temp.resolution_call(1,format('update public.vehicles set availability_status=''available'' where id=%L',md5('resolve-vehicle-1')),'22023','cannot reverse confirmed inventory');
select * from pg_temp.resolution_call(4,pg_temp.reserve_command(2,2),'00000','seller reserves own inquiry');
select * from pg_temp.resolution_call(4,pg_temp.report_command(2,2),'00000','report reserved sale');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(2,true),'00000','Admin confirms reserved sale');
select ok((select status::text='completed' and ended_at is not null and completed_by=md5('resolve-actor-2')::uuid
  and cancelled_by is null from public.reservations where inquiry_id=md5('resolve-inquiry-2')::uuid),
  'confirmed reservation completes instead of cancelling');
select is((select availability_status::text from public.vehicles where id=md5('resolve-vehicle-2')::uuid),'sold','reserved confirmation sells atomically');
select * from pg_temp.resolution_call(3,pg_temp.reserve_command(3,3),'00000','reserve later rejected sale');
select * from pg_temp.resolution_call(3,pg_temp.report_command(3,3),'00000','report later rejected sale');
select * from pg_temp.resolution_call(1,pg_temp.resolution_command(3,false),'00000','Owner rejects reserved sale');
select is((select status::text from public.inquiries where id=md5('resolve-inquiry-3')::uuid),'closed_without_sale','rejection closes only reporting inquiry');
select is((select availability_status::text from public.vehicles where id=md5('resolve-vehicle-3')::uuid),'available','rejection restores reservation availability');
select ok((select status='cancelled' and cancelled_by=md5('resolve-actor-1')::uuid and completed_by is null
  from public.reservations where inquiry_id=md5('resolve-inquiry-3')::uuid),'rejection retains cancellation actor');
select is((select count(*) from public.inquiry_status_history where inquiry_id=md5('resolve-inquiry-3')::uuid),2::bigint,'rejection preserves both transitions');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(3,false),'00000','rejection retry is idempotent');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(3,true),'22023','cannot confirm rejected task');
select * from pg_temp.resolution_call(3,pg_temp.report_command(4,4),'00000','report before competing reservation');
select * from pg_temp.resolution_call(3,pg_temp.reserve_command(5,4),'00000','other inquiry reserves reported vehicle');
select * from pg_temp.resolution_call(1,pg_temp.resolution_command(4,true),'22023','competing reservation blocks confirmation');
select is((select status from public.sale_reviews where inquiry_id=md5('resolve-inquiry-4')::uuid),'pending','blocked confirmation leaves review pending');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(4,false),'00000','reject report without displacing competing reservation');
select is((select status::text from public.reservations where inquiry_id=md5('resolve-inquiry-5')::uuid),'active','rejection preserves other inquiry reservation');
select is((select status::text from public.inquiries where id=md5('resolve-inquiry-5')::uuid),'new','other inquiry remains active');
select * from pg_temp.resolution_call(3,pg_temp.report_command(6,6),'00000','report enabled inventory');
select * from pg_temp.resolution_call(1,format('select public.set_vehicle_sale_blocked(%L,true)',md5('resolve-vehicle-6')),'00000','block after report');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(6,true),'22023','confirmation rechecks current blocking');
select * from pg_temp.resolution_call(1,format('select public.set_vehicle_sale_blocked(%L,false)',md5('resolve-vehicle-6')),'00000','explicitly unblock');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(6,true),'00000','confirmation after unblock succeeds');
select * from pg_temp.resolution_call(3,pg_temp.report_command(7,7),'00000','pending review protects reopen');
select * from pg_temp.resolution_call(1,format('update public.inquiries set status=''following_up'' where id=%L',md5('resolve-inquiry-7')),
  '22023','trusted service cannot reopen pending review','service_role');
select * from pg_temp.resolution_call(2,pg_temp.resolution_command(7,false),'00000','Admin rejects unreserved report');
select is((select availability_status::text from public.vehicles where id=md5('resolve-vehicle-7')::uuid),'available','unreserved rejection leaves inventory unchanged');
select pg_temp.resolution_call(a,format('update public.vehicles set availability_status=''sold'' where id=%L',md5('resolve-vehicle-8')),
  '22023','direct Sold update forbidden '||a) from generate_series(1,2)a;
select * from pg_temp.resolution_call(1,format('update public.vehicles set availability_status=''sold'' where id=%L',md5('resolve-vehicle-8')),
  '42501','service direct Sold update forbidden','service_role');
select pg_temp.resolution_call(a,'insert into public.vehicles(brand,model,year,availability_status) values(''Test'',''Direct Sold'',2024,''sold'')',
  '22023','direct Sold insert forbidden '||a) from generate_series(1,2)a;
select * from pg_temp.resolution_call(1,'update public.confirmed_sales set confirmed_at=now()','42501','confirmed history immutable');
select set_config('request.jwt.claim.sub',md5('resolve-actor-4')::uuid::text,true);
set local role authenticated;
select is((select count(*) from public.confirmed_sales),1::bigint,'seller sees only own inquiry confirmed sales');
reset role;
select set_config('request.jwt.claim.sub',md5('resolve-actor-1')::uuid::text,true);
set local role authenticated;
select is((select count(*) from public.confirmed_sales),3::bigint,'Owner sees global confirmed sales');
reset role;
select * from finish();
rollback;
