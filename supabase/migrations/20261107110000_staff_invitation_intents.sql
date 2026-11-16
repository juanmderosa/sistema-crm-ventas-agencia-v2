-- Intent bookkeeping only: no Auth creation, identity adoption or activation.
create table public.staff_invitation_intents (
  id uuid primary key,
  email text not null check (
    email = lower(btrim(email)) and length(email) <= 254
    and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  role public.user_role not null check (role in ('admin', 'seller')),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create unique index staff_invitation_one_pending_email
  on public.staff_invitation_intents(email) where revoked_at is null;

-- Immutable successful commands provide exact retry matching and action history.
create table public.staff_invitation_requests (
  id uuid primary key,
  invitation_id uuid not null references public.staff_invitation_intents(id) on delete restrict,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  action text not null check (action in ('create', 'resend', 'revoke')),
  created_at timestamptz not null default now()
);
alter table public.staff_invitation_intents enable row level security;
alter table public.staff_invitation_requests enable row level security;
revoke all on public.staff_invitation_intents, public.staff_invitation_requests
  from public, anon, authenticated, service_role;

create function public.manage_staff_invitation_intent(
  p_request_id uuid,
  p_invitation_id uuid,
  p_actor_id uuid,
  p_action text,
  p_email text,
  p_role public.user_role
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  invitation public.staff_invitation_intents%rowtype;
  previous public.staff_invitation_requests%rowtype;
begin
  if p_request_id is null or p_invitation_id is null or p_actor_id is null
     or p_action is null or p_action not in ('create', 'resend', 'revoke')
     or p_email is null or p_email <> lower(btrim(p_email))
     or length(p_email) > 254
     or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or p_role is null then
    raise exception 'Datos de invitación inválidos.' using errcode = '22023';
  end if;

  -- One namespace serializes all new intent/request state, including cross-email
  -- ID collisions. Never acquire the existing last-Owner lock: no profiles change.
  perform pg_advisory_xact_lock(hashtext('public.staff_invitation_intents'));
  -- Fresh row after the advisory wait; SHARE also prevents role/deactivation
  -- changes until this transaction finishes. Do not trust JWT role claims.
  select * into actor from public.profiles where id = p_actor_id for share;
  if not found or not actor.is_active or actor.role not in ('owner', 'admin')
     or p_role = 'owner' or (p_role = 'admin' and actor.role <> 'owner') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;

  select * into invitation from public.staff_invitation_intents where id = p_invitation_id;
  select * into previous from public.staff_invitation_requests where id = p_request_id;
  if previous.id is not null and (
    previous.invitation_id <> p_invitation_id or previous.actor_id <> p_actor_id
    or previous.action <> p_action
  ) then
    raise exception 'El identificador de solicitud ya tiene otros datos.' using errcode = '23514';
  end if;
  if invitation.id is not null and
     (invitation.email <> p_email or invitation.role <> p_role) then
    raise exception 'La invitación no coincide con los datos indicados.' using errcode = '23514';
  end if;
  if invitation.id is null and p_action <> 'create' then
    raise exception 'La invitación no existe.' using errcode = '23514';
  end if;
  if invitation.revoked_at is not null and
     not (p_action = 'revoke' and previous.id is not null) then
    raise exception 'La invitación fue revocada. Cree una nueva invitación.' using errcode = '23514';
  end if;

  -- An intent is not evidence that an existing Auth user belongs to this flow.
  -- Until verified binding exists, all Auth-only partial states fail closed.
  -- Revocation remains possible even if Auth has since created an identity.
  if p_action <> 'revoke' and (
    exists (select 1 from auth.users where lower(email) = p_email)
    or exists (select 1 from auth.identities where lower(identity_data ->> 'email') = p_email)
  ) then
    raise exception 'La identidad existente requiere verificación antes de continuar.' using errcode = '23514';
  end if;
  if previous.id is not null then return p_invitation_id; end if;
  if p_action = 'create' then
    if invitation.id is not null or exists (
      select 1 from public.staff_invitation_intents where email = p_email and revoked_at is null
    ) then
      raise exception 'Ya existe una invitación pendiente. Use el reenvío explícito.' using errcode = '23514';
    end if;
    insert into public.staff_invitation_intents(id, email, role, created_by)
    values (p_invitation_id, p_email, p_role, p_actor_id);
  elsif p_action = 'revoke' then
    update public.staff_invitation_intents set revoked_at = clock_timestamp()
    where id = p_invitation_id;
  end if;
  insert into public.staff_invitation_requests(id, invitation_id, actor_id, action)
  values (p_request_id, p_invitation_id, p_actor_id, p_action);
  return p_invitation_id;
end;
$$;
revoke all on function public.manage_staff_invitation_intent(uuid, uuid, uuid, text, text, public.user_role)
  from public, anon, authenticated;
grant execute on function public.manage_staff_invitation_intent(uuid, uuid, uuid, text, text, public.user_role)
  to service_role;
comment on function public.manage_staff_invitation_intent(uuid, uuid, uuid, text, text, public.user_role) is
  'Trusted-server-only intent lifecycle. Actor must come from verified Auth, never submitted identity. No mail, Auth binding, profile creation or activation; Auth-only states require later verified orchestration.';
