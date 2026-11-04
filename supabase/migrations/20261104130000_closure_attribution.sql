-- No historical backfill: absence of a snapshot means unknown responsibility.
-- A present row with NULL responsibility means the inquiry was unassigned.
create table public.inquiry_closure_attribution (
  history_id uuid primary key references public.inquiry_status_history(id) on delete restrict,
  responsible_id uuid references public.profiles(id) on delete restrict
);
alter table public.inquiry_closure_attribution enable row level security;
revoke all on public.inquiry_closure_attribution from public, anon, authenticated, service_role;

create function public.capture_closure_attribution()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  responsible uuid;
begin
  if new.to_status = 'closed_without_sale' then
    -- Resolution already owns the inquiry UPDATE lock. The SHARE lock also
    -- serializes trusted inserts with reassignment; it does not lock profiles.
    select assignee_id into responsible from public.inquiries
      where id = new.inquiry_id for share;
    insert into public.inquiry_closure_attribution(history_id,responsible_id)
      values(new.id,responsible);
  end if;
  return new;
end;
$$;
revoke all on function public.capture_closure_attribution()
  from public, anon, authenticated, service_role;
create trigger inquiry_status_capture_closure
after insert on public.inquiry_status_history
for each row execute function public.capture_closure_attribution();

comment on table public.inquiry_closure_attribution is
  'Private prospective closure responsibility snapshots. No historical backfill: missing row is unknown; present NULL is known unassigned. Each repeated closure has its own history key. Reporting readers remain a separate slice.';
