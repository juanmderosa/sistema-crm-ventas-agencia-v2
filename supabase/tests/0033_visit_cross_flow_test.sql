begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
create function pg_temp.vc(n integer) returns uuid language sql immutable as
 $$select md5('visit-cross-flow-'||n)::uuid$$;
insert into auth.users(id,email) select pg_temp.vc(n),'vc-'||n||'@example.invalid' from generate_series(1,4)n;
insert into public.profiles(id,role,display_name,is_active) values
 (pg_temp.vc(1),'owner','Owner',true),(pg_temp.vc(2),'admin','Admin',true),
 (pg_temp.vc(3),'seller','Seller',true),(pg_temp.vc(4),'seller','Other',true);
insert into public.vehicles(id,brand,model,year,publication_status)
 select pg_temp.vc(100+n),'Test','Cross flow',2024,'published' from generate_series(1,13)n;
insert into public.contacts(id,normalized_phone,display_name) values(pg_temp.vc(10),'+5491177000033','Customer');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_phone)
 select pg_temp.vc(200+n),pg_temp.vc(300+n),pg_temp.vc(10),pg_temp.vc(101),
 case when n=7 then null else pg_temp.vc(3) end,'Customer','+5491177000033' from generate_series(1,17)n;
create temp table cases(n integer,v integer);
insert into cases values(1,2),(2,1),(3,1),(4,3),(5,3),(6,4),(7,5),(8,6),(9,7),
 (10,8),(11,9),(12,10),(13,11),(14,12),(15,13),(16,1),(17,1);
insert into public.inquiry_interests select pg_temp.vc(200+n),pg_temp.vc(100+v),now() from cases;
insert into public.inquiry_interests(inquiry_id,vehicle_id) values(pg_temp.vc(201),pg_temp.vc(101));
insert into public.visits(id,inquiry_id,vehicle_id,scheduled_at,status,purpose,request_assignee_id,
 first_outcome_recorded_at,outcome_assignee_id)
 select pg_temp.vc(400+n),pg_temp.vc(200+n),pg_temp.vc(100+v),now()+interval '2 days',
 (case when n in (3,5) then 'attended' when n=16 then 'cancelled' when n=17 then 'no_show'
 when n%2=0 then 'confirmed' else 'requested' end)::public.visit_status,
 'Preserve purpose',case when n=7 then null else pg_temp.vc(3) end,
 case when n in (3,5,10,16,17) then now()-interval '1 day' end,
 case when n in (3,5,16,17) then pg_temp.vc(4) end from cases;
insert into public.visit_creation_requests(submission_id,source,inquiry_id,visit_id,intent)
 values(pg_temp.vc(600),'staff',pg_temp.vc(201),pg_temp.vc(401),'{"original":true}');
create temp table final_before as select id,to_jsonb(v) as data from public.visits v where id in
 (pg_temp.vc(403),pg_temp.vc(405),pg_temp.vc(416),pg_temp.vc(417));
create function pg_temp.vc_call(actor integer,command text,expected text,label text)
 returns setof text language plpgsql as $$
declare observed text:='00000';
begin
 perform set_config('request.jwt.claim.sub',pg_temp.vc(actor)::text,true);
 perform set_config('role','authenticated',true);
 begin execute command; exception when others then get stacked diagnostics observed=returned_sqlstate; end;
 perform set_config('role','none',true);
 return next extensions.is(observed,expected,label||': SQLSTATE');
end $$;
select * from pg_temp.vc_call(3,format('select public.report_inquiry_sale(%L,%L)',pg_temp.vc(201),pg_temp.vc(101)),'00000','seller reports sale');
select is((select status::text from public.visits where id=pg_temp.vc(401)),'cancelled','sale report cancels visit for another interest immediately');
select ok((select from_status='requested' and to_status='cancelled' and actor_id=pg_temp.vc(3)
 and reason='Consulta cerrada' and scheduled_at=previous_scheduled_at from public.visit_history where visit_id=pg_temp.vc(401)),
 'report history preserves appointment and recording seller');
select ok((select first_outcome_recorded_at is not null and outcome_assignee_id=pg_temp.vc(3)
 and purpose='Preserve purpose' from public.visits where id=pg_temp.vc(401)),'first cancellation has commercial attribution');
select is((select status::text from public.visits where id=pg_temp.vc(402)),'confirmed','report does not cancel other inquiries');
select is((select availability_status::text from public.vehicles where id=pg_temp.vc(101)),'available','report does not sell inventory');
select * from pg_temp.vc_call(3,format('select public.report_inquiry_sale(%L,%L)',pg_temp.vc(201),pg_temp.vc(101)),'00000','report retry');
select is((select count(*)::int from public.visit_history where visit_id=pg_temp.vc(401)),1,'retry does not duplicate cancellation');
select * from pg_temp.vc_call(1,format('select public.resolve_sale_review(%L,true)',
 (select id from public.sale_reviews where inquiry_id=pg_temp.vc(201))),'00000','Owner confirms sale');
