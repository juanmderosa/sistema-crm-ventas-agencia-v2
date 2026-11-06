"""Rescheduling permission and concurrency regression probes on an owned disposable DB.
Leaves its database and external scratch for caller cleanup; never resets shared data.
"""
import subprocess, pathlib, uuid, hashlib, json, time, concurrent.futures
import tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
HERE=pathlib.Path(tempfile.mkdtemp(prefix='verify-visit-reschedule-'))
DB='verify_visits_reschedule_'+uuid.uuid4().hex[:8]
BASE=['docker','exec','-i','supabase_db_dealership-mvp']
def run(source,db=DB):
 return subprocess.run(BASE+['psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1','-d',db],input=source,text=True,encoding='utf8',capture_output=True,timeout=45)
def sql(source,db=DB):
 r=run(source,db)
 if r.returncode: raise RuntimeError(r.stderr)
 return r.stdout.strip()
print('DATABASE '+DB,flush=True)
(HERE/'database.txt').write_text(DB)
sql('create database '+DB+';', 'postgres')
sql('drop schema public;')
dump=subprocess.run(BASE+['pg_dump','-s','-U','postgres','-n','auth','-n','public','-n','extensions','postgres'],text=True,encoding='utf8',capture_output=True,check=True).stdout
(HERE/'schema.sql').write_text(dump,encoding='utf8')
r=subprocess.run(BASE+['psql','-X','-qAt','-U','supabase_admin','-v','ON_ERROR_STOP=1','-d',DB],input=dump,text=True,encoding='utf8',capture_output=True); assert r.returncode==0,r.stderr
# Independent fixture, including a second vehicle for the same inquiry.
def uid(n): return str(uuid.UUID(hashlib.md5(('independent-state-'+str(n)).encode()).hexdigest()))
def u(n): return "'"+uid(n)+"'::uuid"
fixture="insert into auth.users(id,email) values "+','.join('('+u(n)+",'ivs"+str(n)+"@example.invalid')" for n in range(1,7))+';'
fixture+="insert into public.profiles(id,role,display_name,is_active) values "+','.join('('+u(n)+",'"+role+"','Test',"+active+')' for n,role,active in [(1,'owner','true'),(2,'admin','true'),(3,'seller','true'),(4,'seller','true'),(5,'seller','false'),(6,'admin','false')])+';'
fixture+="insert into public.vehicles(id,brand,model,year) values ("+u(20)+",'Test','One',2024),("+u(21)+",'Test','Two',2024);"
fixture+="insert into public.contacts(id,normalized_phone,display_name) values ("+u(10)+",'+5491177009931','Test');"
fixture+="insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_phone) values ("+','.join([u(30),u(31),u(10),u(20),u(3)])+",'Test','+5491177009931');"
fixture+='insert into public.inquiry_interests(inquiry_id,vehicle_id) values ('+u(30)+','+u(20)+'),('+u(30)+','+u(21)+');'
fixture+="insert into public.dealership_opening_hours select n,'00:00','24:00' from generate_series(0,6)n;"
fixture+="insert into public.visits(id,inquiry_id,vehicle_id,scheduled_at,status,request_assignee_id) values ("+','.join([u(40),u(30),u(20)])+",clock_timestamp()-interval '1 hour','confirmed',"+u(3)+');'
(HERE/'fixture.sql').write_text(fixture,encoding='utf8');sql(fixture)
def auth(n=3,role='authenticated'): return "set role "+role+";set request.jwt.claim.sub='"+uid(n)+"';"
def state(target,reason=None,n=3,visit=40):
 return auth(n)+'select public.set_visit_status('+u(visit)+",'"+target+"'"+(",'"+reason+"'" if reason is not None else '')+');'
# Hash every public table, including private ledgers; schema excludes sequences.
hashfn="""create function public.verify_state_hash() returns text language plpgsql as $$declare r record; h text=''; x text;begin for r in select tablename from pg_tables where schemaname='public' order by tablename loop execute format('select coalesce(string_agg(row_to_json(t)::text,''|'' order by row_to_json(t)::text),'''') from public.%I t',r.tablename) into x;h:=h||r.tablename||x;end loop;return md5(h);end$$;"""
sql(hashfn)
checks=0
def check(ok,label):
 global checks
 assert ok,label
 checks+=1; print('PASS '+label,flush=True)
