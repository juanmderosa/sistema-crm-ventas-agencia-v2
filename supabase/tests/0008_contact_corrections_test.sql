begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users (id, email)
select ('88000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
       'contact-test-' || n || '@example.invalid' from generate_series(1,6) n;
insert into public.profiles (id, role, display_name, is_active)
select ('88000000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
       (case n when 1 then 'owner' when 2 then 'admin' else 'seller' end)::public.user_role,
       'Contact staff ' || n, n <> 5 from generate_series(1,5) n;
insert into public.vehicles (id,brand,model,year,publication_status)
values ('88100000-0000-4000-8000-000000000001','Test','Contact',2020,'published');
insert into public.contacts (id,normalized_phone,display_name,email)
values ('88200000-0000-4000-8000-000000000001','+5491100000001','Original','original@example.invalid'),
       ('88200000-0000-4000-8000-000000000002','+5491100000002','Unrelated','unrelated@example.invalid');
insert into public.inquiries (id,submission_id,contact_id,originating_vehicle_id,assignee_id,status,submitted_name,submitted_email,submitted_phone)
select ('88300000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
       ('88400000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
       '88200000-0000-4000-8000-000000000001','88100000-0000-4000-8000-000000000001',
       ('88000000-0000-4000-8000-' || lpad((n+2)::text,12,'0'))::uuid,
       'closed_without_sale','Submitted','submitted@example.invalid','+5491100000001'
from generate_series(1,2) n;
insert into public.inquiry_assignment_history (inquiry_id,assignee_id,reason)
select id,assignee_id,'rotation' from public.inquiries where id::text like '88300000%';
create temporary table preserved as
select 'inquiries' kind, md5(jsonb_agg(to_jsonb(i) order by id)::text) digest from public.inquiries i
union all select 'history',md5(jsonb_agg(to_jsonb(h) order by id)::text) from public.inquiry_assignment_history h;

set local role authenticated;
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000003',true);
select is(public.update_contact_details('88200000-0000-4000-8000-000000000001',0,'Corrected','corrected@example.invalid'),1::bigint,'seller edits contact linked to own closed inquiry');
select is((select display_name from public.contacts where id='88200000-0000-4000-8000-000000000001'),'Corrected','details persisted');
select is((select count(*) from public.inquiries where contact_id='88200000-0000-4000-8000-000000000001'),1::bigint,'shared contact does not reveal coworker inquiry');
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000002',0,'Denied','d@example.invalid')$$,'42501','contact edit not permitted','unrelated contact denied');
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000099',0,'Denied','d@example.invalid')$$,'42501','contact edit not permitted','missing contact has same authorization error');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',1,'+5491100000001')$$,'42501','contact phone edit not permitted','seller cannot even submit same phone');
select throws_ok($$update public.contacts set display_name='Bypass'$$,'42501',null,'no generic update permission');
reset role;

-- Every rejected operation must preserve complete rows, including timestamps/revisions.
create temporary table before_rejection as select md5(jsonb_agg(to_jsonb(c) order by id)::text) digest from public.contacts c;
set local role authenticated;
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',0,'Stale','s@example.invalid')$$,'40001','contact changed; reload the contact and retry','stale details explicitly request reload');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',0,'+5491100000099')$$,'40001','contact changed; reload the contact and retry','details revision invalidates phone edit');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',1,'+5491100000002')$$,'23505','phone already belongs to another contact; no contacts were merged','collision rejected explicitly');
select throws_ok(format('select public.update_contact_details(%L,%s,%L,%L)','88200000-0000-4000-8000-000000000001',v,n,e),'22023','invalid contact details input',label)
from (values ('null','Name','e@example.invalid','missing version'),('-1','Name','e@example.invalid','negative version'),('1',null,'e@example.invalid','null name'),('1',' ','e@example.invalid','blank name'),('1','Name',null,'null email'),('1','Name',' ','blank email')) t(v,n,e,label);
select throws_ok(format('select public.update_contact_phone(%L,1,%L)','88200000-0000-4000-8000-000000000001',p),'22023','invalid contact phone input','reject noncanonical phone')
from (values (null::text),(''),('54911'),('+0123'),('+1'),('+1234567890123456'),('+54 911')) t(p);
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',null,'+5491100000099')$$,'22023','invalid contact phone input','phone version required');
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001','Name','e@example.invalid')$$,'42883',null,'details has no omitted-version overload');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001','+5491100000099')$$,'42883',null,'phone has no omitted-version overload');
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000005',true);
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',1,'Denied','d@example.invalid')$$,'42501','contact edit not permitted','inactive staff denied');
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000006',true);
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',1,'Denied','d@example.invalid')$$,'42501','contact edit not permitted','no profile denied');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',1,'+5491100000099')$$,'42501','contact phone edit not permitted','no-profile phone denied');
select set_config('request.jwt.claim.sub','',true);
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',1,'Denied','d@example.invalid')$$,'42501','contact edit not permitted','missing identity denied');
reset role;
set local role anon;
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',1,'Denied','d@example.invalid')$$,'42501',null,'anonymous details execution denied');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',1,'+5491100000099')$$,'42501',null,'anonymous phone execution denied');
reset role;
select is((select md5(jsonb_agg(to_jsonb(c) order by id)::text) from public.contacts c),(select digest from before_rejection),'all rejected operations preserve full contact rows');

