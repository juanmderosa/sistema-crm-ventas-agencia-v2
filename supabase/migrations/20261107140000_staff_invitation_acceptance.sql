-- Read-only eligibility at one transaction boundary, not acceptance evidence.
-- The trusted server must derive p_user_id from a verified provider session.
create function public.check_staff_invitation_acceptance(
  p_invitation_id uuid, p_user_id uuid, p_display_name text
)
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
  -- Match completion's namespace and lock order; no inviter re-authorization.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.staff_invitation_intents'));
  select * into invitation from public.staff_invitation_intents where id = p_invitation_id for share;
  select * into binding from public.staff_invitation_identity_bindings where invitation_id = p_invitation_id for share;
  if invitation.id is null or binding.user_id is distinct from p_user_id then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;

  -- Preserve completion's permanent exact retry, including the original name.
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
  -- No reservation survives the HTTP boundary: completion must revalidate.
  return p_user_id;
end;
$$;
revoke all on function public.check_staff_invitation_acceptance(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.check_staff_invitation_acceptance(uuid, uuid, text) to service_role;
comment on function public.check_staff_invitation_acceptance(uuid, uuid, text) is
  'Service-only read-only preflight for a session-verified invitee UUID/name before password update. No acceptance reservation, Auth writes or profile activation; complete_staff_invitation rechecks transactionally afterwards.';
