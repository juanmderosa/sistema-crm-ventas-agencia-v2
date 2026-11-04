begin;
set search_path=public,extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','reopen_inquiry',array['uuid']);
insert into auth.users(id,email)
select md5('reopen-actor-'||n)::uuid,'reopen-'||n||'@example.invalid' from generate_series(1,8)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('reopen-actor-'||n)::uuid,
  (case n when 1 then 'owner' when 2 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
  'Reopening actor '||n,n not in(5,6,7) from generate_series(1,7)n;
insert into public.vehicles(id,brand,model,year,publication_status)
select md5('reopen-vehicle-'||n)::uuid,'Reopen','Vehicle '||n,2024,'published' from generate_series(1,9)n;
insert into public.contacts(id,normalized_phone,display_name)
values(md5('reopen-contact')::uuid,'+5491187871234','Reopening contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name)
select md5('reopen-inquiry-'||n)::uuid,md5('reopen-submission-'||n)::uuid,md5('reopen-contact')::uuid,
  md5('reopen-vehicle-'||n)::uuid,md5('reopen-actor-'||case when n=2 then 4 else 3 end)::uuid,
  '+5491187871234','Reopening' from generate_series(1,9)n;
insert into public.inquiry_interests(inquiry_id,vehicle_id)
select id,originating_vehicle_id from public.inquiries where submitted_name='Reopening';
update public.inquiries set status='closed_without_sale' where id in(
  select md5('reopen-inquiry-'||n)::uuid from unnest(array[1,2,3,8])n);
select set_config('request.jwt.claim.sub',md5('reopen-actor-3')::uuid::text,true);
set local role authenticated;
select public.report_inquiry_sale(md5('reopen-inquiry-'||n)::uuid,md5('reopen-vehicle-'||n)::uuid)
from generate_series(4,7)n;
reset role;
select set_config('request.jwt.claim.sub',md5('reopen-actor-1')::uuid::text,true);
set local role authenticated;
select public.resolve_sale_review(id,true) from public.sale_reviews
where inquiry_id in(md5('reopen-inquiry-4')::uuid,md5('reopen-inquiry-5')::uuid);
select public.resolve_sale_review(id,false) from public.sale_reviews where inquiry_id=md5('reopen-inquiry-7')::uuid;
reset role;

create function pg_temp.reopen_unchanged(i uuid default null) returns text language sql as $$
select md5(jsonb_build_array(
  (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.profiles t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.sale_reviews t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.confirmed_sales t),
  (select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from public.inquiry_interests t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t where id is distinct from i),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_status_history t where inquiry_id is distinct from i)
)::text) $$;
create function pg_temp.reopen_call(a int,n int,expected text,label text,api_role text default 'authenticated')
returns setof text language plpgsql as $$
declare
  target uuid:=md5('reopen-inquiry-'||n)::uuid;
  allbefore text:=pg_temp.reopen_unchanged(); unrelated text:=pg_temp.reopen_unchanged(target);
  before_inquiry jsonb;before_history jsonb;result jsonb;c text:='00000';
begin
  select to_jsonb(t) into before_inquiry from public.inquiries t where id=target;
  select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]') into before_history
  from public.inquiry_status_history t where inquiry_id=target;
  perform set_config('request.jwt.claim.sub',md5('reopen-actor-'||a)::uuid::text,true);
  perform set_config('role',api_role,true);
  begin result:=public.reopen_inquiry(target);
  exception when others then get stacked diagnostics c=returned_sqlstate;end;
  perform set_config('role','none',true);
  return next is(c,expected,label||': SQLSTATE');
  if expected<>'00000' then
    return next is(pg_temp.reopen_unchanged(),allbefore,label||': rejected state unchanged');
  else
    return next is(result,jsonb_build_object('inquiry_id',target,'status','following_up'),label||': exact response');
    return next is(pg_temp.reopen_unchanged(target),unrelated,label||': unrelated state/inventory/ledger unchanged');
    return next is((select to_jsonb(t)-'status'-'updated_at' from public.inquiries t where id=target),
      before_inquiry-'status'-'updated_at',label||': immutable inquiry fields');
    return next is((select status::text from public.inquiries where id=target),'following_up',label||': active follow-up');
    return next is((select count(*) from public.inquiry_status_history where inquiry_id=target),
      jsonb_array_length(before_history)::bigint+1,label||': exactly one new history row');
    return next ok(not exists(select 1 from jsonb_array_elements(before_history)x where not exists(
      select 1 from public.inquiry_status_history t where to_jsonb(t)=x)),label||': prior history retained');
    return next is((select count(*) from public.inquiry_status_history where inquiry_id=target
      and from_status=(before_inquiry->>'status')::public.inquiry_status and to_status='following_up'
      and actor_id=md5('reopen-actor-'||a)::uuid and review_id is null),1::bigint,label||': reopening attribution');
  end if;
end $$;
select * from pg_temp.reopen_call(4,1,'42501','coworker cannot reopen');
select pg_temp.reopen_call(n,8,'42501','inactive or profile-less '||n) from generate_series(5,8)n;
select * from pg_temp.reopen_call(3,1,'42501','anonymous denied','anon');
select * from pg_temp.reopen_call(1,1,'42501','service cannot invoke staff reopening','service_role');
select * from pg_temp.reopen_call(3,999,'42501','missing inquiry denied');
select * from pg_temp.reopen_call(1,null,'42501','null inquiry denied');
select * from pg_temp.reopen_call(3,9,'22023','active inquiry rejected');
select * from pg_temp.reopen_call(3,4,'42501','seller cannot reopen confirmed sale');
select * from pg_temp.reopen_call(3,6,'42501','seller cannot reopen reported sale');
select * from pg_temp.reopen_call(1,6,'22023','Owner must resolve pending review first');
select * from pg_temp.reopen_call(2,6,'22023','Admin must resolve pending review first');
select * from pg_temp.reopen_call(3,1,'00000','seller reopens own closed inquiry');
select * from pg_temp.reopen_call(1,3,'00000','Owner reopens closed inquiry');
select * from pg_temp.reopen_call(2,2,'00000','Admin reopens other assignee closed inquiry');
select * from pg_temp.reopen_call(1,4,'00000','Owner reopens confirmed sale without reversal');
select * from pg_temp.reopen_call(2,5,'00000','Admin reopens confirmed sale without reversal');
select * from pg_temp.reopen_call(3,7,'00000','seller reopens rejected sale');
select * from pg_temp.reopen_call(3,1,'22023','reopening again cannot append duplicate history');
select is((select count(*) from public.confirmed_sales where inquiry_id in(
  md5('reopen-inquiry-4')::uuid,md5('reopen-inquiry-5')::uuid)),2::bigint,'both confirmed sales remain counted');
select is((select count(*) from public.vehicles where id in(md5('reopen-vehicle-4')::uuid,
  md5('reopen-vehicle-5')::uuid) and availability_status='sold'),2::bigint,'both confirmed vehicles remain Sold');
select set_config('request.jwt.claim.sub',md5('reopen-actor-3')::uuid::text,true);
set local role authenticated;
select is((select count(*) from public.inquiry_status_history where inquiry_id=md5('reopen-inquiry-2')::uuid),
  0::bigint,'reopening history does not expose coworker inquiry');
reset role;
select * from finish();
rollback;
