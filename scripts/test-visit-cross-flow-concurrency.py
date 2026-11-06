"""Cross-flow cancellation probes on a fresh owned disposable database.
Leaves the database and external scratch for caller cleanup; never resets shared data.
"""
import pathlib,subprocess,tempfile,uuid,json,time,concurrent.futures,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
HERE=pathlib.Path(tempfile.mkdtemp(prefix='verify-visit-cross-flow-'))
DB='verify_visits_t4_'+uuid.uuid4().hex[:8]
BASE=['docker','exec','-i','supabase_db_dealership-mvp']
def run(s,db=DB):
 return subprocess.run(BASE+['psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1','-d',db],input=s,text=True,encoding='utf8',capture_output=True,timeout=40)
def sql(s,db=DB):
 r=run(s,db)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
print('DATABASE '+DB+' SCRATCH '+str(HERE),flush=True);(HERE/'database.txt').write_text(DB)
sql('create database '+DB,'postgres');sql('drop schema public;')
dump=subprocess.run(BASE+['pg_dump','-s','-U','postgres','-n','auth','-n','public','-n','extensions','postgres'],text=True,encoding='utf8',capture_output=True,check=True).stdout
(HERE/'schema.sql').write_text(dump,encoding='utf8')
r=subprocess.run(BASE+['psql','-X','-qAt','-U','supabase_admin','-v','ON_ERROR_STOP=1','-d',DB],input=dump,text=True,encoding='utf8',capture_output=True);assert r.returncode==0,r.stderr
count=0
def check(ok,label):
 global count
 assert ok,label
 count+=1;print('PASS '+label,flush=True)
def uid(n):return str(uuid.UUID(hashlib.md5(('verify-t4-'+str(n)).encode()).hexdigest()))
def u(n):return "'"+uid(n)+"'::uuid"
def auth(n=3,role='authenticated'):return 'set role '+role+";set request.jwt.claim.sub='"+uid(n)+"';"
fixture="insert into auth.users(id,email) values "+','.join('('+u(n)+",'t4-"+str(n)+"@example.invalid')" for n in (1,2,3,4))+';'
fixture+="insert into public.profiles(id,role,display_name,is_active) values "+','.join('('+u(n)+",'"+role+"','Verify',true)" for n,role in [(1,'owner'),(2,'admin'),(3,'seller'),(4,'seller')])+';'
fixture+="insert into public.contacts(id,normalized_phone,display_name) values ("+u(10)+",'+5491177008822','Verify');"
fixture+="insert into public.vehicles(id,brand,model,year,publication_status) values ("+u(20)+",'Test','A',2024,'published'),("+u(21)+",'Test','B',2024,'published');"
fixture+="insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_phone) values "+','.join('('+','.join([u(n),u(n+100),u(10),u(21),u(3)])+",'Verify','+5491177008822')" for n in (30,31))+';'
fixture+='insert into public.inquiry_interests(inquiry_id,vehicle_id) values '+','.join('('+u(n)+','+u(v)+')' for n in (30,31) for v in (20,21))+';'
fixture+="insert into public.dealership_opening_hours select n,'00:00','24:00' from generate_series(0,6)n;"
sql(fixture);(HERE/'fixture.sql').write_text(fixture,encoding='utf8')
slot=sql("select clock_timestamp()+interval '7 days'")
slot2=sql("select '"+slot+"'::timestamptz+interval '1 hour'")
hashfn="""create function public.verify_state_hash() returns text language plpgsql as $$declare r record; h text=''; x text;begin for r in select tablename from pg_tables where schemaname='public' order by tablename loop execute format('select coalesce(string_agg(row_to_json(t)::text,''|'' order by row_to_json(t)::text),'''') from public.%I t',r.tablename) into x;h:=h||r.tablename||x;end loop;return md5(h);end$$;"""
sql(hashfn)
def denied(cmd,error):
 before=sql('select public.verify_state_hash()');r=run(cmd)
 check(r.returncode==3 and error in r.stderr,'denied '+error)
 check(before==sql('select public.verify_state_hash()'),'all-public-table hash unchanged')
