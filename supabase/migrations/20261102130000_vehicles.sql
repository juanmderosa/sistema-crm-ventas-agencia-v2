create type public.vehicle_publication_status as enum ('draft', 'published');
create type public.vehicle_availability_status as enum ('available', 'reserved', 'sold');

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  brand text not null,
  model text not null,
  version text,
  year smallint not null,
  mileage_km integer not null default 0,
  publication_status public.vehicle_publication_status not null default 'draft',
  availability_status public.vehicle_availability_status not null default 'available',
  created_by uuid references public.profiles (id) on delete restrict,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vehicles_brand_not_blank check (btrim(brand) <> ''),
  constraint vehicles_model_not_blank check (btrim(model) <> ''),
  constraint vehicles_year_range check (year between 1900 and 2100),
  constraint vehicles_mileage_not_negative check (mileage_km >= 0)
);

comment on table public.vehicles is
  'Inventory. Draft and deleted vehicles are never public. Sellers read all rows; only Owner/Admin mutate them. Pricing and image columns are added with their own approved rules.';

create trigger vehicles_set_updated_at
before update on public.vehicles
for each row execute function public.set_updated_at();

alter table public.vehicles enable row level security;

create policy vehicles_select_public_or_staff
on public.vehicles
for select
to anon, authenticated
using (
  (publication_status = 'published' and deleted_at is null)
  or public.is_active_staff()
);

create policy vehicles_insert_by_admin
on public.vehicles
for insert
to authenticated
with check (public.is_owner_or_admin());

create policy vehicles_update_by_admin
on public.vehicles
for update
to authenticated
using (public.is_owner_or_admin())
with check (public.is_owner_or_admin());

grant select on public.vehicles to anon, authenticated;
grant insert, update on public.vehicles to authenticated;

create index vehicles_public_catalog_idx
on public.vehicles (publication_status, availability_status)
where deleted_at is null;
