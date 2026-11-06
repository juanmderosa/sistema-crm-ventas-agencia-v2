"""Independent state/permission probes on a newly created disposable local database.
Leaves its database and external scratch for caller cleanup; never resets shared data.
"""
import subprocess, pathlib, uuid, hashlib, json, time, concurrent.futures
import tempfile
HERE=pathlib.Path(tempfile.mkdtemp(prefix='verify-visit-states-'))
DB='verify_visits_states_'+uuid.uuid4().hex[:8]
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
def check(cond,label):
 global checks
 assert cond,label
 checks+=1;print('PASS '+label,flush=True)
def denied(source,error):
 before=sql('select public.verify_state_hash();'); r=run(source)
 check(r.returncode==3 and error in r.stderr,'rejection '+error)
 check(before==sql('select public.verify_state_hash();'),'rejection preserves all public data')
for n in (4,5,6): denied(state('attended',n=n),'visit access denied')
for role in ('anon','service_role'): denied(auth(3,role)+'select public.set_visit_status('+u(40)+",'attended');",'permission denied')
check(json.loads(sql(state('attended')))=={'visit_id':uid(40)},'responsible seller records attendance')
original=sql('select row_to_json(v) from public.visits v where id='+u(40)+';')
denied(state('cancelled','  '),'correction reason is required')
sql("update public.inquiries set status='closed_without_sale' where id="+u(30)+";update public.vehicles set availability_status='sold',sale_enabled=false where id="+u(20)+';')
check(json.loads(sql(state('no_show','Historical',2)))=={'visit_id':uid(40)},'admin historical correction closed/sold/blocked')
denied(state('confirmed','Restore',2),'inquiry is not active')
sql("update public.inquiries set status='following_up' where id="+u(30)+';')
denied(state('confirmed','Restore',2),'vehicle does not accept visits')
sql("update public.vehicles set availability_status='reserved',sale_enabled=true where id="+u(20)+';')
check(json.loads(sql(state('confirmed','Restore',1)))=={'visit_id':uid(40)},'owner restores past confirmed Reserved visit')
sql(state('cancelled',n=1))
# Reliable first outcome / appointment parity, comparing JSON projections.
current=json.loads(sql('select row_to_json(v) from public.visits v where id='+u(40)+';'));original=json.loads(original)
check(all(current[k]==original[k] for k in ['first_outcome_recorded_at','outcome_assignee_id','request_assignee_id','scheduled_at','purpose']),'original attribution and appointment preserved')
# Commit/contender release handshake and observed PostgreSQL lock wait.
CMD=BASE+['psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1','-d',DB]
def wait(pred):
 until=time.monotonic()+15
 while time.monotonic()<until:
  if sql('select '+pred+';')=='t': return
  time.sleep(.03)
 raise AssertionError('wait not observed '+pred)
