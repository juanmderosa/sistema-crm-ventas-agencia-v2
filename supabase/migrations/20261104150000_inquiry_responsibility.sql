-- Prospective observation only. No inference from current assignee or incomplete
-- legacy assignment history; readers must respect complete_from_creation.
create table public.inquiry_responsibility_tracking (
  inquiry_id uuid primary key references public.inquiries(id) on delete restrict,
  complete_from_creation boolean not null
);
create table public.inquiry_first_responsibilities (
  inquiry_id uuid not null references public.inquiry_responsibility_tracking(inquiry_id) on delete restrict,
  responsible_id uuid not null references public.profiles(id) on delete restrict,
  first_observed_at timestamptz not null,
  primary key(inquiry_id,responsible_id)
);
alter table public.inquiry_responsibility_tracking enable row level security;
alter table public.inquiry_first_responsibilities enable row level security;
revoke all on public.inquiry_responsibility_tracking,public.inquiry_first_responsibilities
  from public,anon,authenticated,service_role;

create function public.capture_inquiry_responsibility()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op='UPDATE' and new.assignee_id is not distinct from old.assignee_id then
    return new;
  end if;
  -- The INSERT/UPDATE already owns this inquiry's row. No new business-row
  -- lock order or reassignment authorization is introduced by observation.
  insert into public.inquiry_responsibility_tracking(inquiry_id,complete_from_creation)
    values(new.id,tg_op='INSERT') on conflict(inquiry_id) do nothing;
  if new.assignee_id is not null then
    insert into public.inquiry_first_responsibilities(inquiry_id,responsible_id,first_observed_at)
      values(new.id,new.assignee_id,pg_catalog.clock_timestamp())
      on conflict(inquiry_id,responsible_id) do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.capture_inquiry_responsibility()
  from public,anon,authenticated,service_role;
create trigger inquiries_capture_responsibility
after insert or update of assignee_id on public.inquiries
for each row execute function public.capture_inquiry_responsibility();

comment on table public.inquiry_responsibility_tracking is
  'Private prospective coverage. TRUE only for inquiries inserted with tracking active, including initially unassigned inquiries. Missing or FALSE is incomplete historical first-responsibility evidence; no legacy backfill.';
comment on table public.inquiry_first_responsibilities is
  'Private first observed assignment per inquiry/person. Return assignments do not advance time or add counts. first_observed_at is historical first assignment only when inquiry coverage is complete_from_creation. Not a performed activity; staff counts are nonadditive.';
