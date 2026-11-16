-- Pending identity correlation only. Auth is read/locked, never written here.
create table public.staff_invitation_identity_bindings (
  invitation_id uuid primary key references public.staff_invitation_intents(id) on delete restrict,
  provenance uuid not null unique,
  user_id uuid unique references auth.users(id) on delete restrict,
  bound_at timestamptz,
  constraint staff_invitation_binding_complete check ((user_id is null) = (bound_at is null))
);
alter table public.staff_invitation_identity_bindings enable row level security;
revoke all on public.staff_invitation_identity_bindings from public, anon, authenticated, service_role;

create function public.prepare_staff_invitation_identity(
  p_invitation_id uuid, p_actor_id uuid, p_provenance uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  invitation public.staff_invitation_intents%rowtype;
  binding public.staff_invitation_identity_bindings%rowtype;
  candidates uuid[];
  candidate auth.users%rowtype;
  identity_count integer;
  email_identity auth.identities%rowtype;
begin
  if p_invitation_id is null or p_actor_id is null or p_provenance is null then
    raise exception 'Datos de vinculación inválidos.' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.staff_invitation_intents'));
  select * into actor from public.profiles where id = p_actor_id for share;
  if not found or not actor.is_active or actor.role not in ('owner', 'admin') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;
  select * into invitation from public.staff_invitation_intents where id = p_invitation_id for share;
  if invitation.role = 'owner' or (invitation.role = 'admin' and actor.role <> 'owner') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;
  if invitation.id is null then
    raise exception 'La invitación no existe.' using errcode = '23514';
  end if;
  if invitation.revoked_at is not null then
    raise exception 'La invitación fue revocada. Cree una nueva invitación.' using errcode = '23514';
  end if;

  select * into binding from public.staff_invitation_identity_bindings where invitation_id = p_invitation_id;
  if (binding.invitation_id is not null and binding.provenance <> p_provenance)
     or exists (select 1 from public.staff_invitation_identity_bindings
       where provenance = p_provenance and invitation_id <> p_invitation_id) then
    raise exception 'La procedencia no coincide con la invitación.' using errcode = '23514';
  end if;

  -- Lock every currently related Auth user in UUID order. Either marker alone
  -- identifies a conflict to inspect, never sufficient evidence for adoption.
  -- UPDATE row locks also exclude FK-backed profile/identity insertion for these
  -- users until commit. They do not write Auth or reserve an absent Auth email.
  select pg_catalog.array_agg(locked.id) into candidates from (
    select u.id from auth.users u
    where pg_catalog.lower(u.email) = invitation.email
       or u.raw_app_meta_data ->> 'staff_invitation_id' = p_invitation_id::text
       or u.raw_app_meta_data ->> 'staff_invitation_provenance' = p_provenance::text
       or u.id = binding.user_id
    order by u.id for update
  ) locked;
  if coalesce(pg_catalog.cardinality(candidates), 0) > 1 then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;

  -- Lock existing identity rows before a fresh validation read after any wait.
  perform i.id from auth.identities i
  where i.user_id = candidates[1] or pg_catalog.lower(i.identity_data ->> 'email') = invitation.email
  order by i.id for share;
  if candidates[1] is null then
    if binding.user_id is not null or exists (
      select 1 from auth.identities where pg_catalog.lower(identity_data ->> 'email') = invitation.email
    ) then
      raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
    end if;
  else
    select * into candidate from auth.users where id = candidates[1];
    if binding.invitation_id is null
       or candidate.email is distinct from invitation.email
       or candidate.raw_app_meta_data ->> 'staff_invitation_id' is distinct from p_invitation_id::text
       or candidate.raw_app_meta_data ->> 'staff_invitation_provenance' is distinct from p_provenance::text
       or candidate.deleted_at is not null
       or candidate.banned_until > pg_catalog.clock_timestamp()
       or candidate.is_anonymous is true or candidate.is_sso_user is true
       or coalesce(candidate.email_change, '') <> ''
       or (binding.user_id is not null and binding.user_id <> candidate.id)
       or exists (select 1 from public.profiles where id = candidate.id)
       or exists (select 1 from public.staff_invitation_identity_bindings
         where user_id = candidate.id and invitation_id <> p_invitation_id)
       or exists (select 1 from auth.users u where u.id <> candidate.id and (
         pg_catalog.lower(u.email) = invitation.email
         or u.raw_app_meta_data ->> 'staff_invitation_id' = p_invitation_id::text
         or u.raw_app_meta_data ->> 'staff_invitation_provenance' = p_provenance::text))
       or exists (select 1 from auth.identities i where i.user_id <> candidate.id
         and pg_catalog.lower(i.identity_data ->> 'email') = invitation.email) then
      raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
    end if;
    select pg_catalog.count(*) into identity_count from auth.identities where user_id = candidate.id;
    select * into email_identity from auth.identities where user_id = candidate.id and provider = 'email';
    if identity_count <> 1 or email_identity.id is null
       or email_identity.provider_id is distinct from candidate.id::text
       or email_identity.identity_data ->> 'sub' is distinct from candidate.id::text
       or email_identity.identity_data ->> 'email' is distinct from invitation.email then
      raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
    end if;
  end if;

  -- Only this function reserves provenance. Bind reuses this verification path
  -- but must first establish that a reservation already exists.
  if binding.invitation_id is null then
    insert into public.staff_invitation_identity_bindings(invitation_id, provenance)
    values (p_invitation_id, p_provenance);
  end if;
  return pg_catalog.jsonb_build_object(
    'invitation_id', invitation.id, 'email', invitation.email, 'role', invitation.role,
    'provenance', p_provenance, 'user_id', binding.user_id, 'candidate_user_id', candidate.id);
end;
$$;
revoke all on function public.prepare_staff_invitation_identity(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.prepare_staff_invitation_identity(uuid, uuid, uuid) to service_role;

create function public.bind_staff_invitation_identity(
  p_invitation_id uuid, p_actor_id uuid, p_user_id uuid, p_provenance uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  invitation public.staff_invitation_intents%rowtype;
  binding public.staff_invitation_identity_bindings%rowtype;
  verified jsonb;
begin
  if p_invitation_id is null or p_actor_id is null or p_user_id is null or p_provenance is null then
    raise exception 'Datos de vinculación inválidos.' using errcode = '22023';
  end if;

  -- Same namespace/order as intent management and prepare; never an Owner lock.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.staff_invitation_intents'));
  select * into actor from public.profiles where id = p_actor_id for share;
  if not found or not actor.is_active or actor.role not in ('owner', 'admin') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;
  select * into invitation from public.staff_invitation_intents where id = p_invitation_id for share;
  if invitation.role = 'owner' or (invitation.role = 'admin' and actor.role <> 'owner') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;
  if invitation.id is null then
    raise exception 'La invitación no existe.' using errcode = '23514';
  end if;
  if invitation.revoked_at is not null then
    raise exception 'La invitación fue revocada. Cree una nueva invitación.' using errcode = '23514';
  end if;
  select * into binding from public.staff_invitation_identity_bindings where invitation_id = p_invitation_id;
  if binding.invitation_id is null then
    raise exception 'Prepare la identidad de la invitación antes de vincularla.' using errcode = '23514';
  end if;
  if binding.provenance <> p_provenance then
    raise exception 'La procedencia no coincide con la invitación.' using errcode = '23514';
  end if;
  if binding.user_id is not null and binding.user_id <> p_user_id then
    raise exception 'La identidad vinculada no coincide con la solicitud.' using errcode = '23514';
  end if;

  verified := public.prepare_staff_invitation_identity(p_invitation_id, p_actor_id, p_provenance);
  if verified ->> 'candidate_user_id' is distinct from p_user_id::text then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;
  if binding.user_id is null then
    update public.staff_invitation_identity_bindings
    set user_id = p_user_id, bound_at = pg_catalog.clock_timestamp()
    where invitation_id = p_invitation_id;
  end if;
  return p_user_id;
end;
$$;
revoke all on function public.bind_staff_invitation_identity(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.bind_staff_invitation_identity(uuid, uuid, uuid, uuid) to service_role;
comment on function public.prepare_staff_invitation_identity(uuid, uuid, uuid) is
  'Trusted server reserves creation provenance and privately recovers a verified pending Auth candidate. No adoption by email, Auth writes, mail, profile creation or activation.';
comment on function public.bind_staff_invitation_identity(uuid, uuid, uuid, uuid) is
  'Trusted server must re-read the exact Admin Auth UUID before binding reserved provenance. Immutable pending binding only; not acceptance, password or role authority.';
