begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
select has_function('public','reporting_period',array['text','date','date'],'internal reporting calendar exists');

-- Compare UTC instants, not session-dependent timestamp display strings.
select results_eq(
 $$select local_start,local_end,start_at,end_at from public.reporting_period('month','2024-02-17',null)$$,
 $$values(date '2024-02-01',date '2024-02-29',timestamptz '2024-02-01 03:00:00+00',timestamptz '2024-03-01 03:00:00+00')$$,
 'leap February includes the last day and excludes next local midnight');
select results_eq(
 $$select local_start,local_end from public.reporting_period('quarter','2026-12-31',null)$$,
 $$values(date '2026-10-01',date '2026-12-31')$$,'fourth quarter crosses the year at exclusive end');
select results_eq(
 $$select local_start,local_end from public.reporting_period('semester','2026-06-30',null)$$,
 $$values(date '2026-01-01',date '2026-06-30')$$,'first semester');
select results_eq(
 $$select local_start,local_end from public.reporting_period('semester','2026-07-01',null)$$,
 $$values(date '2026-07-01',date '2026-12-31')$$,'second semester');
select results_eq(
 $$select local_start,local_end from public.reporting_period('year','2024-12-31',null)$$,
 $$values(date '2024-01-01',date '2024-12-31')$$,'calendar year');
select results_eq(
 $$select local_start,local_end,start_at,end_at from public.reporting_period('custom','2026-11-04','2026-11-04')$$,
 $$values(date '2026-11-04',date '2026-11-04',timestamptz '2026-11-04 03:00:00+00',timestamptz '2026-11-05 03:00:00+00')$$,
 'single-day custom range includes the whole local day');
select results_eq(
 $$select local_start,local_end from public.reporting_period('custom','2024-02-29','2025-01-01')$$,
 $$values(date '2024-02-29',date '2025-01-01')$$,'custom range spans months and years without bucketing');

select is((select count(*) from public.reporting_period('custom','2026-11-04','2026-11-05') p
 cross join (values(timestamptz '2026-11-04 02:59:59.999999+00'),
 (timestamptz '2026-11-04 03:00:00+00'),(timestamptz '2026-11-06 02:59:59.999999+00'),
 (timestamptz '2026-11-06 03:00:00+00')) events(at)
 where at>=p.start_at and at<p.end_at),2::bigint,'half-open interval includes start and final microsecond, not next day');

create temp table period_snapshot as select * from public.reporting_period('month','2026-11-04',null);
set local timezone='Pacific/Auckland';
select results_eq($$select * from public.reporting_period('month','2026-11-04',null)$$,
 $$select * from period_snapshot$$,'session timezone does not change output instants or dates');
set local timezone='UTC';
select is((select timezone_name from public.reporting_period('year','2026-01-01',null)),
 'America/Argentina/Buenos_Aires','timezone is explicit');

-- Each local midnight is converted independently, including historical offsets.
select is((select start_at from public.reporting_period('custom','2008-01-01','2008-07-01')),
 timestamp '2008-01-01 00:00:00' at time zone 'America/Argentina/Buenos_Aires','historical start offset');
select is((select end_at from public.reporting_period('custom','2008-01-01','2008-07-01')),
 timestamp '2008-07-02 00:00:00' at time zone 'America/Argentina/Buenos_Aires','historical end offset independently converted');

select throws_ok(sql,'22023',null,label) from (values
 ($$select * from public.reporting_period(null,'2026-01-01',null)$$,'null kind'),
 ($$select * from public.reporting_period('week','2026-01-01',null)$$,'unsupported kind'),
 ($$select * from public.reporting_period('month',null,null)$$,'null anchor'),
 ($$select * from public.reporting_period('custom','2026-01-01',null)$$,'missing custom end'),
 ($$select * from public.reporting_period('custom','2026-02-01','2026-01-01')$$,'reversed dates'),
 ($$select * from public.reporting_period('month','2026-01-01','2026-01-31')$$,'calendar kind must not ignore custom end'),
 ($$select * from public.reporting_period('custom','-infinity','2026-01-01')$$,'infinite start'),
 ($$select * from public.reporting_period('custom','2026-01-01','infinity')$$,'infinite end'),
 ($$select * from public.reporting_period('year','5874897-12-31',null)$$,'unrepresentable timestamp boundary')
) invalid(sql,label);

select ok(not has_function_privilege(r,'public.reporting_period(text,date,date)','EXECUTE'),
 r||' has no direct internal-helper RPC access') from (values('anon'),('authenticated'),('service_role')) roles(r);
select * from finish();
rollback;
