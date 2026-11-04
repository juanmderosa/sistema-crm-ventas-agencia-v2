begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Synthetic inventory uses the same database-owner fixture boundary as T5.
insert into public.vehicles(id, brand, model, year, publication_status, availability_status, sale_enabled, deleted_at)
values
 ('00000000-0000-4000-8000-00000000e601','Test','Available',2024,'published','available',true,null),
 ('00000000-0000-4000-8000-00000000e602','Test','Sold',2024,'published','sold',true,null),
 ('00000000-0000-4000-8000-00000000e603','Test','Reserved',2024,'published','reserved',true,null),
 ('00000000-0000-4000-8000-00000000e604','Test','Draft',2024,'draft','available',true,null),
 ('00000000-0000-4000-8000-00000000e605','Test','Blocked',2024,'published','available',false,null),
 ('00000000-0000-4000-8000-00000000e606','Test','Deleted',2024,'published','available',true,now());

select has_table('public','vehicle_view_events','counted view events exist');
select has_table('public','vehicle_view_dedup','private dedup state exists');
select has_function('public','record_vehicle_view',array['uuid','uuid'],'server ingestion exists');

create function pg_temp.view_state() returns text language sql as $$
 select md5(jsonb_build_array(
   (select jsonb_agg(to_jsonb(e) order by e.id) from public.vehicle_view_events e),
   (select jsonb_agg(to_jsonb(d) order by d.vehicle_id,d.browser_token) from public.vehicle_view_dedup d)
 )::text)
$$;
create temp table view_snapshot(value text);
insert into view_snapshot select pg_temp.view_state();

-- Privilege denial is role-wide: even an Owner JWT cannot call server ingestion.
set local role anon;
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f601')$$,
 '42501',null,'anon cannot forge a public view');
reset role;
set local role authenticated;
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f601')$$,
 '42501',null,'authenticated cannot generate views');
reset role;
select is(pg_temp.view_state(),(select value from view_snapshot),'denied ingestion preserves all view state');

set local role service_role;
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f601'),true,'first load counts');
reset role;
update view_snapshot set value=pg_temp.view_state();
set local role service_role;
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f601'),false,'same pair within 24h does not count');
reset role;
select is(pg_temp.view_state(),(select value from view_snapshot),'duplicate never extends the rolling window or adds an event');
select is((select count(*)::int from public.vehicle_view_events),1,'exactly one event persisted');
select is((select last_counted_at from public.vehicle_view_dedup limit 1),
 (select counted_at from public.vehicle_view_events limit 1),'event and dedup timestamps agree');

-- Backdating only fixtures avoids a production caller-controlled clock.
update public.vehicle_view_dedup set last_counted_at=clock_timestamp()-interval '23 hours';
set local role service_role;
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f601'),false,'23h does not expire');
reset role;
update public.vehicle_view_dedup set last_counted_at=clock_timestamp()-interval '25 hours';
set local role service_role;
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f601'),true,'25h expires without calendar bucketing');
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e601','00000000-0000-4000-8000-00000000f602'),true,'another browser counts independently');
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e602','00000000-0000-4000-8000-00000000f601'),true,'same browser counts Sold public detail independently');
select is(public.record_vehicle_view('00000000-0000-4000-8000-00000000e603','00000000-0000-4000-8000-00000000f601'),true,'Reserved public detail counts');
reset role;
select is((select count(*)::int from public.vehicle_view_events),5,'only accepted counts create events');
select is((select count(*)::int from public.vehicle_view_dedup),4,'one dedup row per pair');
update view_snapshot set value=pg_temp.view_state();

set local role service_role;
select throws_ok($$select public.record_vehicle_view(null,'00000000-0000-4000-8000-00000000f601')$$,'22023','vehicle and browser token are required','null vehicle rejected');
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e601',null)$$,'22023','vehicle and browser token are required','null browser rejected');
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e604','00000000-0000-4000-8000-00000000f601')$$,'22023','vehicle is not publicly visible','draft rejected');
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e605','00000000-0000-4000-8000-00000000f601')$$,'22023','vehicle is not publicly visible','blocked rejected');
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e606','00000000-0000-4000-8000-00000000f601')$$,'22023','vehicle is not publicly visible','deleted rejected');
select throws_ok($$select public.record_vehicle_view('00000000-0000-4000-8000-00000000e699','00000000-0000-4000-8000-00000000f601')$$,'22023','vehicle is not publicly visible','missing rejected with the same error');
reset role;
select is(pg_temp.view_state(),(select value from view_snapshot),'every rejected input preserves stored state');

-- Test effective ACLs including default grants and PUBLIC inheritance.
select ok(not has_function_privilege(r,'public.record_vehicle_view(uuid,uuid)','EXECUTE'),r||' has no ingestion privilege')
 from (values ('anon'),('authenticated')) roles(r);
select ok(has_function_privilege('service_role','public.record_vehicle_view(uuid,uuid)','EXECUTE'),'service ingestion allowed');
select ok(not has_table_privilege(r,t,p),r||' cannot '||p||' '||t)
 from (values ('anon'),('authenticated'),('service_role')) roles(r)
 cross join (values ('public.vehicle_view_events'),('public.vehicle_view_dedup')) tables(t)
 cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) privileges(p);
select ok(relrowsecurity,relname||' has RLS') from pg_class
 where oid in ('public.vehicle_view_events'::regclass,'public.vehicle_view_dedup'::regclass);
select is((select count(*)::int from pg_policy where polrelid in
 ('public.vehicle_view_events'::regclass,'public.vehicle_view_dedup'::regclass)),0,'no raw-table policies expose browser state');
select ok(prosecdef,'ingestion uses controlled definer privileges') from pg_proc
 where oid='public.record_vehicle_view(uuid,uuid)'::regprocedure;
select * from finish();
rollback;
