-- Manual inquiries are the same CRM follow-up entry as web submissions, with an
-- explicit origin. Creation stays a controlled operation, not a table grant.
create type public.inquiry_origin as enum ('web', 'in_person', 'phone');

alter table public.inquiries add column origin public.inquiry_origin not null default 'web';

-- Manual follow-up may start before a vehicle is chosen; reservation still
-- requires an Available interest. The web submission keeps its vehicle.
alter table public.inquiries alter column originating_vehicle_id drop not null;

-- Manual email is optional. The web submission keeps requiring it in code.
alter table public.inquiries alter column submitted_email drop not null;
alter table public.inquiries drop constraint inquiries_submitted_email_check;
alter table public.inquiries add constraint inquiries_submitted_email_check
  check (submitted_email is null or btrim(submitted_email) <> '');

alter table public.contacts alter column email drop not null;
alter table public.contacts drop constraint contacts_email_check;
alter table public.contacts add constraint contacts_email_check
  check (email is null or btrim(email) <> '');

-- A manual inquiry is self-assigned, so history records that reason explicitly.
alter table public.inquiry_assignment_history
  drop constraint inquiry_assignment_history_reason_check;
alter table public.inquiry_assignment_history add constraint inquiry_assignment_history_reason_check
  check (reason in ('rotation', 'continuity', 'unassigned', 'manual'));

create function public.create_manual_inquiry(
  p_phone text, p_name text, p_email text, p_vehicle_id uuid, p_origin public.inquiry_origin
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_vehicle public.vehicles%rowtype;
  contact uuid;
  inquiry uuid;
begin
  -- The web origin only comes from submit_inquiry; manual callers cannot forge it.
  if p_origin is null or p_origin not in ('in_person', 'phone') then
    raise exception 'manual inquiry origin must be in_person or phone' using errcode = '22023';
  end if;
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{1,14}$'
     or p_name is null or btrim(p_name) = ''
     or (p_email is not null and btrim(p_email) = '') then
    raise exception 'invalid manual inquiry input' using errcode = '22023';
  end if;

  -- Reject non-staff before inspecting inventory: this check reveals nothing and
  -- avoids exposing availability to an authenticated identity without a profile.
  -- Revalidated under the actor lock below; the lock order is unchanged.
  if not public.is_active_staff() then
    raise exception 'manual inquiry access denied' using errcode = '42501';
  end if;

  -- Reuse the submission/phone-correction routing namespace and take it before
  -- row locks, then hold the actor against deactivation until commit.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('inquiry-contact:' || p_phone, 0)
  );
  if p_vehicle_id is not null then
    select * into selected_vehicle from public.vehicles
    where id = p_vehicle_id for update;
    if not found or selected_vehicle.deleted_at is not null
       or selected_vehicle.availability_status <> 'available' then
      raise exception 'vehicle must be Available and not deleted' using errcode = '22023';
    end if;
  end if;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'manual inquiry access denied' using errcode = '42501';
  end if;

  -- A recognized phone never overwrites the stored contact; the submitted name
  -- and email stay on the new inquiry for authorized review.
  select id into contact from public.contacts where normalized_phone = p_phone;
  if contact is null then
    insert into public.contacts (normalized_phone, display_name, email)
    values (p_phone, p_name, p_email) returning id into contact;
  end if;

  insert into public.inquiries (
    submission_id, contact_id, originating_vehicle_id, assignee_id, status,
    submitted_phone, submitted_name, submitted_email, origin
  ) values (
    pg_catalog.gen_random_uuid(), contact, p_vehicle_id, auth.uid(), 'new',
    p_phone, p_name, p_email, p_origin
  ) returning id into inquiry;

  if p_vehicle_id is not null then
    insert into public.inquiry_interests (inquiry_id, vehicle_id)
    values (inquiry, p_vehicle_id);
  end if;
  insert into public.inquiry_assignment_history (inquiry_id, assignee_id, reason)
  values (inquiry, auth.uid(), 'manual');

  return pg_catalog.jsonb_build_object('inquiry_id', inquiry);
end;
$$;
revoke all on function public.create_manual_inquiry(
  text, text, text, uuid, public.inquiry_origin
) from public, anon, authenticated;
grant execute on function public.create_manual_inquiry(
  text, text, text, uuid, public.inquiry_origin
) to authenticated;

comment on column public.inquiries.origin is
  'Web submissions are set by submit_inquiry. Manual in-person/telephone entries are self-assigned and never advance web rotation.';
comment on function public.create_manual_inquiry(
  text, text, text, uuid, public.inquiry_origin
) is
  'Active staff register a manual in-person/telephone inquiry, optionally with one Available vehicle, assigned to the creator. Phone is mandatory; email is optional. READ COMMITTED callers; phone matching is not authorization to unrelated history.';
