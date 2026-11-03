-- Controlled additions only: no generic inquiry or interest mutation grants.
create function public.add_inquiry_interest(p_inquiry_id uuid, p_vehicle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_vehicle public.vehicles%rowtype;
  selected_inquiry public.inquiries%rowtype;
begin
  -- Match submit_inquiry's vehicle-before-profile ordering. FOR SHARE, not
  -- KEY SHARE, also blocks non-key role/active updates until transaction end.
  select * into selected_vehicle from public.vehicles
  where id = p_vehicle_id for update;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'inquiry interest access denied' using errcode = '42501';
  end if;

  -- Serialize additions with closure/reassignment before authorizing ownership.
  select * into selected_inquiry from public.inquiries
  where id = p_inquiry_id for update;
  if not found or not (
    public.is_owner_or_admin()
    or (public.current_staff_role() = 'seller' and selected_inquiry.assignee_id = auth.uid())
  ) is true then
    raise exception 'inquiry interest access denied' using errcode = '42501';
  end if;
  if selected_inquiry.status not in ('new', 'contacted', 'following_up') then
    raise exception 'inquiry is not active' using errcode = '22023';
  end if;
  if selected_vehicle.id is null or selected_vehicle.deleted_at is not null
     or selected_vehicle.availability_status <> 'available' then
    raise exception 'vehicle must be Available and not deleted' using errcode = '22023';
  end if;

  -- Reuse the established composite identity; retries never update timestamps.
  insert into public.inquiry_interests (inquiry_id, vehicle_id)
  values (p_inquiry_id, p_vehicle_id)
  on conflict (inquiry_id, vehicle_id) do nothing;
  return '{"accepted":true}'::jsonb;
end;
$$;
revoke all on function public.add_inquiry_interest(uuid, uuid) from public, anon, authenticated;
grant execute on function public.add_inquiry_interest(uuid, uuid) to authenticated;

comment on function public.add_inquiry_interest(uuid, uuid) is
  'Active staff add Available non-deleted interests to active inquiries. Sellers require current ownership. READ COMMITTED callers; retries revalidate current authorization and availability.';
