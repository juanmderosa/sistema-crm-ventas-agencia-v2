begin;
set search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();
-- Retained independent probes; the same calls were executed on the baseline.
-- This regression test uses only current schema, never git history.
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
create function pg_temp.common_state() returns text language sql as $$
select md5(jsonb_build_array(
  (select jsonb_agg(to_jsonb(t) order by id) from public.vehicles t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiries t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.reservations t),
  (select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from public.inquiry_interests t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.contacts t),
  (select jsonb_agg(to_jsonb(t) order by id) from public.inquiry_assignment_history t)
)::text) $$;
create function pg_temp.diff_call(actor int,command text,expected text,label text)
returns text language plpgsql as $$
declare b text:=pg_temp.common_state(); c text:='00000'; m text:=''; r jsonb; reservation uuid;
begin
  perform set_config('request.jwt.claim.sub',md5('bounded-actor-'||actor)::uuid::text,true);
  perform set_config('role','authenticated',true);
  begin execute command into r;
  exception when others then get stacked diagnostics c=returned_sqlstate,m=message_text; end;
  perform set_config('role','none',true);
  if c<>expected then raise exception '% expected % got %/%',label,expected,c,m; end if;
  if c<>'00000' and b<>pg_temp.common_state() then raise exception '% changed state',label; end if;
  if r ? 'reservation_id' then
    reservation:=(r->>'reservation_id')::uuid;
    if not exists(select 1 from public.reservations where id=reservation) then
      raise exception 'returned reservation absent';
    end if;
  end if;
  return ok(true,label);
end $$;
select pg_temp.diff_call(3,format('select public.add_inquiry_interest(%L,%L)',md5('bounded-inquiry-1'),md5('bounded-vehicle-10')),'00000','add interest');
select pg_temp.diff_call(3,format('select public.add_inquiry_interest(%L,%L)',md5('bounded-inquiry-1'),md5('bounded-vehicle-10')),'00000','duplicate interest');
select pg_temp.diff_call(4,format('select public.add_inquiry_interest(%L,%L)',md5('bounded-inquiry-1'),md5('bounded-vehicle-11')),'42501','coworker add denied');
select pg_temp.diff_call(3,format('select public.reserve_inquiry_vehicle(%L,%L)',md5('bounded-inquiry-1'),md5('bounded-vehicle-10')),'00000','reserve added draft interest');
select pg_temp.diff_call(4,format('select public.reserve_inquiry_vehicle(%L,%L)',md5('bounded-inquiry-2'),md5('bounded-vehicle-10')),'22023','competing reserve denied');
select pg_temp.diff_call(4,format('select public.cancel_reservation(%L)',(select id from public.reservations where inquiry_id=md5('bounded-inquiry-1')::uuid and status='active')),'42501','coworker cancel denied');
select pg_temp.diff_call(3,format('select public.cancel_reservation(%L)',(select id from public.reservations where inquiry_id=md5('bounded-inquiry-1')::uuid and status='active')),'00000','own cancel');
select pg_temp.diff_call(3,format('select public.cancel_reservation(%L)',(select id from public.reservations where inquiry_id=md5('bounded-inquiry-1')::uuid)),'22023','repeat cancel denied');
select pg_temp.diff_call(5,format('select public.add_inquiry_interest(%L,%L)',md5('bounded-inquiry-1'),md5('bounded-vehicle-11')),'42501','inactive add denied');
select is((select status::text from public.inquiries where id=md5('bounded-inquiry-1')::uuid),
  'new','existing operations preserve inquiry state');
select is((select count(*) from public.inquiry_interests where inquiry_id=md5('bounded-inquiry-1')::uuid),
  9::bigint,'duplicate addition keeps one interest');
select is((select availability_status::text from public.vehicles where id=md5('bounded-vehicle-10')::uuid),
  'available','cancellation restores availability');
select ok((select status='cancelled' and ended_at is not null and cancelled_by=md5('bounded-actor-3')::uuid
  from public.reservations where inquiry_id=md5('bounded-inquiry-1')::uuid),
  'cancellation retains actor and terminal history');
select * from finish();
rollback;