def reset(status='requested',both=False,first=False):
 sql("delete from public.visit_history;delete from public.visit_creation_requests;delete from public.visits;delete from public.inquiry_status_history;delete from public.confirmed_sales;delete from public.sale_reviews;delete from public.reservations;update public.inquiries set status='new',assignee_id="+u(3)+";update public.vehicles set sale_enabled=true,availability_status='available',deleted_at=null;")
 for n,i in [(40,30)]+([(41,31)] if both else []):
  sql('insert into public.visits(id,inquiry_id,vehicle_id,scheduled_at,status,purpose,request_assignee_id,first_outcome_recorded_at,outcome_assignee_id) values('+','.join([u(n),u(i),u(20)])+",'"+slot+"','"+status+"','Original',"+u(3)+","+("'2020-01-01Z',null" if first else 'null,null')+');')
def report():return auth()+ 'select public.report_inquiry_sale('+u(30)+','+u(21)+');'
def block():return auth(2)+'select public.set_vehicle_sale_blocked('+u(20)+',true);'
def state(target,reason='Correction'):return auth(2)+'select public.set_visit_status('+u(40)+",'"+target+"','"+reason+"');"
def res():return auth(2)+'select public.reschedule_visit('+u(40)+",'"+slot2+"',true);"
def create():return auth(2)+'select public.create_inquiry_visit('+','.join([u(50),u(30),u(20)])+",'"+slot+"','Original');"
def snapshot():return json.loads(sql('select row_to_json(v) from public.visits v where id='+u(40)))
def verify_cancel(reason,actor,old='requested',appointment=slot,history=1):
 check(sql('select status::text from public.visits where id='+u(40))=='cancelled','terminal cancelled')
 check(sql('select count(*) from public.visit_history where visit_id='+u(40))==str(history),'exact history count')
 check(sql("select from_status='"+old+"' and to_status='cancelled' and reason='"+reason+"' and actor_id="+u(actor)+" and previous_scheduled_at=scheduled_at and scheduled_at='"+appointment+"'::timestamptz from public.visit_history where visit_id="+u(40)+' order by occurred_at desc limit 1')=='t','exact cancellation state/reason/actor/appointment')
reset(both=True);before=snapshot();sql(report());verify_cancel('Consulta cerrada',3)
check(sql('select status::text from public.visits where id='+u(41))=='requested','report only cancels own inquiry with different-interest visit')
after=snapshot();check(all(after[k]==before[k] for k in before if k not in ('status','updated_at','first_outcome_recorded_at','outcome_assignee_id')),'report immutable visit fields preserved')
check(after['outcome_assignee_id']==uid(3) and after['first_outcome_recorded_at'] is not None,'report attribution follows responsible seller')
for role in ['anon','authenticated','service_role']:
 for fn,args in [('cancel_pending_visits',u(30)+",null,'test'"),('cancel_closed_inquiry_visits',''),('cancel_unavailable_vehicle_visits','')]:denied(auth(3,role)+'select public.'+fn+'('+args+');','permission denied')
for column,value,reason in [('sale_enabled','false','Vehículo bloqueado'),('availability_status',"'sold'",'Vehículo vendido'),('deleted_at','clock_timestamp()','Vehículo dado de baja')]:
 reset(both=True,first=True);before=snapshot()
 if column=='availability_status':
  sql(auth()+'select public.report_inquiry_sale('+u(31)+','+u(20)+');');sql(auth(1)+'select public.resolve_sale_review((select id from public.sale_reviews where inquiry_id='+u(31)+'),true);')
 else:sql(auth(1)+'update public.vehicles set '+column+'='+value+' where id='+u(20))
 verify_cancel(reason,1)
 check(sql('select count(*) from public.visits where status=\'cancelled\'')=='2','vehicle cancels every inquiry pending visit')
 check(sql('select status::text from public.inquiries where id='+u(30))=='new','vehicle leaves other inquiry active')
 after=snapshot();check(after['outcome_assignee_id'] is None and after['first_outcome_recorded_at']==before['first_outcome_recorded_at'],'preserve first explicit-unassigned outcome')
for final in ['attended','no_show','cancelled']:
 reset(status=final,first=True);before=snapshot();sql(block());check(snapshot()==before and sql('select count(*) from public.visit_history')=='0','final '+final+' unchanged')
