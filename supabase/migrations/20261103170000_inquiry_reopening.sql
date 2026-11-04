create function public.reopen_inquiry(p_inquiry_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare inquiry public.inquiries%rowtype;
begin
  if not public.is_active_staff() then
    raise exception 'inquiry reopening access denied' using errcode='42501';
  end if;
  -- No inventory lock or write is needed: reopening never changes availability.
  -- Profile -> inquiry is the suffix of the existing shared lock order.
  perform 1 from public.profiles where id=auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'inquiry reopening access denied' using errcode='42501';
  end if;
  select * into inquiry from public.inquiries where id=p_inquiry_id for update;
  if not found or not (public.is_owner_or_admin() or inquiry.assignee_id=auth.uid()) is true then
    raise exception 'inquiry reopening access denied' using errcode='42501';
  end if;
  if inquiry.status='sale_reported' and not public.is_owner_or_admin() then
    raise exception 'inquiry reopening access denied' using errcode='42501';
  end if;
  if inquiry.status not in('sale_reported','closed_without_sale') then
    raise exception 'inquiry is not closed' using errcode='22023';
  end if;
  if exists(select 1 from public.sale_reviews where inquiry_id=p_inquiry_id and status='pending') then
    raise exception 'resolve the pending sale review before reopening the inquiry' using errcode='22023';
  end if;
  insert into public.inquiry_status_history(inquiry_id,from_status,to_status,actor_id)
  values(p_inquiry_id,inquiry.status,'following_up',auth.uid());
  update public.inquiries set status='following_up' where id=p_inquiry_id;
  return pg_catalog.jsonb_build_object('inquiry_id',p_inquiry_id,'status','following_up');
end $$;
revoke all on function public.reopen_inquiry(uuid) from public,anon,authenticated;
grant execute on function public.reopen_inquiry(uuid) to authenticated;
comment on function public.reopen_inquiry(uuid) is
  'Active sellers reopen their own closed-without-sale inquiries. Active Owner/Admin also reopen reported/confirmed sales after review resolution. Reopening returns to follow-up and appends history; it never changes inventory, reservations or confirmed sales.';