def denied(command,error):
 before=sql('select public.verify_state_hash();');r=run(command)
 check(r.returncode==3 and error in r.stderr,'denied '+error)
 check(before==sql('select public.verify_state_hash();'),'rejected command preserves every public table')
def res(slot,agreed=True,n=3,visit=40):
 return auth(n)+'select public.reschedule_visit('+u(visit)+",'"+slot+"'::timestamptz,"+str(agreed).lower()+');'
def scalar(q):return sql(q)
# Reconstruct exact baseline by removing the sole newly added function; no tables/old functions changed.
sql('drop function public.reschedule_visit(uuid,timestamptz,boolean);')
olddefs=sql("select md5(string_agg(pg_get_functiondef(p.oid),'' order by p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f';")
r=run((ROOT/'supabase/migrations/20261105150000_visit_rescheduling.sql').read_text(encoding='utf-8'))
check(r.returncode==0,'new migration applies to isolated schema without preexisting reschedule RPC')
check(olddefs==sql("select md5(string_agg(pg_get_functiondef(p.oid),'' order by p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and p.proname<>'reschedule_visit';"),'every existing public function definition unchanged')
slot=sql("select clock_timestamp()+interval '7 days'")
slot2=sql("select '"+slot+"'::timestamptz+interval '1 hour'")
slot3=sql("select '"+slot+"'::timestamptz+interval '2 hours'")
for n in (4,5,6,7):denied(res(slot,n=n),'visit access denied')
for role in ('anon','service_role'):denied(auth(3,role)+'select public.reschedule_visit('+u(40)+",'"+slot+"',true);",'permission denied')
# Former assignee after real reassignment.
sql('update public.inquiries set assignee_id='+u(4)+';')
denied(res(slot),'visit access denied');sql('update public.inquiries set assignee_id='+u(3)+';')
# Original first-result fields, including explicitly unassigned, survive restored/rescheduled visits.
sql(state('cancelled',n=2));sql(state('confirmed','Restore',2))
original=json.loads(sql('select row_to_json(v) from public.visits v where id='+u(40)+';'))
check(json.loads(sql(res(slot,n=2)))=={'visit_id':uid(40)},'active admin can agree reschedule')
check(json.loads(sql(res(slot2,False,n=1)))=={'visit_id':uid(40)},'active owner can propose reschedule')
current=json.loads(sql('select row_to_json(v) from public.visits v where id='+u(40)+';'))
check(all(current[k]==original[k] for k in original if k not in ('status','scheduled_at','updated_at')),'all identity purpose attribution and first-result fields preserved')
check(sql('select from_status::text||\'>\'||to_status::text||\'|\'||(previous_scheduled_at=\''+slot+'\'::timestamptz)::text||\'|\'||(scheduled_at=\''+slot2+'\'::timestamptz)::text||\'|\'||(actor_id='+u(1)+')::text from public.visit_history order by occurred_at desc limit 1;')=='confirmed>requested|true|true|true','proposal history has exact old/new state appointment and actor')
for target in ('attended','cancelled','no_show'):
 sql('update public.visits set status=\''+target+'\';');denied(res(slot), 'only pending visits can be rescheduled')
sql("update public.visits set status='requested';")
for timestamp in ('infinity','-infinity','2000-01-01T00:00:00Z'):
 denied(res(timestamp),'visit time must be future and within opening hours')
