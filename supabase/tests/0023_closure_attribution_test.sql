begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_table('public','inquiry_closure_attribution','private closure snapshots exist');

insert into auth.users(id,email)
select md5('closure-actor-'||n)::uuid,'closure-'||n||'@example.invalid' from generate_series(1,3)n;
insert into public.profiles(id,role,display_name)
select md5('closure-actor-'||n)::uuid,
 (case when n=1 then 'owner' else 'seller' end)::public.user_role,'Closure actor '||n
from generate_series(1,3)n;
insert into public.vehicles(id,brand,model,year,publication_status)
values(md5('closure-vehicle')::uuid,'Test','Closure',2024,'published');
insert into public.contacts(id,normalized_phone,display_name)
values(md5('closure-contact')::uuid,'+5491182345678','Closure contact');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_phone,submitted_name)
values(md5('closure-inquiry')::uuid,md5('closure-submit')::uuid,md5('closure-contact')::uuid,
 md5('closure-vehicle')::uuid,md5('closure-actor-2')::uuid,'+5491182345678','Submitted');
insert into public.inquiry_interests(inquiry_id,vehicle_id)
values(md5('closure-inquiry')::uuid,md5('closure-vehicle')::uuid);

set local role authenticated;
select set_config('request.jwt.claim.sub',md5('closure-actor-2')::uuid::text,true);
select public.report_inquiry_sale(md5('closure-inquiry')::uuid,md5('closure-vehicle')::uuid);
select set_config('request.jwt.claim.sub',md5('closure-actor-1')::uuid::text,true);
select public.resolve_sale_review((select id from public.sale_reviews where inquiry_id=md5('closure-inquiry')::uuid),false);
reset role;
select is((select count(*) from public.inquiry_closure_attribution),1::bigint,'one closure snapshot');
select is((select responsible_id from public.inquiry_closure_attribution),md5('closure-actor-2')::uuid,
 'outcome belongs to responsible seller, not administrator');
select is((select actor_id from public.inquiry_status_history where to_status='closed_without_sale'),
 md5('closure-actor-1')::uuid,'performer remains unchanged');

set local role authenticated;
select public.resolve_sale_review((select id from public.sale_reviews where inquiry_id=md5('closure-inquiry')::uuid),false);
select public.reopen_inquiry(md5('closure-inquiry')::uuid);
reset role;
select is((select count(*) from public.inquiry_closure_attribution),1::bigint,'retry and reopening preserve one recorded outcome');
update public.inquiries set assignee_id=md5('closure-actor-3')::uuid where id=md5('closure-inquiry')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('closure-actor-3')::uuid::text,true);
select public.report_inquiry_sale(md5('closure-inquiry')::uuid,md5('closure-vehicle')::uuid);
select set_config('request.jwt.claim.sub',md5('closure-actor-1')::uuid::text,true);
select public.resolve_sale_review((select id from public.sale_reviews where inquiry_id=md5('closure-inquiry')::uuid and status='pending'),false);
reset role;
select is((select count(*) from public.inquiry_closure_attribution),2::bigint,'repeated closure is a separate event');
select is((select count(*) from public.inquiries where id=md5('closure-inquiry')::uuid),1::bigint,'inquiry remains counted once');
select is((select count(distinct responsible_id) from public.inquiry_closure_attribution),2::bigint,
 'each event retains its own historical responsibility');
update public.profiles set is_active=false where id=md5('closure-actor-2')::uuid;
select ok(exists(select 1 from public.inquiry_closure_attribution where responsible_id=md5('closure-actor-2')::uuid),
 'deactivation preserves attribution');

-- Owner-only fixtures model a known unassigned event; no API bypass is granted.
set local role authenticated;
select public.reopen_inquiry(md5('closure-inquiry')::uuid);
reset role;
update public.inquiries set assignee_id=null where id=md5('closure-inquiry')::uuid;
insert into public.inquiry_status_history(inquiry_id,from_status,to_status,actor_id)
values(md5('closure-inquiry')::uuid,'following_up','closed_without_sale',md5('closure-actor-1')::uuid);
select is((select count(*) from public.inquiry_closure_attribution where responsible_id is null),1::bigint,
 'known unassigned snapshot is present, distinct from absent historical snapshot');
select is((select count(*) from public.inquiry_closure_attribution a join public.inquiry_status_history h on h.id=a.history_id
 where h.to_status<>'closed_without_sale'),0::bigint,'other status events create no closure snapshot');
select ok(not has_table_privilege(r,'public.inquiry_closure_attribution',p),r||' cannot '||p||' snapshots')
from (values('anon'),('authenticated'),('service_role')) roles(r)
cross join (values('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE')) privileges(p);
select ok(relrowsecurity,'RLS enabled') from pg_class where oid='public.inquiry_closure_attribution'::regclass;
select * from finish();
rollback;
