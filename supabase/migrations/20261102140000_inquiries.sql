-- Private inquiry read model. Creation and mutation are separate controlled operations.
create type public.inquiry_status as enum (
  'new', 'contacted', 'following_up', 'sale_reported', 'closed_without_sale'
);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  normalized_phone text not null unique,
  display_name text not null check (btrim(display_name) <> ''),
  email text not null check (btrim(email) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Shape validation only; real phone parsing belongs at the application boundary.
  constraint contacts_phone_international check (normalized_phone ~ '^\+[1-9][0-9]{1,14}$')
);

create table public.inquiries (
  id uuid primary key default gen_random_uuid(),
  creation_sequence bigint generated always as identity unique,
  submission_id uuid not null unique,
  contact_id uuid not null references public.contacts (id) on delete restrict,
  originating_vehicle_id uuid not null references public.vehicles (id) on delete restrict,
  assignee_id uuid references public.profiles (id) on delete restrict,
  status public.inquiry_status not null default 'new',
  -- Preserve submitted data without overwriting a recognized contact's identity.
  submitted_name text not null check (btrim(submitted_name) <> ''),
  submitted_email text not null check (btrim(submitted_email) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.inquiry_interests (
  inquiry_id uuid not null references public.inquiries (id) on delete restrict,
  vehicle_id uuid not null references public.vehicles (id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (inquiry_id, vehicle_id)
);

comment on table public.contacts is
  'Normalized phone is a routing aid, never proof of identity. Private contact data is visible only to authorized staff.';
comment on table public.inquiries is
  'One originating vehicle and at most one current assignee. Null assignee means pending administrative assignment. A reported sale is not a confirmed vehicle sale.';
comment on table public.inquiry_interests is
  'Additional interests preserve one inquiry and do not change vehicle availability. Controlled mutation operations are added separately.';

create trigger contacts_set_updated_at
before update on public.contacts
for each row execute function public.set_updated_at();
create trigger inquiries_set_updated_at
before update on public.inquiries
for each row execute function public.set_updated_at();

create index inquiries_assignee_idx on public.inquiries (assignee_id);
create index inquiries_contact_continuity_idx
on public.inquiries (contact_id, created_at desc, creation_sequence desc)
where status in ('new', 'contacted', 'following_up');
create index inquiries_origin_idx on public.inquiries (originating_vehicle_id);
create index inquiry_interests_vehicle_idx on public.inquiry_interests (vehicle_id);

alter table public.contacts enable row level security;
alter table public.inquiries enable row level security;
alter table public.inquiry_interests enable row level security;

create policy inquiries_select_assigned_or_admin
on public.inquiries for select to authenticated
using (
  public.is_owner_or_admin()
  or (assignee_id = auth.uid() and public.is_active_staff())
);

-- Query inquiries under the caller's RLS: a shared contact never grants access
-- to another seller's inquiries. Inquiries do not query contacts in their policy.
create policy contacts_select_linked_or_admin
on public.contacts for select to authenticated
using (
  public.is_owner_or_admin()
  or exists (
    select 1 from public.inquiries i
    where i.contact_id = contacts.id
  )
);

create policy inquiry_interests_select_visible_inquiry
on public.inquiry_interests for select to authenticated
using (
  exists (
    select 1 from public.inquiries i
    where i.id = inquiry_interests.inquiry_id
  )
);

-- No direct mutation grants or policies, even for Owner/Admin. Future RPCs must
-- enforce workflow invariants, not rely on broad table updates.
revoke all on public.contacts, public.inquiries, public.inquiry_interests from anon, authenticated;
grant select on public.contacts, public.inquiries, public.inquiry_interests to authenticated;
grant select, insert, update on public.contacts, public.inquiries, public.inquiry_interests to service_role;
grant usage, select on sequence public.inquiries_creation_sequence_seq to service_role;
