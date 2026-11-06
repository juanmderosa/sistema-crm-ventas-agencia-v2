-- Preserve the ordinary submission contract and routing implementation. The
-- only new branch rejects a UUID already committed as a public visit intent.
create or replace function public.submit_inquiry(
  p_submission_id uuid, p_vehicle_id uuid, p_phone text, p_name text, p_email text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  perform pg_advisory_xact_lock(hashtextextended('inquiry-submission:' || p_submission_id::text, 0));
  if exists (select 1 from public.visit_creation_requests
    where submission_id = p_submission_id and source = 'public') then
    raise exception 'submission ID already used with different input' using errcode = '22023';
  end if;
  select * into prior from public.inquiries where submission_id = p_submission_id;
  if found then
    if prior.originating_vehicle_id is distinct from p_vehicle_id
       or prior.submitted_phone is distinct from p_phone
       or prior.submitted_name is distinct from p_name
       or prior.submitted_email is distinct from p_email then
      raise exception 'submission ID already used with different input' using errcode = '22023';
    end if;
    return '{"accepted":true}'::jsonb;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('inquiry-contact:' || p_phone, 0));
  select * into vehicle from public.vehicles where id = p_vehicle_id for update;
  if not found or vehicle.deleted_at is not null
     or vehicle.publication_status <> 'published' or vehicle.availability_status = 'sold' then
    raise exception 'vehicle does not accept inquiries' using errcode = '22023';
  end if;
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

create function public.submit_visit_request(
  p_submission_id uuid, p_vehicle_id uuid, p_phone text, p_name text, p_email text,
  p_scheduled_at timestamptz, p_purpose text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  prior public.visit_creation_requests%rowtype;
  selected_inquiry public.inquiries%rowtype;
  original_intent jsonb;
  visit uuid;
begin
  if p_submission_id is null or p_scheduled_at is null or not isfinite(p_scheduled_at) then
    raise exception 'invalid visit input' using errcode = '22023';
  end if;
  original_intent := jsonb_build_object('vehicle_id',p_vehicle_id,'phone',p_phone,
    'name',p_name,'email',p_email,'scheduled_epoch',extract(epoch from p_scheduled_at),'purpose',p_purpose);
  perform pg_advisory_xact_lock(hashtextextended('inquiry-submission:' || p_submission_id::text,0));
  select * into prior from public.visit_creation_requests where submission_id=p_submission_id;
  if found then
    if prior.source <> 'public' or prior.intent is distinct from original_intent then
      raise exception 'visit submission ID already used with different input' using errcode = '22023';
    end if;
    return '{"accepted":true}'::jsonb;
  end if;
  if exists (select 1 from public.inquiries where submission_id=p_submission_id) then
    raise exception 'submission ID already used with different input' using errcode = '22023';
  end if;
  -- Reuse canonical validation, contact preservation, continuity and rotation.
  -- No marker exists yet, so the ordinary-operation intent guard permits this
  -- nested call. The shared submission lock protects both insertion directions.
  perform public.submit_inquiry(p_submission_id,p_vehicle_id,p_phone,p_name,p_email);
  select * into selected_inquiry from public.inquiries where submission_id=p_submission_id for update;
  if not (select sale_enabled from public.vehicles where id=p_vehicle_id) then
    raise exception 'vehicle does not accept visits' using errcode = '22023';
  end if;
  perform public.require_visit_opening_time(p_scheduled_at);
  insert into public.visits(inquiry_id,vehicle_id,scheduled_at,purpose,request_assignee_id)
    values(selected_inquiry.id,p_vehicle_id,p_scheduled_at,p_purpose,selected_inquiry.assignee_id)
    returning id into visit;
  insert into public.visit_history(visit_id,to_status,scheduled_at,actor_id)
    values(visit,'requested',p_scheduled_at,null);
  insert into public.visit_creation_requests(submission_id,source,inquiry_id,visit_id,intent)
    values(p_submission_id,'public',selected_inquiry.id,visit,original_intent);
  return '{"accepted":true}'::jsonb;
end;
$$;
revoke all on function public.submit_visit_request(uuid,uuid,text,text,text,timestamptz,text)
  from public,anon,authenticated;
grant execute on function public.submit_visit_request(uuid,uuid,text,text,text,timestamptz,text) to service_role;
comment on function public.submit_visit_request(uuid,uuid,text,text,text,timestamptz,text) is
  'Trusted backend only; canonical inputs required. Atomically creates a routed inquiry and tentative visit; exact original-intent retries return accepted only, including after later state changes. READ COMMITTED required; real phone parsing and abuse protection remain mandatory before public HTTP exposure.';