reset();sql("create function public.fail_t4() returns trigger language plpgsql as $$begin raise exception 'injected-t4';end$$;create trigger fail_t4 before insert on public.visit_history for each row execute function public.fail_t4();")
denied(block(),'injected-t4');denied(report(),'injected-t4');sql('drop trigger fail_t4 on public.visit_history;drop function public.fail_t4();')
CMD=BASE+['psql','-X','-qAt','-U','postgres','-v','ON_ERROR_STOP=1','-d',DB]
def wait(pred):
 until=time.monotonic()+15
 while time.monotonic()<until:
  if sql('select '+pred)=='t':return
  time.sleep(.03)
 raise AssertionError('no observed wait '+pred)
def race(label,hold,attempt,error=None):
 tag='t4_'+uuid.uuid4().hex
 p=subprocess.Popen(CMD,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8')
 try:
  p.stdin.write("begin;set application_name='"+tag+"_a';"+hold.rstrip(';')+';\n');p.stdin.flush()
  wait("exists(select from pg_stat_activity where application_name='"+tag+"_a' and state='idle in transaction')")
  with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
   future=pool.submit(run,"set application_name='"+tag+"_b';"+attempt)
   wait("exists(select from pg_stat_activity a where application_name='"+tag+"_b' and wait_event_type='Lock' and cardinality(pg_blocking_pids(pid))>0 and exists(select from pg_locks l where l.pid=a.pid and not l.granted))")
   p.stdin.write('commit;\n');p.stdin.close();p.wait(timeout=10);r=future.result()
  check(p.returncode==0 and r.returncode==(3 if error else 0) and (not error or error in r.stderr),label+' observed pg_locks wait/release and exact exit')
  (HERE/(label+'.txt')).write_text(r.stdout+'\n'+r.stderr,encoding='utf8')
 finally:
  if p.poll() is None:p.kill();p.wait()
reset();race('report_then_reschedule',report(),res(),'only pending visits can be rescheduled');verify_cancel('Consulta cerrada',3)
reset();race('reschedule_then_report',res(),report());verify_cancel('Consulta cerrada',3,'confirmed',slot2,2)
reset();race('close_then_reschedule',"update public.inquiries set status='closed_without_sale' where id="+u(30),res(),'only pending visits can be rescheduled')
check(sql('select status::text from public.visits where id='+u(40))=='cancelled','close wins')
reset();race('reschedule_then_close',res(),"update public.inquiries set status='closed_without_sale' where id="+u(30));check(sql("select status='cancelled' and scheduled_at='"+slot2+"' from public.visits where id="+u(40))=='t','close retains rescheduled appointment')
reset();sql('delete from public.visits;');race('block_then_create',block(),create(),'vehicle does not accept visits');check(sql('select count(*) from public.visits')=='0','blocked creation has no partial visit')
reset();sql('delete from public.visits;');race('create_then_block',create(),block());check(sql("select count(*)=1 and bool_and(status='cancelled') from public.visits")=='t' and sql("select count(*) from public.visit_history")=='2','created visit cancelled with exactly creation+cancellation history')
reset(status='cancelled',first=True);race('block_then_restore',block(),state('confirmed'),'vehicle does not accept visits');check(sql('select count(*) from public.visit_history')=='0','rejected restore no history')
reset(status='cancelled',first=True);race('restore_then_block',state('confirmed'),block());verify_cancel('Vehículo bloqueado',2,'confirmed',slot,2)
reset(status='confirmed');sql("update public.visits set scheduled_at=clock_timestamp()-interval '1 hour';")
race('result_then_block',state('attended'),block());check(sql('select status::text from public.visits where id='+u(40))=='attended' and sql('select count(*) from public.visit_history')=='1','attended wins and remains final')
reset(status='confirmed');sql("update public.visits set scheduled_at=clock_timestamp()-interval '1 hour';")
race('block_then_result',block(),state('attended'));check(sql('select status::text from public.visits where id='+u(40))=='attended' and sql('select count(*) from public.visit_history')=='2','authorized historical correction follows cancellation')
reset(both=True);race('report_then_block_overlap',report(),block());verify_cancel('Consulta cerrada',3);check(sql('select count(*) from public.visit_history')=='2','overlapping parent cancellations no duplicate events')
reset(both=True);race('block_then_report_overlap',block(),report());verify_cancel('Vehículo bloqueado',2);check(sql('select count(*) from public.visit_history')=='2','reverse overlapping parents no duplicate events')
print('CHECKS '+str(count)+' DATABASE '+DB+' SCRATCH '+str(HERE),flush=True)