-- Active administrative roles are not sufficient after deactivation.
update public.profiles set is_active=false where id='88000000-0000-4000-8000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',1,'Denied','d@example.invalid')$$,'42501','contact edit not permitted','inactive Admin details denied');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000001',1,'+5491100000099')$$,'42501','contact phone edit not permitted','inactive Admin phone denied');
reset role;
update public.profiles set is_active=true where id='88000000-0000-4000-8000-000000000002';
select is((select md5(jsonb_agg(to_jsonb(c) order by id)::text) from public.contacts c),(select digest from before_rejection),'inactive Admin rejection preserves complete rows');

set local role authenticated;
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000001',true);
select is(public.update_contact_phone('88200000-0000-4000-8000-000000000001',1,'+5491100000099'),2::bigint,'Owner phone increments once');
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000001',1,'Stale','s@example.invalid')$$,'40001','contact changed; reload the contact and retry','phone revision invalidates details');
select is(public.update_contact_details('88200000-0000-4000-8000-000000000002',0,'Owner edit','owner@example.invalid'),1::bigint,'Owner details without linked inquiry');
select set_config('request.jwt.claim.sub','88000000-0000-4000-8000-000000000002',true);
select is(public.update_contact_phone('88200000-0000-4000-8000-000000000002',1,'+5491100000088'),2::bigint,'Admin phone parity');
select is(public.update_contact_details('88200000-0000-4000-8000-000000000002',2,'Admin edit','admin@example.invalid'),3::bigint,'Admin details parity');
select throws_ok($$select public.update_contact_phone('88200000-0000-4000-8000-000000000002',1,'+5491100000077')$$,'40001','contact changed; reload the contact and retry','stale phone rejected');
reset role;
update public.contacts set display_name=display_name,revision=0 where id='88200000-0000-4000-8000-000000000002';
select is((select revision from public.contacts where id='88200000-0000-4000-8000-000000000002'),4::bigint,'trusted update cannot reset revision; increments exactly once');
set local role authenticated;
select throws_ok($$select public.update_contact_details('88200000-0000-4000-8000-000000000002',3,'Stale','s@example.invalid')$$,'40001','contact changed; reload the contact and retry','trusted update invalidates prior revision');
reset role;
select is((select md5(jsonb_agg(to_jsonb(i) order by id)::text) from public.inquiries i),(select digest from preserved where kind='inquiries'),'snapshots and all inquiry fields unchanged');
select is((select md5(jsonb_agg(to_jsonb(h) order by id)::text) from public.inquiry_assignment_history h),(select digest from preserved where kind='history'),'routing history unchanged');

-- Existing submission semantics still preserve corrected contact identity.
set local role service_role;
select is(public.submit_inquiry('88500000-0000-4000-8000-000000000001','88100000-0000-4000-8000-000000000001','+5491100000099','New submission','new@example.invalid'),'{"accepted":true}'::jsonb,'existing submit operation accepts corrected phone');
select is(public.submit_inquiry('88500000-0000-4000-8000-000000000001','88100000-0000-4000-8000-000000000001','+5491100000099','New submission','new@example.invalid'),'{"accepted":true}'::jsonb,'submission retry remains idempotent');
reset role;
select is((select revision from public.contacts where id='88200000-0000-4000-8000-000000000001'),2::bigint,'submission/retry do not overwrite corrected contact or revision');
select is((select normalized_phone from public.contacts where id='88200000-0000-4000-8000-000000000001'),'+5491100000099','phone correction persisted');
select is((select display_name from public.contacts where id='88200000-0000-4000-8000-000000000001'),'Corrected','submission preserves corrected name');
select is((select count(*) from public.inquiries where submission_id='88500000-0000-4000-8000-000000000001'),1::bigint,'submission retry creates one inquiry');
select * from finish();
rollback;