denied(auth(3)+'select public.reschedule_visit('+u(40)+',null,true);','visit time must be future and within opening hours')
denied(auth(3)+'select public.reschedule_visit('+u(40)+",'"+slot+"',null);",'visit agreement is required')
# Trigger-injected history failure proves atomic appointment rollback too.
sql("create function public.reject_history_probe() returns trigger language plpgsql as $$begin raise exception 'probe history rejected';end$$;create trigger reject_history_probe before insert on public.visit_history for each row execute function public.reject_history_probe();")
denied(res(slot3),'probe history rejected')
sql('drop trigger reject_history_probe on public.visit_history;drop function public.reject_history_probe();')
CMD=BASE+['psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1','-d',DB]
def wait(pred):
 until=time.monotonic()+15
 while time.monotonic()<until:
  if sql('select '+pred+';')=='t':return
  time.sleep(.03)
 raise AssertionError('wait not observed '+pred)
def race(label,hold,attempt,error=None,expiry=None):
 tag='reschedule_'+uuid.uuid4().hex
 p=subprocess.Popen(CMD,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8')
 try:
  p.stdin.write("begin;set application_name='"+tag+"_a';"+hold+'\n');p.stdin.flush()
  wait("exists(select from pg_stat_activity where application_name='"+tag+"_a' and state='idle in transaction')")
  # Holder's committed result is expected state; contender denial may not mutate it.
  with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(run,"set application_name='"+tag+"_b';"+attempt)
   wait("exists(select from pg_stat_activity where application_name='"+tag+"_b' and wait_event_type='Lock' and cardinality(pg_blocking_pids(pid))>0)")
   if expiry:
    wait("clock_timestamp() > '"+expiry+"'::timestamptz")
   p.stdin.write('commit;\n');p.stdin.close();p.wait(timeout=10);r=future.result()
  check(p.returncode==0 and r.returncode==(3 if error else 0) and (not error or error in r.stderr),label+' observed real lock wait and exact result')
  (HERE/(label+'.txt')).write_text(r.stdout+'\n'+r.stderr,encoding='utf8')
 finally:
  if p.poll() is None:p.kill();p.wait()
# Two concurrent reschedules must chain from the committed appointment, not stale snapshot.
sql('delete from public.visit_history;')
race('two_reschedules',res(slot,True,n=2),res(slot2,False,n=1))
check(sql("select string_agg(from_status::text||'>'||to_status::text,',' order by occurred_at) from public.visit_history;")=='requested>confirmed,confirmed>requested','concurrent reschedules exact chained history')
check(sql('select (select count(*)=2 from public.visit_history) and exists(select from public.visit_history where from_status=\'confirmed\' and to_status=\'requested\' and previous_scheduled_at=\''+slot+'\' and scheduled_at=\''+slot2+'\') and exists(select from public.visits where status=\'requested\' and scheduled_at=\''+slot2+'\');')=='t','concurrent appointments and final state exact')
race('terminal_then_reschedule',state('cancelled',n=2),res(slot3),'only pending visits can be rescheduled')
check(sql("select count(*)=3 and count(*) filter(where to_status='cancelled')=1 from public.visit_history;")=='t','terminal wins without rejected reschedule history')
sql(state('confirmed','Restore',2))
race('reschedule_then_terminal',res(slot3),state('cancelled',n=2))
check(sql('select status=\'cancelled\' and scheduled_at=\''+slot3+'\'::timestamptz from public.visits;')=='t','terminal after reschedule retains new appointment')
sql(state('confirmed','Restore',2))
# Real schedule replacement holds advisory lock; newly closed schedule rejects pending reschedule.
prior=sql('select md5(string_agg(row_to_json(t)::text,\'|\' order by row_to_json(t)::text)) from public.visits t;')
hist=sql('select count(*) from public.visit_history;')
race('replacement_then_validate',auth(1)+"select public.set_dealership_opening_hours('[]');",res(slot),'visit time must be future and within opening hours')
check(sql('select count(*) from public.dealership_opening_hours;')=='0' and hist==sql('select count(*) from public.visit_history;') and prior==sql('select md5(string_agg(row_to_json(t)::text,\'|\' order by row_to_json(t)::text)) from public.visits t;'),'replacement survives while rejected reschedule has zero visit/history effects')
sql("insert into public.dealership_opening_hours select n,'00:00','24:00' from generate_series(0,6)n;")
# Hold schedule lock until proposed timestamp actually expires; use actual clock not transaction now.
expiry=sql("select clock_timestamp()+interval '4 seconds'")
before=sql('select public.verify_state_hash();')
race('expiry_during_schedule_wait',"select pg_advisory_xact_lock(hashtextextended('dealership.opening_hours',0));",res(expiry),'visit time must be future and within opening hours',expiry)
check(before==sql('select public.verify_state_hash();'),'expiry rejection has no persisted effects anywhere')
# Actor/inquiry modifications commit before authorization is reevaluated.
prior=sql('select row_to_json(t)::text from public.visits t;');hist=sql('select count(*) from public.visit_history;')
race('deactivate_during_wait','update public.profiles set is_active=false where id='+u(3)+';',res(slot),'visit access denied')
check(prior==sql('select row_to_json(t)::text from public.visits t;') and hist==sql('select count(*) from public.visit_history;'),'deactivation rejection does not change visit or history')
sql('update public.profiles set is_active=true where id='+u(3)+';')
race('reassign_during_wait','update public.inquiries set assignee_id='+u(4)+' where id='+u(30)+';',res(slot),'visit access denied')
check(prior==sql('select row_to_json(t)::text from public.visits t;') and hist==sql('select count(*) from public.visit_history;'),'reassignment rejection does not change visit or history')
sql('update public.inquiries set assignee_id='+u(3)+';')
# Staff creation retry must preserve immutable intent after rescheduling.
sql(state('cancelled',n=2))
creation=auth(3)+'select public.create_inquiry_visit('+','.join([u(100),u(30),u(21)])+",'"+slot+"'::timestamptz,'Original staff');"
created=json.loads(sql(creation))['visit_id'];intent=sql('select intent from public.visit_creation_requests where submission_id='+u(100)+';')
sql(auth(3)+"select public.reschedule_visit('"+created+"','"+slot2+"',true);")
check(json.loads(sql(creation))['visit_id']==created and intent==sql('select intent from public.visit_creation_requests where submission_id='+u(100)+';'),'staff creation retry after reschedule preserves identity and exact intent')
# Public accepted-only retry similarly cannot leak/change rescheduled visit.
sql("update public.vehicles set publication_status='published' where id="+u(21)+';')
request="set role service_role;select public.submit_visit_request("+u(200)+','+u(21)+",'+5491177009932','Public','pub@example.invalid','"+slot+"'::timestamptz,'Original public');"
check(json.loads(sql(request))=={'accepted':True},'public creation accepted-only')
publicvisit=sql('select visit_id from public.visit_creation_requests where submission_id='+u(200)+';')
intent=sql('select intent from public.visit_creation_requests where submission_id='+u(200)+';')
sql(auth(2)+"select public.reschedule_visit('"+publicvisit+"','"+slot3+"',false);")
before=sql('select public.verify_state_hash();')
check(json.loads(sql(request))=={'accepted':True} and before==sql('select public.verify_state_hash();') and intent==sql('select intent from public.visit_creation_requests where submission_id='+u(200)+';'),'public retry after reschedule accepted-only with exact complete persisted parity')
# Explicitly-unassigned first outcome survives restoration/reschedule.
sql('update public.inquiries set assignee_id=null where id='+u(30)+';')
sql(auth(2)+"select public.set_visit_status('"+created+"','cancelled');")
# Existing staff-created visit already has first outcome unset before this cancellation.
check(sql("select outcome_assignee_id is null and first_outcome_recorded_at is not null from public.visits where id='"+created+"';")=='t','unassigned first outcome fixture recorded')
first=sql("select first_outcome_recorded_at from public.visits where id='"+created+"';")
sql(auth(2)+"select public.set_visit_status('"+created+"','confirmed','Restore');select public.reschedule_visit('"+created+"','"+slot3+"',true);")
check(sql("select outcome_assignee_id is null and first_outcome_recorded_at='"+first+"'::timestamptz from public.visits where id='"+created+"';")=='t','explicitly unassigned first outcome preserved after reschedule')
print('CHECKS '+str(checks)+' DATABASE '+DB+' SCRATCH '+str(HERE),flush=True)
