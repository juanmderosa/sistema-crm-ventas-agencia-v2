-- Every contact update invalidates prior forms, including trusted direct updates.
alter table public.contacts add column revision bigint not null default 0
  check (revision >= 0);

create function public.increment_contact_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.revision := old.revision + 1;
  return new;
end;
$$;
revoke all on function public.increment_contact_revision() from public, anon, authenticated;
create trigger contacts_increment_revision before update on public.contacts
for each row execute function public.increment_contact_revision();
-- The existing contacts_set_updated_at trigger remains the timestamp authority.

create function public.update_contact_details(
  p_contact_id uuid, p_expected_revision bigint, p_name text, p_email text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  result bigint;
  old_phone text;
begin
  if not public.is_active_staff() then
    raise exception 'contact edit not permitted' using errcode = '42501';
  end if;
  select normalized_phone into old_phone from public.contacts where id = p_contact_id;
  if not found then
    raise exception 'contact edit not permitted' using errcode = '42501';
  end if;
  -- Match phone correction/submission: acquire the routing key before any row
  -- locks. A later submission in this transaction can then reuse the same key.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('inquiry-contact:' || old_phone, 0)
  );
  -- Hold the actor against deactivation/role changes until this operation commits.
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_active_staff() then
    raise exception 'contact edit not permitted' using errcode = '42501';
  end if;
  if not public.is_owner_or_admin() then
    -- Lock a currently linked inquiry against reassignment. Closed inquiries count.
    perform 1 from public.inquiries
    where contact_id = p_contact_id and assignee_id = auth.uid()
    order by id limit 1 for share;
    if not found then
      raise exception 'contact edit not permitted' using errcode = '42501';
    end if;
  end if;
  perform 1 from public.contacts where id = p_contact_id for update;
  if not found then
    raise exception 'contact edit not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.contacts
                 where id = p_contact_id and normalized_phone = old_phone) then
    raise exception 'contact changed; reload the contact and retry' using errcode = '40001';
  end if;
  if p_expected_revision is null or p_expected_revision < 0
     or p_name is null or btrim(p_name) = ''
     or p_email is null or btrim(p_email) = '' then
    raise exception 'invalid contact details input' using errcode = '22023';
  end if;
  update public.contacts set display_name = p_name, email = p_email
  where id = p_contact_id and revision = p_expected_revision
  returning revision into result;
  if not found then
    raise exception 'contact changed; reload the contact and retry' using errcode = '40001';
  end if;
  return result;
end;
$$;

create function public.update_contact_phone(
  p_contact_id uuid, p_expected_revision bigint, p_phone text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_phone text;
  lock_key bigint;
  result bigint;
begin
  -- Initial authorization reveals no contact data; rechecked under actor lock below.
  if not public.is_owner_or_admin() then
    raise exception 'contact phone edit not permitted' using errcode = '42501';
  end if;
  if p_contact_id is null or p_expected_revision is null or p_expected_revision < 0
     or p_phone is null or p_phone !~ '^\+[1-9][0-9]{1,14}$' then
    raise exception 'invalid contact phone input' using errcode = '22023';
  end if;
  select normalized_phone into old_phone from public.contacts where id = p_contact_id;
  if not found then
    raise exception 'contact phone edit not permitted' using errcode = '42501';
  end if;
  -- Same namespace as submit_inquiry. Sort actual keys, including hash collisions.
  -- Advisory locks precede profile/contact row locks: submission locks profiles
  -- after its phone lock, so acquiring the actor first could deadlock with it.
  for lock_key in
    select distinct pg_catalog.hashtextextended('inquiry-contact:' || phone, 0) as key
    from unnest(array[old_phone, p_phone]) phone order by key
  loop
    perform pg_catalog.pg_advisory_xact_lock(lock_key);
  end loop;
  perform 1 from public.profiles where id = auth.uid() for share;
  if not public.is_owner_or_admin() then
    raise exception 'contact phone edit not permitted' using errcode = '42501';
  end if;
  perform 1 from public.contacts where id = p_contact_id for update;
  -- A changed old phone while waiting invalidates the expected revision. Never
  -- follow it by acquiring another advisory lock out of the deterministic order.
  if not exists (select 1 from public.contacts
                 where id = p_contact_id and revision = p_expected_revision
                   and normalized_phone = old_phone) then
    raise exception 'contact changed; reload the contact and retry' using errcode = '40001';
  end if;
  if exists (select 1 from public.contacts where normalized_phone = p_phone and id <> p_contact_id) then
    raise exception 'phone already belongs to another contact; no contacts were merged' using errcode = '23505';
  end if;
  begin
    update public.contacts set normalized_phone = p_phone
    where id = p_contact_id and revision = p_expected_revision
    returning revision into result;
  exception when unique_violation then
    raise exception 'phone already belongs to another contact; no contacts were merged' using errcode = '23505';
  end;
  if not found then
    raise exception 'contact changed; reload the contact and retry' using errcode = '40001';
  end if;
  return result;
end;
$$;

revoke all on function public.update_contact_details(uuid,bigint,text,text) from public, anon;
revoke all on function public.update_contact_phone(uuid,bigint,text) from public, anon;
grant execute on function public.update_contact_details(uuid,bigint,text,text) to authenticated;
grant execute on function public.update_contact_phone(uuid,bigint,text) to authenticated;

comment on column public.contacts.revision is
  'Optimistic edit version. Every successful UPDATE increments once; clients must reload after a conflict.';