def race(label,hold,attempt,error=None):
 tag='ivs_'+uuid.uuid4().hex
 p=subprocess.Popen(CMD,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8')
 try:
  p.stdin.write("begin;set application_name='"+tag+"_a';"+hold+'\n');p.stdin.flush()
  wait("exists(select from pg_stat_activity where application_name='"+tag+"_a' and state='idle in transaction')")
  with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(run,"set application_name='"+tag+"_b';"+attempt)
   wait("exists(select from pg_stat_activity where application_name='"+tag+"_b' and wait_event_type='Lock' and cardinality(pg_blocking_pids(pid))>0)")
   p.stdin.write('commit;\n');p.stdin.close();p.wait(timeout=10);r=future.result()
  check(p.returncode==0 and r.returncode==(3 if error else 0) and (not error or error in r.stderr),label+' observed wait/release/result')
  (HERE/(label+'.txt')).write_text(r.stdout+'\n'+r.stderr,encoding='utf8')
 finally:
  if p.poll() is None:p.kill();p.wait()
race('final_corrections',state('attended','First',2),state('no_show','Second',1))
check(sql('select status::text from public.visits where id='+u(40)+';')=='no_show','last serialized correction persists')
check(sql('select string_agg(from_status::text||\'>\'||to_status::text,\',\' order by occurred_at) from (select * from public.visit_history where visit_id='+u(40)+' order by occurred_at desc limit 2)t;')=='cancelled>attended,attended>no_show','serialized correction history exact')
slot=sql("select clock_timestamp()+interval '7 days'")
creation=auth(3)+'select public.create_inquiry_visit('+','.join([u(100),u(30),u(21)])+",'"+slot+"'::timestamptz,null);"
race('restore_then_create',state('confirmed','Restore',2),creation,'inquiry already has a pending visit')
check(sql('select count(*) from public.visits where inquiry_id='+u(30)+" and status in ('requested','confirmed');")=='1','cross-vehicle restoration leaves one pending')
sql(state('cancelled',n=2))
race('create_then_restore',creation,state('confirmed','Restore',2),'inquiry already has a pending visit')
newvisit=json.loads(sql(creation))['visit_id']
check(sql('select count(*) from public.visits where inquiry_id='+u(30)+" and status in ('requested','confirmed');")=='1','cross-vehicle creation leaves one pending')
# Existing private retry retains exact intent despite lifecycle mutation.
sql(auth(2)+"select public.set_visit_status('"+newvisit+"','cancelled');")
check(json.loads(sql(creation))['visit_id']==newvisit,'private creation retry preserves original intent after lifecycle')
race('deactivate_wait', 'update public.profiles set is_active=false where id='+u(3)+';',state('attended','Correction'),'visit access denied')
sql('update public.profiles set is_active=true where id='+u(3)+';')
race('reassign_wait','update public.inquiries set assignee_id='+u(4)+' where id='+u(30)+';',state('attended','Correction'),'visit access denied')
# Unassigned first result remains unassigned through later responsibility changes.
sql('update public.inquiries set assignee_id=null where id='+u(30)+';')
sql(auth(2)+'select public.set_visit_status('+u(40)+",'attended','Correction');")
# New visit's initial cancellation above occurred assigned; use fresh terminal visit.
sql("insert into public.visits(id,inquiry_id,vehicle_id,scheduled_at) values ("+','.join([u(42),u(30),u(20)])+",clock_timestamp()-interval '1 hour');")
sql(state('cancelled',n=2,visit=42)); unattributed=sql('select first_outcome_recorded_at from public.visits where id='+u(42)+';')
sql('update public.inquiries set assignee_id='+u(4)+' where id='+u(30)+';')
sql(state('confirmed','Restore',2,42));sql(state('no_show',n=2,visit=42))
check(sql('select outcome_assignee_id is null and first_outcome_recorded_at=\''+unattributed+'\'::timestamptz from public.visits where id='+u(42)+';')=='t','recorded-unassigned first result stays null through reactivation and refinalization')
print('CHECKS '+str(checks)+' DATABASE '+DB+' SCRATCH '+str(HERE),flush=True)

auth="set role authenticated;set request.jwt.claim.sub="+u(2).replace('::uuid','')+';'
sql("update public.vehicles set publication_status='published' where id="+u(21)+';')
slot=sql("select clock_timestamp()+interval '7 days'")
request="set role service_role;select public.submit_visit_request("+u(200)+','+u(21)+",'+5491177009932','Public','pub@example.invalid','"+slot+"'::timestamptz,null);"
assert json.loads(sql(request))=={'accepted':True}
visit=sql('select visit_id from public.visit_creation_requests where submission_id='+u(200)+';')
intent=sql('select intent from public.visit_creation_requests where submission_id='+u(200)+';')
sql(auth+"select public.set_visit_status('"+visit+"','confirmed');select public.set_visit_status('"+visit+"','cancelled');select public.set_visit_status('"+visit+"','no_show','Correction');")
assert json.loads(sql(request))=={'accepted':True}
assert intent==sql('select intent from public.visit_creation_requests where submission_id='+u(200)+';')
assert sql("select count(*) from public.visits where id='"+visit+"';")=='1'
print('PASS public retry accepted-only and exact immutable intent after lifecycle; one visit')

