-- Initial Owner provisioning only. No table grants or existing policies change.
-- Both preflight and finalization fail closed; preflight is not a reservation.
create function public.bootstrap_initial_owner(
  p_email text,
  p_user_id uuid default null,
  p_display_name text default null,
  p_finalize boolean default false
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  intended auth.users%rowtype;
  matches integer;
begin
  if p_email is null or p_email <> lower(btrim(p_email))
     or length(p_email) > 254 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or p_finalize is null
     or (p_finalize and (p_user_id is null or p_display_name is null
         or btrim(p_display_name) = '' or length(p_display_name) > 200))
     or (not p_finalize and p_display_name is not null) then
    raise exception 'invalid bootstrap input' using errcode = '22023';
  end if;

  -- EXACT namespace used by protect_last_active_owner. Recheck after lock wait.
  perform pg_advisory_xact_lock(hashtext('public.profiles.last_active_owner'));
  if exists (select 1 from public.profiles where role = 'owner') then
    -- An inactive Owner is exceptional recovery, not an initial bootstrap.
    raise exception 'owner bootstrap is unavailable' using errcode = '23514';
  end if;

  select count(*) into matches from auth.users
  where lower(email) = p_email or id = p_user_id;
  if matches > 1 then
    raise exception 'conflicting bootstrap identity' using errcode = '23514';
  end if;
  if matches = 0 then
    if p_finalize then
      raise exception 'bootstrap identity is missing' using errcode = '23514';
    end if;
    return 'missing';
  end if;

  -- Prevent concurrent Auth changes until finalization commits.
  select * into intended from auth.users
  where lower(email) = p_email or id = p_user_id for update;
  if intended.email is distinct from p_email
     or (p_user_id is not null and intended.id <> p_user_id)
     or intended.email_confirmed_at is null
     or coalesce(intended.encrypted_password, '') = ''
     or coalesce(intended.email_change, '') <> ''
     or intended.deleted_at is not null
     or coalesce(intended.is_anonymous, false)
     or coalesce(intended.is_sso_user, false)
     or intended.banned_until > clock_timestamp()
     or exists (select 1 from public.profiles where id = intended.id) then
    raise exception 'conflicting bootstrap identity' using errcode = '23514';
  end if;

  -- Lock identity rows as well, and reject linked/non-email/ambiguous accounts.
  perform 1 from auth.identities where user_id = intended.id for update;
  if (select count(*) from auth.identities where user_id = intended.id) <> 1
     or not exists (
       select 1 from auth.identities where user_id = intended.id
         and provider = 'email' and identity_data ->> 'email' = p_email
     ) then
    raise exception 'conflicting bootstrap identity' using errcode = '23514';
  end if;

  if not p_finalize then return 'auth_only'; end if;
  insert into public.profiles(id, role, display_name, is_active)
  values (intended.id, 'owner', btrim(p_display_name), true);
  return 'created';
end;
$$;

revoke all on function public.bootstrap_initial_owner(text, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.bootstrap_initial_owner(text, uuid, text, boolean)
  to service_role;
comment on function public.bootstrap_initial_owner(text, uuid, text, boolean) is
  'Trusted initial Owner bootstrap only: service-only bounded preflight/finalization, exact verified email identity, absent profile, no existing Owner, shared last-Owner advisory lock. Never edits Auth or existing profiles.';
