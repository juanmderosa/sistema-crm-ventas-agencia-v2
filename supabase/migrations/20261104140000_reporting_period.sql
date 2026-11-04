-- Internal pure calendar helper. Future authorized readers call it as owner;
-- it reads no business tables and creates no application-facing RPC grant.
create function public.reporting_period(p_kind text,p_start date,p_end date default null)
returns table(local_start date,local_end date,start_at timestamptz,end_at timestamptz,timezone_name text)
language plpgsql stable security invoker set search_path = '' as $$
declare
  first_day timestamp;
  next_day timestamp;
begin
  if p_kind is null or p_kind not in ('month','quarter','semester','year','custom') then
    raise exception 'reporting period must be month, quarter, semester, year or custom' using errcode='22023';
  end if;
  if p_start is null or not pg_catalog.isfinite(p_start) then
    raise exception 'a finite reporting start or anchor date is required' using errcode='22023';
  end if;
  if p_kind='custom' then
    if p_end is null or not pg_catalog.isfinite(p_end) or p_end<p_start then
      raise exception 'custom reporting end must be finite and not precede start' using errcode='22023';
    end if;
    local_start:=p_start;
    local_end:=p_end;
    first_day:=local_start::timestamp;
    next_day:=(local_end+1)::timestamp;
  else
    if p_end is not null then
      raise exception 'calendar reporting periods do not accept an end date' using errcode='22023';
    end if;
    if p_kind='semester' then
      first_day:=pg_catalog.date_trunc('year',p_start::timestamp)
        + case when extract(month from p_start)>6 then interval '6 months' else interval '0 months' end;
      next_day:=first_day+interval '6 months';
    else
      first_day:=pg_catalog.date_trunc(p_kind,p_start::timestamp);
      next_day:=first_day+case p_kind when 'month' then interval '1 month'
        when 'quarter' then interval '3 months' else interval '1 year' end;
    end if;
    local_start:=first_day::date;
    local_end:=next_day::date-1;
  end if;
  timezone_name:='America/Argentina/Buenos_Aires';
  -- Convert both local midnights separately, never assume a fixed UTC offset
  -- or multiply inclusive days by 24h across historical timezone changes.
  start_at:=first_day at time zone timezone_name;
  end_at:=next_day at time zone timezone_name;
  return next;
exception when datetime_field_overflow or numeric_value_out_of_range then
  raise exception 'reporting dates exceed supported timestamp boundaries' using errcode='22023';
end;
$$;
revoke all on function public.reporting_period(text,date,date) from public,anon,authenticated,service_role;
comment on function public.reporting_period(text,date,date) is
  'Internal calendar normalizer: month/quarter/semester/year containing p_start, or inclusive custom p_start/p_end. Returns local dates and [start_at,end_at) Buenos Aires boundaries. No business-data access or application execution grants.';