select is((select status::text from public.visits where id=pg_temp.vc(402)),'cancelled','Sold cancels other inquiry visit');
select is((select reason from public.visit_history where visit_id=pg_temp.vc(402)),'Vehículo vendido','Sold reason');
select is((select status::text from public.inquiries where id=pg_temp.vc(202)),'new','Sold does not close other inquiry');
select * from pg_temp.vc_call(2,format('select public.set_vehicle_sale_blocked(%L,true)',pg_temp.vc(103)),'00000','Admin blocks');
select is((select status::text from public.visits where id=pg_temp.vc(404)),'cancelled','blocking cancels confirmed visit');
select is((select reason from public.visit_history where visit_id=pg_temp.vc(404)),'Vehículo bloqueado','blocked reason');
select * from pg_temp.vc_call(2,format('select public.set_vehicle_sale_blocked(%L,false)',pg_temp.vc(103)),'00000','Admin unblocks');
select is((select status::text from public.visits where id=pg_temp.vc(404)),'cancelled','unblock does not restore');
select * from pg_temp.vc_call(1,format('update public.vehicles set deleted_at=now() where id=%L',pg_temp.vc(104)),'00000','Owner soft deletes');
select is((select status::text from public.visits where id=pg_temp.vc(406)),'cancelled','soft delete cancels');
select is((select reason from public.visit_history where visit_id=pg_temp.vc(406)),'Vehículo dado de baja','deletion reason');
select * from pg_temp.vc_call(1,format('select public.set_vehicle_sale_blocked(%L,true)',pg_temp.vc(105)),'00000','block unassigned inquiry vehicle');
select ok((select first_outcome_recorded_at is not null and outcome_assignee_id is null
 from public.visits where id=pg_temp.vc(407)),'unassigned outcome is not attributed to administrator');
select * from pg_temp.vc_call(3,format('select public.reserve_inquiry_vehicle(%L,%L)',pg_temp.vc(208),pg_temp.vc(106)),'00000','seller reserves');
select is((select status::text from public.visits where id=pg_temp.vc(408)),'confirmed','Reserved keeps visit');
-- No general close RPC exists yet; privileged state transition tests its database hook.
update public.inquiries set status='closed_without_sale' where id=pg_temp.vc(209);
select is((select status::text from public.visits where id=pg_temp.vc(409)),'cancelled','closed without sale cancels');
select is((select reason from public.visit_history where visit_id=pg_temp.vc(409)),'Consulta cerrada','closure reason');
select * from pg_temp.vc_call(3,format('select public.reopen_inquiry(%L)',pg_temp.vc(209)),'00000','seller reopens');
select is((select status::text from public.visits where id=pg_temp.vc(409)),'cancelled','reopen does not restore');
select * from pg_temp.vc_call(1,format('select public.set_vehicle_sale_blocked(%L,true)',pg_temp.vc(108)),'00000','block reactivated visit');
select ok((select first_outcome_recorded_at=now()-interval '1 day' and outcome_assignee_id is null
 from public.visits where id=pg_temp.vc(410)),'reactivated first-unassigned attribution retained');
select is((select count(*)::int from final_before b join public.visits v using(id) where to_jsonb(v)=b.data),4,
 'all final states remain byte-for-byte unchanged');
select is((select intent from public.visit_creation_requests where submission_id=pg_temp.vc(600)),
 '{"original":true}'::jsonb,'immutable creation intent preserved');
select * from pg_temp.vc_call(4,format('select public.set_vehicle_sale_blocked(%L,true)',pg_temp.vc(110)),'42501','seller block denied');
select is((select status::text from public.visits where id=pg_temp.vc(412)),'confirmed','denied block leaves visit unchanged');
select * from pg_temp.vc_call(4,format('select public.report_inquiry_sale(%L,%L)',pg_temp.vc(213),pg_temp.vc(111)),'42501','coworker sale denied');
select is((select status::text from public.visits where id=pg_temp.vc(413)),'requested','denied report leaves visit unchanged');
create function pg_temp.fail_vc_history() returns trigger language plpgsql as $$
 begin raise exception 'injected history failure' using errcode='P0001'; end $$;
create trigger fail_vc_history before insert on public.visit_history for each row execute function pg_temp.fail_vc_history();
select * from pg_temp.vc_call(1,format('select public.set_vehicle_sale_blocked(%L,true)',pg_temp.vc(109)),'P0001','history failure rolls back block');
select ok((select sale_enabled from public.vehicles where id=pg_temp.vc(109)),'failed history preserves inventory');
select is((select status::text from public.visits where id=pg_temp.vc(411)),'requested','failed history preserves visit');
select * from pg_temp.vc_call(3,format('select public.report_inquiry_sale(%L,%L)',pg_temp.vc(214),pg_temp.vc(112)),'P0001','history failure rolls back report');
select is((select status::text from public.inquiries where id=pg_temp.vc(214)),'new','failed history preserves inquiry');
select is((select count(*)::int from public.sale_reviews where inquiry_id=pg_temp.vc(214)),0,'failed history leaves no review');
drop trigger fail_vc_history on public.visit_history;
select * from pg_temp.vc_call(1,format('update public.vehicles set model=''Edited'' where id=%L',pg_temp.vc(113)),'00000','ordinary inventory edit');
select is((select status::text from public.visits where id=pg_temp.vc(415)),'requested','ordinary update keeps visit');
select ok(not has_function_privilege(r, 'public.cancel_pending_visits(uuid,uuid,text)','execute')
 and not has_function_privilege(r,'public.cancel_closed_inquiry_visits()','execute')
 and not has_function_privilege(r,'public.cancel_unavailable_vehicle_visits()','execute'),
 r||' cannot execute private cancellation hooks') from unnest(array['anon','authenticated','service_role'])r;
select * from finish();
rollback;
