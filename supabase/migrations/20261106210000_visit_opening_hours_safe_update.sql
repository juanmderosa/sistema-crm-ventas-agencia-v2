-- Preserve opening-hours replacement semantics while satisfying HTTP safe-update checks.
create or replace function public.set_dealership_opening_hours(p_intervals jsonb)
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
  delete from public.dealership_opening_hours where weekday between 0 and 6;
  insert into public.dealership_opening_hours(weekday, opens_at, closes_at)
    select x.weekday, x.opens_at, x.closes_at
    from pg_catalog.jsonb_to_recordset(p_intervals)
      as x(weekday integer, opens_at time without time zone, closes_at time without time zone);
end;
$$;
