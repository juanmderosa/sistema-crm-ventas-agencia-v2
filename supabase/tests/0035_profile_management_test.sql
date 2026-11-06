begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id,email)
select md5('profile-management-'||n)::uuid,'profile-management-'||n||'@example.invalid' from generate_series(1,9)n;
insert into public.profiles(id,role,display_name,is_active)
select md5('profile-management-'||n)::uuid,
 (case n when 1 then 'owner' when 2 then 'owner' when 3 then 'admin' when 4 then 'admin' when 6 then 'owner' when 7 then 'admin' else 'seller' end)::public.user_role,
 'Profile management '||n,n<6 from generate_series(1,8)n;

set local role authenticated;
select set_config('request.jwt.claim.sub',md5('profile-management-3')::uuid::text,true);
select throws_ok($$update public.profiles set role='owner' where id=md5('profile-management-5')::uuid$$,
 '42501',null,'admin cannot promote seller to owner');
select throws_ok($$update public.profiles set role='admin' where id=md5('profile-management-5')::uuid$$,
 '42501',null,'admin cannot promote seller to admin');
select is((select role::text from public.profiles where id=md5('profile-management-5')::uuid),'seller','rejected promotions preserve seller role');
with changed as (update public.profiles set display_name='Changed seller',is_active=false where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),1,'admin may rename and deactivate seller');
with changed as (update public.profiles set is_active=true where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),1,'admin may reactivate seller');
with changed as (update public.profiles set display_name='Self rename' where id=auth.uid() returning 1)
select is((select count(*)::int from changed),1,'admin self display-name update remains allowed');
select throws_ok($$update public.profiles set role='owner' where id=auth.uid()$$,'42501',null,'admin cannot self-promote');
select throws_ok($$update public.profiles set role='seller' where id=auth.uid()$$,'42501',null,'admin cannot manage own role');
select throws_ok($$update public.profiles set is_active=false where id=auth.uid()$$,'42501',null,'admin cannot deactivate own admin account');
with changed as (update public.profiles set display_name='Unauthorized' where id=md5('profile-management-4')::uuid returning 1)
select is((select count(*)::int from changed),0,'admin cannot rename another admin');
with changed as (update public.profiles set is_active=false where id=md5('profile-management-4')::uuid returning 1)
select is((select count(*)::int from changed),0,'admin cannot deactivate another admin');
with changed as (update public.profiles set role='seller' where id=md5('profile-management-4')::uuid returning 1)
select is((select count(*)::int from changed),0,'admin cannot demote another admin');
with changed as (update public.profiles set display_name='Unauthorized' where id=md5('profile-management-1')::uuid returning 1)
select is((select count(*)::int from changed),0,'admin cannot modify owner');
with changed as (update public.profiles set is_active=true where id=md5('profile-management-6')::uuid returning 1)
select is((select count(*)::int from changed),0,'admin cannot reactivate inactive owner');
with changed as (update public.profiles set role='seller' where id=md5('profile-management-7')::uuid returning 1)
select is((select count(*)::int from changed),0,'inactive admin targets remain owner-managed');
select throws_ok($$update public.profiles set id=md5('profile-management-9')::uuid where id=md5('profile-management-5')::uuid$$,
 '42501',null,'application cannot rebind profile identity');
select throws_ok($$update public.profiles set created_at=now() where id=md5('profile-management-5')::uuid$$,
 '42501',null,'application cannot rewrite creation timestamp');
select throws_ok($$update public.profiles set updated_at='2000-01-01' where id=md5('profile-management-5')::uuid$$,
 '42501',null,'application cannot supply system update timestamp');

select set_config('request.jwt.claim.sub',md5('profile-management-1')::uuid::text,true);
with changed as (update public.profiles set role='admin' where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),1,'owner can promote seller to admin');
with changed as (update public.profiles set display_name='Owner managed admin',is_active=false where id=md5('profile-management-4')::uuid returning 1)
select is((select count(*)::int from changed),1,'owner can rename and deactivate admin');
with changed as (update public.profiles set role='seller',is_active=true where id=md5('profile-management-4')::uuid returning 1)
select is((select count(*)::int from changed),1,'owner can demote and reactivate admin');
with changed as (update public.profiles set role='owner' where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),1,'owner can grant owner role');
with changed as (update public.profiles set role='seller' where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),1,'owner can remove other owner role when owners remain');
with changed as (update public.profiles set role='seller' where id=auth.uid() returning 1)
select is((select count(*)::int from changed),1,'owner self-demotion remains allowed with another active owner');
with changed as (update public.profiles set display_name='Unauthorized seller' where id=auth.uid() returning 1)
select is((select count(*)::int from changed),0,'demoted owner loses profile-management access on next statement');
select set_config('request.jwt.claim.sub',md5('profile-management-2')::uuid::text,true);
-- Remove unrelated preexisting active Owners only inside this rollback fixture.
reset role;
update public.profiles set is_active=false where role='owner' and id<>md5('profile-management-2')::uuid;
set local role authenticated;
select throws_ok($$update public.profiles set role='seller' where id=auth.uid()$$,'23514',null,'last active owner cannot self-demote');
select throws_ok($$update public.profiles set is_active=false where id=auth.uid()$$,'23514',null,'last active owner cannot self-deactivate');
select throws_ok($$update public.profiles set id=md5('profile-management-9')::uuid where id=auth.uid()$$,
 '42501',null,'owner cannot rewrite Auth identity link');

select set_config('request.jwt.claim.sub',md5('profile-management-5')::uuid::text,true);
with changed as (update public.profiles set role='owner' where id=auth.uid() returning 1)
select is((select count(*)::int from changed),0,'seller cannot self-promote');
select set_config('request.jwt.claim.sub',md5('profile-management-6')::uuid::text,true);
with changed as (update public.profiles set display_name='Inactive owner' where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),0,'inactive owner cannot manage seller');
select set_config('request.jwt.claim.sub',md5('profile-management-7')::uuid::text,true);
with changed as (update public.profiles set display_name='Inactive admin' where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),0,'inactive admin cannot manage seller');
select set_config('request.jwt.claim.sub',md5('profile-management-9')::uuid::text,true);
with changed as (update public.profiles set display_name='Missing profile' where id=md5('profile-management-5')::uuid returning 1)
select is((select count(*)::int from changed),0,'identity without profile cannot manage seller');
reset role;
select ok(not has_column_privilege('authenticated','public.profiles','id','UPDATE'),'identity column has no application update grant');
select ok(has_column_privilege('authenticated','public.profiles','display_name','UPDATE'),'display-name column retains application update grant');
select * from finish();
rollback;
