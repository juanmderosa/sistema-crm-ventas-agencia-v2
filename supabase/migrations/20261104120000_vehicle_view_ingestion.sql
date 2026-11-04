-- Database-only ingestion. The future public server must establish successful
-- detail-page loading and filter known bots before invoking this operation.
create table public.vehicle_view_events (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  counted_at timestamptz not null
);
create index vehicle_view_events_vehicle_time_idx
  on public.vehicle_view_events(vehicle_id, counted_at);

-- Browser tokens are random opaque UUIDs, never contact or identity identifiers.
-- Events intentionally carry no token; only the private rolling window needs it.
create table public.vehicle_view_dedup (
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  browser_token uuid not null,
  last_counted_at timestamptz not null,
  primary key (vehicle_id, browser_token)
);
alter table public.vehicle_view_events enable row level security;
alter table public.vehicle_view_dedup enable row level security;
revoke all on public.vehicle_view_events, public.vehicle_view_dedup
  from public, anon, authenticated, service_role;

create function public.record_vehicle_view(p_vehicle_id uuid, p_browser_token uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  previous_count timestamptz;
  observed_at timestamptz;
begin
  if p_vehicle_id is null or p_browser_token is null then
    raise exception 'vehicle and browser token are required' using errcode = '22023';
  end if;

  -- Keep this namespace separate from commercial submission locks. Collisions
  -- only serialize unrelated pairs; equality is always checked using both UUIDs.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'vehicle-view:' || p_vehicle_id::text || ':' || p_browser_token::text, 0));

  -- Match public detail visibility, not inquiry eligibility: Sold is readable.
  -- Snapshot eligibility does not promise linearization with publication edits.
  -- No vehicle FOR UPDATE lock is added to the commercial lock graph.
  if not exists (
    select 1 from public.vehicles where id = p_vehicle_id
      and publication_status = 'published' and deleted_at is null and sale_enabled
  ) then
    raise exception 'vehicle is not publicly visible' using errcode = '22023';
  end if;

  select last_counted_at into previous_count from public.vehicle_view_dedup
    where vehicle_id = p_vehicle_id and browser_token = p_browser_token;
  -- now() would retain transaction-start time even after a concurrent writer
  -- commits. Sample wall time after serialization; use full timestamp precision.
  observed_at := pg_catalog.clock_timestamp();
  if previous_count is not null
      and observed_at - previous_count < interval '24 hours' then
    return false;
  end if;

  insert into public.vehicle_view_events(vehicle_id, counted_at)
    values (p_vehicle_id, observed_at);
  insert into public.vehicle_view_dedup(vehicle_id, browser_token, last_counted_at)
    values (p_vehicle_id, p_browser_token, observed_at)
    on conflict (vehicle_id, browser_token)
    do update set last_counted_at = excluded.last_counted_at;
  return true;
end;
$$;
revoke all on function public.record_vehicle_view(uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.record_vehicle_view(uuid, uuid) to service_role;

comment on function public.record_vehicle_view(uuid, uuid) is
  'Trusted-server ingestion only: true counts a view, false is a duplicate within rolling 24h. No caller timestamps, identity checks or page/UA claims. Public load capture and bot filtering are integration-pending.';
comment on table public.vehicle_view_events is
  'Counted public-detail views, not unique people. No browser token or staff attribution; metric readers are a separate reporting slice.';
comment on table public.vehicle_view_dedup is
  'Private last-counted timestamp per opaque browser UUID and vehicle; ignored duplicates never extend the window. No retention or cleanup policy is defined here.';
