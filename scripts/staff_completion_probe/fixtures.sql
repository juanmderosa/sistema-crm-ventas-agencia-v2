-- Synthetic SQL-role fixtures, not real acceptance or password evidence.
insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-000000008001','probe-owner@example.invalid');
insert into public.profiles(id,role,display_name,is_active) values
 ('00000000-0000-0000-0000-000000008001','owner','Probe Owner',true);
-- Per-invitation setup reuses public intent/prepare/bind APIs in db.py.
