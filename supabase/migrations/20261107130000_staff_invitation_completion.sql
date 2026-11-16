-- This private primitive trusts the server to verify the acceptance session and
-- successful password update before calling it. It is not an onboarding API.
create table public.staff_invitation_completions (
  invitation_id uuid primary key references public.staff_invitation_intents(id) on delete restrict,
  user_id uuid not null unique references auth.users(id) on delete restrict,
  initial_display_name text not null check (btrim(initial_display_name) <> ''),
  completed_at timestamptz not null default clock_timestamp()
);
alter table public.staff_invitation_completions enable row level security;
revoke all on public.staff_invitation_completions from public, anon, authenticated, service_role;

create function public.complete_staff_invitation(p_invitation_id uuid, p_user_id uuid, p_display_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  invitation public.staff_invitation_intents%rowtype;
  binding public.staff_invitation_identity_bindings%rowtype;
  completed public.staff_invitation_completions%rowtype;
  candidate auth.users%rowtype;
  identity_count integer;
  email_identity auth.identities%rowtype;
begin
  if p_invitation_id is null or p_user_id is null or p_display_name is null
     or pg_catalog.btrim(p_display_name) = '' or pg_catalog.length(p_display_name) > 200 then
    raise exception 'Datos de finalización inválidos.' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.staff_invitation_intents'));
  select * into invitation from public.staff_invitation_intents where id = p_invitation_id for share;
  select * into binding from public.staff_invitation_identity_bindings where invitation_id = p_invitation_id for share;
  if invitation.id is null or binding.user_id is distinct from p_user_id then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;

  -- A completed retry is read-only: later profile changes must never be undone.
  select * into completed from public.staff_invitation_completions where invitation_id = p_invitation_id;
  if completed.invitation_id is not null then
    if completed.user_id <> p_user_id or completed.initial_display_name <> p_display_name then
      raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
    end if;
    return p_user_id;
  end if;
  if invitation.revoked_at is not null then
    raise exception 'La invitación fue revocada. Cree una nueva invitación.' using errcode = '23514';
  end if;

  perform u.id from auth.users u
  where pg_catalog.lower(u.email) = invitation.email
    or u.raw_app_meta_data ->> 'staff_invitation_id' = p_invitation_id::text
    or u.raw_app_meta_data ->> 'staff_invitation_provenance' = binding.provenance::text
    or u.id = p_user_id order by u.id for update;
  perform i.id from auth.identities i
  where i.user_id = p_user_id or pg_catalog.lower(i.identity_data ->> 'email') = invitation.email
  order by i.id for share;
  select * into candidate from auth.users where id = p_user_id;
  if candidate.id is null or candidate.email is distinct from invitation.email
     or candidate.email_confirmed_at is null
     or candidate.raw_app_meta_data ->> 'staff_invitation_id' is distinct from p_invitation_id::text
     or candidate.raw_app_meta_data ->> 'staff_invitation_provenance' is distinct from binding.provenance::text
     or candidate.deleted_at is not null or candidate.banned_until > pg_catalog.clock_timestamp()
     or candidate.is_anonymous is true or candidate.is_sso_user is true
     or coalesce(candidate.email_change, '') <> ''
     or exists (select 1 from public.profiles where id = p_user_id)
     or exists (select 1 from auth.users u where u.id <> p_user_id and (
       pg_catalog.lower(u.email) = invitation.email
       or u.raw_app_meta_data ->> 'staff_invitation_id' = p_invitation_id::text
       or u.raw_app_meta_data ->> 'staff_invitation_provenance' = binding.provenance::text))
     or exists (select 1 from auth.identities i where i.user_id <> p_user_id
       and pg_catalog.lower(i.identity_data ->> 'email') = invitation.email) then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;
  select pg_catalog.count(*) into identity_count from auth.identities where user_id = p_user_id;
  select * into email_identity from auth.identities where user_id = p_user_id and provider = 'email';
  if identity_count <> 1 or email_identity.id is null
     or email_identity.provider_id is distinct from p_user_id::text
     or email_identity.identity_data ->> 'sub' is distinct from p_user_id::text
     or email_identity.identity_data ->> 'email' is distinct from invitation.email then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;

  insert into public.profiles(id, role, display_name, is_active)
  values (p_user_id, invitation.role, p_display_name, true);
  insert into public.staff_invitation_completions(invitation_id, user_id, initial_display_name)
  values (p_invitation_id, p_user_id, p_display_name);
  return p_user_id;
end;
$$;
revoke all on function public.complete_staff_invitation(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.complete_staff_invitation(uuid, uuid, text) to service_role;
