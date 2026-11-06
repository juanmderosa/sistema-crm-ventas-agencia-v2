-- Original intent survives later scheduling/status changes. It is never an
-- application-readable history or identity-discovery endpoint.
create table public.visit_creation_requests (
  submission_id uuid primary key,
  source text not null check (source in ('staff', 'public')),
  inquiry_id uuid not null references public.inquiries(id) on delete restrict,
  visit_id uuid not null unique references public.visits(id) on delete restrict,
  intent jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.visit_creation_requests enable row level security;
revoke all on public.visit_creation_requests from public, anon, authenticated, service_role;

create function public.require_visit_opening_time(p_scheduled_at timestamptz)
returns void language plpgsql set search_path = '' as $$
declare local_time timestamp;
begin
  -- Call only after vehicle, actor and inquiry locks. The hours setter holds
  -- actor -> schedule, so taking another actor lock after this would invert it.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('dealership.opening_hours', 0));
  local_time := p_scheduled_at at time zone 'America/Argentina/Buenos_Aires';
  if p_scheduled_at is null or not isfinite(p_scheduled_at)
    or p_scheduled_at <= clock_timestamp() or not exists (
      select 1 from public.dealership_opening_hours h
      where h.weekday = extract(dow from local_time)::integer
        and h.opens_at <= local_time::time and local_time::time < h.closes_at
    ) then
    raise exception 'visit time must be future and within opening hours' using errcode = '22023';
  end if;
end;
$$;
revoke all on function public.require_visit_opening_time(timestamptz)
  from public, anon, authenticated, service_role;

create function public.create_inquiry_visit(
  p_submission_id uuid, p_inquiry_id uuid, p_vehicle_id uuid,
  p_scheduled_at timestamptz, p_purpose text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  selected_vehicle public.vehicles%rowtype;
  selected_inquiry public.inquiries%rowtype;
  actor public.profiles%rowtype;
  prior public.visit_creation_requests%rowtype;
  original_intent jsonb;
  visit uuid;
begin
  if not public.is_active_staff() then
    raise exception 'visit access denied' using errcode = '42501';
  end if;
  if p_submission_id is null or p_inquiry_id is null or p_vehicle_id is null
    or p_scheduled_at is null or not isfinite(p_scheduled_at) then
    raise exception 'invalid visit input' using errcode = '22023';
  end if;
  original_intent := jsonb_build_object('inquiry_id', p_inquiry_id, 'vehicle_id', p_vehicle_id,
    'scheduled_epoch', extract(epoch from p_scheduled_at), 'purpose', p_purpose);
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('inquiry-submission:' || p_submission_id::text, 0));
  select * into selected_vehicle from public.vehicles where id = p_vehicle_id for update;
  select * into actor from public.profiles where id = auth.uid() for share;
  if actor.id is null or not actor.is_active then
    raise exception 'visit access denied' using errcode = '42501';
  end if;
  select * into selected_inquiry from public.inquiries where id = p_inquiry_id for update;
  if selected_inquiry.id is null or (actor.role = 'seller'
    and selected_inquiry.assignee_id is distinct from actor.id) then
    raise exception 'visit access denied' using errcode = '42501';
  end if;
  -- Reauthorize every private retry before returning its original identifier.
  -- Compare original intent, never mutable visit state or session timezone text.
  select * into prior from public.visit_creation_requests where submission_id = p_submission_id;
  if found then
    if prior.source <> 'staff' or prior.intent is distinct from original_intent then
      raise exception 'visit submission ID already used with different input' using errcode = '22023';
    end if;
    return jsonb_build_object('visit_id', prior.visit_id);
  end if;
  if selected_inquiry.status not in ('new', 'contacted', 'following_up') then
    raise exception 'inquiry is not active' using errcode = '22023';
  end if;
  if selected_vehicle.id is null or selected_vehicle.deleted_at is not null
    or not selected_vehicle.sale_enabled or selected_vehicle.availability_status = 'sold' then
    raise exception 'vehicle does not accept visits' using errcode = '22023';
  end if;
  if not exists (select 1 from public.inquiry_interests
    where inquiry_id = p_inquiry_id and vehicle_id = p_vehicle_id) then
    raise exception 'vehicle is not an inquiry interest' using errcode = '22023';
  end if;
  if exists (select 1 from public.visits where inquiry_id = p_inquiry_id
    and status in ('requested', 'confirmed')) then
    raise exception 'inquiry already has a pending visit' using errcode = '22023';
  end if;
  perform public.require_visit_opening_time(p_scheduled_at);
  insert into public.visits(inquiry_id, vehicle_id, scheduled_at, purpose, request_assignee_id)
    values(p_inquiry_id, p_vehicle_id, p_scheduled_at, p_purpose, selected_inquiry.assignee_id)
    returning id into visit;
  insert into public.visit_history(visit_id, to_status, scheduled_at, actor_id)
    values(visit, 'requested', p_scheduled_at, actor.id);
  insert into public.visit_creation_requests(submission_id, source, inquiry_id, visit_id, intent)
    values(p_submission_id, 'staff', p_inquiry_id, visit, original_intent);
  return jsonb_build_object('visit_id', visit);
end;
$$;
revoke all on function public.create_inquiry_visit(uuid, uuid, uuid, timestamptz, text)
  from public, anon, service_role;
grant execute on function public.create_inquiry_visit(uuid, uuid, uuid, timestamptz, text) to authenticated;
comment on function public.create_inquiry_visit(uuid, uuid, uuid, timestamptz, text) is
  'Active responsible staff or Owner/Admin creates a tentative visit for an existing active inquiry interest. Submission UUID identifies original intent; private retries reauthorize before returning visit_id. No inquiry creation, reservation or routing. READ COMMITTED required.';
