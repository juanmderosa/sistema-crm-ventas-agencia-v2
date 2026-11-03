begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id,email) select md5('finish.actor.'||n)::uuid,'finish'||n||'@example.invalid' from generate_series(1,8)n;
insert into profiles(id,role,display_name,is_active) select md5('finish.actor.'||n)::uuid,(case n when 1 then 'owner' when 2 then 'admin' when 4 then 'owner' when 5 then 'admin' else 'seller' end)::user_role,'Actor '||n,n not in(4,5,6) from generate_series(1,8)n where n<>7;
insert into vehicles(id,brand,model,year,publication_status) select md5('finish.car.'||n)::uuid,'Independent','Car '||n,2024,'published' from generate_series(1,3)n;
insert into vehicle_inquiry_rotation values(md5('finish.car.1')::uuid,md5('finish.actor.8')::uuid);
create function pg_temp.snap() returns text language sql as $$
select md5(jsonb_build_array(
(select jsonb_agg(to_jsonb(t) order by id) from profiles t),
(select jsonb_agg(to_jsonb(t) order by id) from vehicles t),
(select jsonb_agg(to_jsonb(t) order by id) from contacts t),
(select jsonb_agg(to_jsonb(t) order by id) from inquiries t),
(select jsonb_agg(to_jsonb(t) order by inquiry_id,vehicle_id) from inquiry_interests t),
(select jsonb_agg(to_jsonb(t) order by id) from inquiry_assignment_history t),
(select jsonb_agg(to_jsonb(t) order by vehicle_id) from vehicle_inquiry_rotation t),
(select jsonb_agg(to_jsonb(t) order by id) from reservations t),
(select jsonb_build_array(last_value,is_called) from inquiries_creation_sequence_seq))::text)
$$;
create function pg_temp.call_as(actor integer,api_role text,q text) returns jsonb language plpgsql as $$
declare response jsonb;st text:='00000';msg text:='';
begin
perform set_config('request.jwt.claim.sub',case when api_role='anon' then '' else md5('finish.actor.'||actor)::uuid::text end,true);
perform set_config('role',api_role,true);
begin execute q into response;
exception when others then get stacked diagnostics st=returned_sqlstate,msg=message_text;
end;
perform set_config('role','none',true);
return jsonb_build_object('state',st,'message',msg,'result',response);
end$$;
create function pg_temp.reject(actor integer,api_role text,q text,st text,msg text,label text) returns setof text language plpgsql as $$
declare before_hash text:=pg_temp.snap();r jsonb;
begin
r:=pg_temp.call_as(actor,api_role,q);
return next is(r->>'state',st,label||' SQLSTATE');
return next is(r->>'message',msg,label||' exact message');
return next is(pg_temp.snap(),before_hash,label||' complete unchanged hash');
end$$;
create temp table made(actor integer,origin text,id uuid);
-- S17/S18: every active role, both origins, and a nontrivial existing rotation cursor.
insert into made select actor,origin,(pg_temp.call_as(actor,'authenticated',format('select create_manual_inquiry(%L,%L,null,%L::uuid,%L::inquiry_origin)','+54110001000'||actor||case origin when 'phone' then '1' else '2' end,'Person '||actor,md5('finish.car.1')::uuid,origin))->'result'->>'inquiry_id')::uuid from unnest(array[1,2,3])actor cross join unnest(array['phone','in_person'])origin;
select is(count(*)::integer,6,'S17 all active role/origin combinations created') from made where id is not null;
select ok(bool_and(i.assignee_id=md5('finish.actor.'||m.actor)::uuid and i.origin::text=m.origin and i.submitted_email is null),'S17/S18 origins, optional email and self assignment') from made m join inquiries i on i.id=m.id;
select is((select last_assignee_id from vehicle_inquiry_rotation where vehicle_id=md5('finish.car.1')::uuid),md5('finish.actor.8')::uuid,'S18 manual creation never advances rotation');
select r.* from unnest(array[4,5,6,7])n cross join lateral pg_temp.reject(n,'authenticated',$q$select create_manual_inquiry('+541100020001','Denied',null,null,'phone')$q$,'42501','manual inquiry access denied','S17 inactive/no-profile actor '||n) r;
select * from pg_temp.reject(7,'anon',$q$select create_manual_inquiry('+541100020001','Denied',null,null,'phone')$q$,'42501','permission denied for function create_manual_inquiry','S17 anonymous');
-- S19 name/phone boundaries: no inferred email syntax requirement.
select r.* from unnest(array[null,'',' ','114567890','+0123','+1234567890123456'])phone cross join lateral pg_temp.reject(3,'authenticated',format('select create_manual_inquiry(%L,''Name'',null,null,''phone'')',phone),'22023','invalid manual inquiry input','S19 invalid phone '||coalesce(phone,'NULL')) r;
select r.* from unnest(array[null,'','  '])name cross join lateral pg_temp.reject(3,'authenticated',format('select create_manual_inquiry(''+541100030001'',%L,null,null,''phone'')',name),'22023','invalid manual inquiry input','S19 invalid name '||coalesce(name,'NULL')) r;
select * from pg_temp.reject(3,'authenticated',$q$select create_manual_inquiry('+541100030001','Name',' ',null,'phone')$q$,'22023','invalid manual inquiry input','S19 blank optional email');
select is(pg_temp.call_as(3,'authenticated',$q$select create_manual_inquiry('+12','Shortest',null,null,'phone')$q$)->>'state','00000','S19 shortest normalized phone accepted');
select is(pg_temp.call_as(3,'authenticated',$q$select create_manual_inquiry('+123456789012345','Longest','typed email',null,'phone')$q$)->>'state','00000','S19 fifteen digits and optional nonblank email accepted');
-- Shared contact across two seller inquiries must not disclose the first inquiry/history.
insert into contacts(id,normalized_phone,display_name,email) values(md5('finish.shared')::uuid,'+541100040001','Stored','stored@example.invalid');
insert into made select 8,'phone',(pg_temp.call_as(8,'authenticated',$q$select create_manual_inquiry('+541100040001','Coworker',null,null,'phone')$q$)->'result'->>'inquiry_id')::uuid;
insert into made select 3,'phone',(pg_temp.call_as(3,'authenticated',$q$select create_manual_inquiry('+541100040001','Typed','different@example.invalid',null,'phone')$q$)->'result'->>'inquiry_id')::uuid;
select is((select count(*)::integer from inquiries where contact_id=md5('finish.shared')::uuid),2,'S19 recognized contact reused');
select is((select display_name||'|'||email||'|'||revision from contacts where id=md5('finish.shared')::uuid),'Stored|stored@example.invalid|0','S19 reuse does not overwrite contact');
select ok(exists(select 1 from inquiries where submitted_phone='+541100040001' and submitted_name='Typed' and submitted_email='different@example.invalid'),'S19 discrepant snapshot retained');
select is(pg_temp.call_as(3,'authenticated',$q$select jsonb_build_array((select count(*) from inquiries where contact_id=md5('finish.shared')::uuid),(select count(*) from inquiry_assignment_history where inquiry_id in(select id from inquiries where contact_id=md5('finish.shared')::uuid)))$q$)->'result','[1, 0]'::jsonb,'S19 seller sees only own shared-contact inquiry and no assignment history');
-- S9 distinct collision dimensions and exact rejected-operation snapshots.
select is(pg_temp.call_as(3,'authenticated',format('select reserve_inquiry_vehicle(%L::uuid,%L::uuid)',(select id from made where actor=3 and origin='in_person'),md5('finish.car.1')::uuid))->>'state','00000','S9 first reservation succeeds');
select * from pg_temp.reject(2,'authenticated',format('select reserve_inquiry_vehicle(%L::uuid,%L::uuid)',(select id from made where actor=2 and origin='in_person'),md5('finish.car.1')::uuid),'22023','vehicle must be Available and enabled for sale','S9 same vehicle distinct inquiry');
insert into inquiry_interests select id,md5('finish.car.2')::uuid from made where actor=3 and origin='in_person';
select * from pg_temp.reject(3,'authenticated',format('select reserve_inquiry_vehicle(%L::uuid,%L::uuid)',(select id from made where actor=3 and origin='in_person'),md5('finish.car.2')::uuid),'23505','an active reservation already exists','S9 same inquiry distinct vehicle');
select is((select count(*)::integer from reservations where status='active'),1,'S9 exactly one active row after both collisions');
select is((select availability_status::text from vehicles where id=md5('finish.car.2')::uuid),'available','S9 rejected target remains Available');
select ok(not exists(select 1 from reservations where status='active' group by inquiry_id having count(*)>1) and not exists(select 1 from reservations where status='active' group by vehicle_id having count(*)>1),'S9 both uniqueness dimensions preserved');
-- S20 both permitted roles can block AND enable, no implicit publication/availability mutation.
create function pg_temp.permitted_block(actor integer,blocked boolean) returns setof text language plpgsql as $$
declare r jsonb;
begin
r:=pg_temp.call_as(actor,'authenticated',format('select set_vehicle_sale_blocked(%L::uuid,%L::boolean)',md5('finish.car.3')::uuid,blocked));
return next is(r->>'state','00000','S20 permitted role '||actor||' blocked='||blocked);
return next is((select sale_enabled from vehicles where id=md5('finish.car.3')::uuid),not blocked,'S20 persisted requested flag');
return next is((select availability_status::text from vehicles where id=md5('finish.car.3')::uuid),'available','S20 unchanged availability');
return next is((select publication_status::text from vehicles where id=md5('finish.car.3')::uuid),'published','S20 unchanged publication');
end$$;
select r.* from unnest(array[1,2])actor cross join unnest(array[true,false])blocked cross join lateral pg_temp.permitted_block(actor,blocked)r;
select ok((select publication_status='published' and availability_status='available' from vehicles where id=md5('finish.car.3')::uuid),'S20 publication and availability unchanged');
select r.* from unnest(array[3,4,5,6,7])actor cross join unnest(array[true,false])blocked cross join lateral pg_temp.reject(actor,'authenticated',format('select set_vehicle_sale_blocked(%L::uuid,%L::boolean)',md5('finish.car.3')::uuid,blocked),'42501','vehicle sale access denied','S20 denied actor '||actor||' blocked='||blocked) r;
select r.* from unnest(array[true,false])blocked cross join lateral pg_temp.reject(7,'anon',format('select set_vehicle_sale_blocked(%L::uuid,%L::boolean)',md5('finish.car.3')::uuid,blocked),'42501','permission denied for function set_vehicle_sale_blocked','S20 denied anon blocked='||blocked) r;
select * from finish();
rollback;
