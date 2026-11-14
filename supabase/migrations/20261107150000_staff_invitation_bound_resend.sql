-- Distinct action, same global request identity; legacy input domain stays closed.
alter table public.staff_invitation_requests
  drop constraint staff_invitation_requests_action_check;
alter table public.staff_invitation_requests
  add constraint staff_invitation_requests_action_check
  check (action in ('create', 'resend', 'revoke', 'bound_resend'));

create function public.prepare_bound_staff_invitation_resend(
  p_request_id uuid, p_invitation_id uuid, p_actor_id uuid
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  invitation public.staff_invitation_intents%rowtype;
  previous public.staff_invitation_requests%rowtype;
  binding public.staff_invitation_identity_bindings%rowtype;
  verified jsonb;
begin
  if p_request_id is null or p_invitation_id is null or p_actor_id is null then
    raise exception 'Datos de invitación inválidos.' using errcode = '22023';
  end if;
  -- Match management/prepare order. Current actor authority precedes disclosure.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('public.staff_invitation_intents'));
  select * into actor from public.profiles where id = p_actor_id for share;
  if not found or not actor.is_active or actor.role not in ('owner', 'admin') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;
  select * into invitation from public.staff_invitation_intents where id = p_invitation_id for share;
  if invitation.role = 'owner' or (invitation.role = 'admin' and actor.role <> 'owner') then
    raise exception 'No tiene permiso para gestionar esta invitación.' using errcode = '42501';
  end if;
  select * into previous from public.staff_invitation_requests where id = p_request_id;
  if previous.id is not null and (previous.invitation_id <> p_invitation_id
     or previous.actor_id <> p_actor_id or previous.action <> 'bound_resend') then
    raise exception 'El identificador de solicitud ya tiene otros datos.' using errcode = '23514';
  end if;
  if invitation.id is null then
    raise exception 'La invitación no existe.' using errcode = '23514';
  end if;
  if invitation.revoked_at is not null then
    raise exception 'La invitación fue revocada. Cree una nueva invitación.' using errcode = '23514';
  end if;
  select * into binding from public.staff_invitation_identity_bindings
    where invitation_id = p_invitation_id for share;
  -- Never call the reserving helper without an existing complete binding.
  if binding.user_id is null or binding.provenance is null or exists (
    select 1 from public.staff_invitation_completions where invitation_id = p_invitation_id
  ) then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;
  verified := public.prepare_staff_invitation_identity(p_invitation_id, p_actor_id, binding.provenance);
  if verified ->> 'user_id' is distinct from binding.user_id::text
     or verified ->> 'candidate_user_id' is distinct from binding.user_id::text then
    raise exception 'La identidad de la invitación requiere verificación.' using errcode = '23514';
  end if;
  -- Revalidation above also applies to retries. The helper's canonical payload
  -- contains no confirmation timestamp, delivery status or first/retry flag.
  if previous.id is null then
    insert into public.staff_invitation_requests(id, invitation_id, actor_id, action)
    values (p_request_id, p_invitation_id, p_actor_id, 'bound_resend');
  end if;
  return verified;
end;
$$;
revoke all on function public.prepare_bound_staff_invitation_resend(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.prepare_bound_staff_invitation_resend(uuid, uuid, uuid) to service_role;
comment on function public.prepare_bound_staff_invitation_resend(uuid, uuid, uuid) is
  'Trusted-server-only bound pending resend authorization. Derive actor from verified context; response is private, not permission to create an identity or proof of email delivery. No Auth writes, role changes or activation.';
