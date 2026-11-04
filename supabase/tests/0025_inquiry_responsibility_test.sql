begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_table('public','inquiry_responsibility_tracking','responsibility coverage exists');
select has_table('public','inquiry_first_responsibilities','first observed responsibilities exist');

insert into auth.users(id,email)
select md5('responsibility-actor-'||n)::uuid,'responsibility-'||n||'@example.invalid' from generate_series(1,3)n;
insert into public.profiles(id,role,display_name)
select md5('responsibility-actor-'||n)::uuid,(case when n=1 then 'owner' else 'seller' end)::public.user_role,
 'Responsibility actor '||n from generate_series(1,3)n;
insert into public.vehicles(id,brand,model,year,publication_status)
values(md5('responsibility-vehicle')::uuid,'Test','Responsibility',2024,'published');
set local role authenticated;
select set_config('request.jwt.claim.sub',md5('responsibility-actor-2')::uuid::text,true);
select set_config('test.manual_inquiry',public.create_manual_inquiry(
 '+5491184567890','Test',null,null,'in_person')->>'inquiry_id',true);
reset role;
select ok((select complete_from_creation from public.inquiry_responsibility_tracking
 where inquiry_id=current_setting('test.manual_inquiry')::uuid),'new inquiry coverage starts at creation');
select is((select responsible_id from public.inquiry_first_responsibilities
 where inquiry_id=current_setting('test.manual_inquiry')::uuid),md5('responsibility-actor-2')::uuid,
 'manual creation preserves registering responsibility');
select ok((select first_observed_at<=clock_timestamp() from public.inquiry_first_responsibilities
 where inquiry_id=current_setting('test.manual_inquiry')::uuid),'capture supplies server time');

create temp table responsibility_before as select * from public.inquiry_first_responsibilities;
set local role service_role;
update public.inquiries set assignee_id=md5('responsibility-actor-3')::uuid
 where id=current_setting('test.manual_inquiry')::uuid;
update public.inquiries set assignee_id=md5('responsibility-actor-2')::uuid
 where id=current_setting('test.manual_inquiry')::uuid;
reset role;
select is((select count(*) from public.inquiry_first_responsibilities
 where inquiry_id=current_setting('test.manual_inquiry')::uuid),2::bigint,'A to B to A records two distinct responsible people');
select results_eq($$select * from public.inquiry_first_responsibilities where responsible_id=md5('responsibility-actor-2')::uuid$$,
 $$select * from responsibility_before$$,'return assignment preserves first observed time');

-- Explicit no-op assignment and unrelated updates must not manufacture events.
truncate responsibility_before;
insert into responsibility_before select * from public.inquiry_first_responsibilities;
set local role service_role;
update public.inquiries set assignee_id=assignee_id where id=current_setting('test.manual_inquiry')::uuid;
update public.inquiries set status='following_up' where id=current_setting('test.manual_inquiry')::uuid;
update public.inquiries set assignee_id=null where id=current_setting('test.manual_inquiry')::uuid;
update public.inquiries set assignee_id=md5('responsibility-actor-2')::uuid where id=current_setting('test.manual_inquiry')::uuid;
reset role;
select results_eq($$select * from public.inquiry_first_responsibilities order by responsible_id$$,
 $$select * from responsibility_before order by responsible_id$$,'no-op, status-only and null/return changes never reset counts');
update public.profiles set is_active=false where id=md5('responsibility-actor-3')::uuid;
select is((select count(*) from public.inquiry_first_responsibilities),2::bigint,'deactivation preserves historical observations');

-- Web creation and idempotency keep the existing privacy-safe response shape.
set local role service_role;
select public.submit_inquiry(md5('responsibility-web-submit')::uuid,md5('responsibility-vehicle')::uuid,
 '+5491184567891','Web','web@example.invalid');
select public.submit_inquiry(md5('responsibility-web-submit')::uuid,md5('responsibility-vehicle')::uuid,
 '+5491184567891','Web','web@example.invalid');
reset role;
select is((select count(*) from public.inquiries where submission_id=md5('responsibility-web-submit')::uuid),1::bigint,
 'web retry keeps one inquiry');
select is((select count(*) from public.inquiry_first_responsibilities r join public.inquiries i on i.id=r.inquiry_id
 where i.submission_id=md5('responsibility-web-submit')::uuid),1::bigint,'web retry keeps one first responsibility');
select ok((select complete_from_creation from public.inquiry_responsibility_tracking t join public.inquiries i on i.id=t.inquiry_id
 where i.submission_id=md5('responsibility-web-submit')::uuid),'web inquiry has complete coverage');

-- Initially unassigned fixtures start covered but without a responsible count.
insert into public.inquiries(id,submission_id,contact_id,origin,assignee_id,submitted_phone,submitted_name)
select md5('responsibility-unassigned')::uuid,md5('responsibility-unassigned-submit')::uuid,contact_id,
 'phone',null,'+5491184567890','Test' from public.inquiries where id=current_setting('test.manual_inquiry')::uuid;
select ok((select complete_from_creation from public.inquiry_responsibility_tracking
 where inquiry_id=md5('responsibility-unassigned')::uuid),'initially unassigned inquiry still covered');
select is((select count(*) from public.inquiry_first_responsibilities where inquiry_id=md5('responsibility-unassigned')::uuid),
 0::bigint,'unassigned is not a staff person');
set local role service_role;
update public.inquiries set assignee_id=md5('responsibility-actor-2')::uuid where id=md5('responsibility-unassigned')::uuid;
reset role;
select is((select count(*) from public.inquiry_first_responsibilities where inquiry_id=md5('responsibility-unassigned')::uuid),
 1::bigint,'first later assignment captured');

select ok(not has_table_privilege(r,t,p),r||' cannot '||p||' '||t)
from (values('anon'),('authenticated'),('service_role')) roles(r)
cross join (values('public.inquiry_responsibility_tracking'),('public.inquiry_first_responsibilities')) tables(t)
cross join (values('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE')) privileges(p);
select ok(relrowsecurity,relname||' has RLS') from pg_class where oid in
 ('public.inquiry_responsibility_tracking'::regclass,'public.inquiry_first_responsibilities'::regclass);
select * from finish();
rollback;
