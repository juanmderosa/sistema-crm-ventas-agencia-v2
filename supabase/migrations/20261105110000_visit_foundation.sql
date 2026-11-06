-- Private visit foundation. Creation, transitions and public schedule delivery
-- are separate contracts; no application-role writes bypass those operations.
create table public.dealership_opening_hours (
  weekday integer not null check (weekday between 0 and 6),
  opens_at time without time zone not null,
  closes_at time without time zone not null,
  constraint opening_hours_ordered check (opens_at < closes_at),
  constraint opening_hours_no_overlap exclude using gist (
    numrange(weekday * 86400 + extract(epoch from opens_at),
      weekday * 86400 + extract(epoch from closes_at), '[)') with &&
  )
);
comment on table public.dealership_opening_hours is
  'Weekly local intervals in America/Argentina/Buenos_Aires. Sunday=0. No default schedule, capacity or appointment duration. Adjacent intervals are allowed.';

create type public.visit_status as enum ('requested', 'confirmed', 'attended', 'cancelled', 'no_show');
create table public.visits (
  id uuid primary key default gen_random_uuid(),
  inquiry_id uuid not null references public.inquiries(id) on delete restrict,
  vehicle_id uuid not null,
  scheduled_at timestamptz not null,
  status public.visit_status not null default 'requested',
  purpose text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  request_assignee_id uuid references public.profiles(id) on delete restrict,
  first_outcome_recorded_at timestamptz,
  outcome_assignee_id uuid references public.profiles(id) on delete restrict,
  foreign key (inquiry_id, vehicle_id)
    references public.inquiry_interests(inquiry_id, vehicle_id) on delete restrict,
  constraint visit_outcome_attribution_recorded check (
    first_outcome_recorded_at is not null or outcome_assignee_id is null
  )
);
create unique index visits_one_pending_per_inquiry on public.visits(inquiry_id)
  where status in ('requested', 'confirmed');
create index visits_vehicle_idx on public.visits(vehicle_id);
create trigger visits_set_updated_at before update on public.visits
  for each row execute function public.set_updated_at();
comment on column public.visits.first_outcome_recorded_at is
  'Distinguishes never recorded from a first result with no assignee. Retained on correction/reactivation; attribution is not the recording actor.';

create table public.visit_history (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references public.visits(id) on delete restrict,
  from_status public.visit_status,
  to_status public.visit_status not null,
  previous_scheduled_at timestamptz,
  scheduled_at timestamptz,
  actor_id uuid references public.profiles(id) on delete restrict,
  reason text,
  occurred_at timestamptz not null default now()
);
create index visit_history_visit_idx on public.visit_history(visit_id, occurred_at);
comment on table public.visit_history is
  'Private audit storage. Later controlled visit operations record creation, scheduling, transitions, corrections and automatic cancellation. Null actor permits a system event.';

alter table public.dealership_opening_hours enable row level security;
alter table public.visits enable row level security;
alter table public.visit_history enable row level security;
create policy opening_hours_staff_read on public.dealership_opening_hours
  for select to authenticated using (public.is_active_staff());
create policy visits_visible_inquiry on public.visits for select to authenticated
  using (exists (select 1 from public.inquiries i where i.id = visits.inquiry_id));
create policy visit_history_visible_visit on public.visit_history for select to authenticated
  using (exists (select 1 from public.visits v where v.id = visit_history.visit_id));
revoke all on public.dealership_opening_hours, public.visits, public.visit_history
  from public, anon, authenticated, service_role;
grant select on public.dealership_opening_hours, public.visits, public.visit_history to authenticated;

create function public.set_dealership_opening_hours(p_intervals jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  -- Stabilize the actor against deactivation, then serialize whole-schedule
  -- replacements. No vehicle/inquiry locks are acquired by this command.
  perform 1 from public.profiles p where p.id = auth.uid()
    and p.is_active and p.role in ('owner', 'admin') for share;
  if not found then
    raise exception 'opening hours access denied' using errcode = '42501';
  end if;
  if p_intervals is null or jsonb_typeof(p_intervals) <> 'array' then
    raise exception 'opening hours must be an array' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('dealership.opening_hours', 0));
  delete from public.dealership_opening_hours;
  insert into public.dealership_opening_hours(weekday, opens_at, closes_at)
    select x.weekday, x.opens_at, x.closes_at
    from pg_catalog.jsonb_to_recordset(p_intervals)
      as x(weekday integer, opens_at time without time zone, closes_at time without time zone);
end;
$$;
revoke all on function public.set_dealership_opening_hours(jsonb)
  from public, anon, service_role;
grant execute on function public.set_dealership_opening_hours(jsonb) to authenticated;
comment on function public.set_dealership_opening_hours(jsonb) is
  'Active Owner/Admin replaces all weekly intervals atomically; [] means no opening intervals. Validation failure preserves the old schedule. Existing visits and their history are never changed.';
