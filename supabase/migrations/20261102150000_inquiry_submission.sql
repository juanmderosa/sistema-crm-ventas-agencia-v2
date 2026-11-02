-- The caller is a trusted backend with canonical inputs, not an anonymous client.
alter table public.inquiries add column submitted_phone text
  check (submitted_phone ~ '^\+[1-9][0-9]{1,14}$');

create table public.vehicle_inquiry_participants (
  vehicle_id uuid not null references public.vehicles (id) on delete restrict,
  profile_id uuid not null references public.profiles (id) on delete restrict,
  primary key (vehicle_id, profile_id)
);
create table public.vehicle_inquiry_rotation (
  vehicle_id uuid primary key references public.vehicles (id) on delete restrict,
  last_assignee_id uuid not null references public.profiles (id) on delete restrict
);
create table public.inquiry_assignment_history (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.inquiries (id) on delete restrict,
  assignee_id uuid references public.profiles (id) on delete restrict,
  reason text not null check (reason in ('rotation', 'continuity', 'unassigned')),
  created_at timestamptz not null default now()
);
create index inquiry_assignment_history_inquiry_idx on public.inquiry_assignment_history (inquiry_id);
alter table public.vehicle_inquiry_participants enable row level security;
alter table public.vehicle_inquiry_rotation enable row level security;
alter table public.inquiry_assignment_history enable row level security;
create policy participants_select_admin on public.vehicle_inquiry_participants
for select to authenticated using (public.is_owner_or_admin());
create policy rotation_select_admin on public.vehicle_inquiry_rotation
for select to authenticated using (public.is_owner_or_admin());
-- History remains administrative; former assignee identities are not exposed to sellers.
create policy assignment_history_select_admin on public.inquiry_assignment_history
for select to authenticated using (public.is_owner_or_admin());
revoke all on public.vehicle_inquiry_participants, public.vehicle_inquiry_rotation, public.inquiry_assignment_history from anon, authenticated;
grant select on public.vehicle_inquiry_participants, public.vehicle_inquiry_rotation, public.inquiry_assignment_history to authenticated;
grant select, insert, update, delete on public.vehicle_inquiry_participants to service_role;
grant select, insert, update on public.vehicle_inquiry_rotation to service_role;
grant select, insert on public.inquiry_assignment_history to service_role;

create function public.submit_inquiry(
  p_submission_id uuid, p_vehicle_id uuid, p_phone text, p_name text, p_email text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  prior public.inquiries%rowtype;
  vehicle public.vehicles%rowtype;
  contact uuid;
  inquiry uuid;
  eligible uuid[];
  assigned uuid;
  previous uuid;
  assignment_reason text;
begin
  if p_submission_id is null or p_vehicle_id is null
     or p_phone is null or p_phone !~ '^\+[1-9][0-9]{1,14}$'
     or p_name is null or btrim(p_name) = ''
     or p_email is null or btrim(p_email) = '' then
    raise exception 'invalid inquiry input' using errcode = '22023';
  end if;

  -- Fixed lock ordering: submission, normalized contact, originating vehicle,
  -- then eligible profiles in stable order. Hash collisions only serialize more work.
  perform pg_advisory_xact_lock(hashtextextended('inquiry-submission:' || p_submission_id::text, 0));
  select * into prior from public.inquiries where submission_id = p_submission_id;
  if found then
    if prior.originating_vehicle_id is distinct from p_vehicle_id
       or prior.submitted_phone is distinct from p_phone
       or prior.submitted_name is distinct from p_name
       or prior.submitted_email is distinct from p_email then
      raise exception 'submission ID already used with different input' using errcode = '22023';
    end if;
    -- A late retry is independent of later availability or assignment changes.
    return '{"accepted":true}'::jsonb;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('inquiry-contact:' || p_phone, 0));
  select * into vehicle from public.vehicles where id = p_vehicle_id for update;
  if not found or vehicle.deleted_at is not null
     or vehicle.publication_status <> 'published' or vehicle.availability_status = 'sold' then
    raise exception 'vehicle does not accept inquiries' using errcode = '22023';
  end if;

  -- Lock eligibility until commit so profile deactivation cannot race assignment.
  select array_agg(p.id order by p.id) into eligible from (
    select p.id from public.profiles p
    where p.is_active and (
      p.role = 'seller' or exists (
        select 1 from public.vehicle_inquiry_participants vp
        where vp.vehicle_id = p_vehicle_id and vp.profile_id = p.id
      )
    )
    order by p.id for share
  ) p;

  select id into contact from public.contacts where normalized_phone = p_phone;
  if contact is null then
    insert into public.contacts (normalized_phone, display_name, email)
    values (p_phone, p_name, p_email) returning id into contact;
  end if;
  select i.assignee_id into assigned from public.inquiries i
  where i.contact_id = contact
    and i.status in ('new', 'contacted', 'following_up')
    and i.assignee_id = any(eligible)
  order by i.created_at desc, i.creation_sequence desc limit 1;
  assignment_reason := 'continuity';
  if assigned is null and cardinality(eligible) > 0 then
    select last_assignee_id into previous from public.vehicle_inquiry_rotation where vehicle_id = p_vehicle_id;
    select e into assigned from unnest(eligible) e where e > previous order by e limit 1;
    if assigned is null then assigned := eligible[1]; end if;
    insert into public.vehicle_inquiry_rotation (vehicle_id, last_assignee_id)
    values (p_vehicle_id, assigned)
    on conflict (vehicle_id) do update set last_assignee_id = excluded.last_assignee_id;
    assignment_reason := 'rotation';
  elsif assigned is null then
    assignment_reason := 'unassigned';
  end if;

  insert into public.inquiries (
    submission_id, contact_id, originating_vehicle_id, assignee_id,
    submitted_phone, submitted_name, submitted_email
  ) values (
    p_submission_id, contact, p_vehicle_id, assigned, p_phone, p_name, p_email
  ) returning id into inquiry;
  insert into public.inquiry_interests (inquiry_id, vehicle_id) values (inquiry, p_vehicle_id);
  insert into public.inquiry_assignment_history (inquiry_id, assignee_id, reason)
  values (inquiry, assigned, assignment_reason);
  return '{"accepted":true}'::jsonb;
end;
$$;
revoke all on function public.submit_inquiry(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.submit_inquiry(uuid, uuid, text, text, text) to service_role;

comment on function public.submit_inquiry(uuid, uuid, text, text, text) is
  'Internal backend operation. Canonical inputs compare exactly for retries. Requires READ COMMITTED transactions; real phone validation and abuse protection must precede public exposure.';
