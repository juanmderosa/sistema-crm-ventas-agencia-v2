-- Identity, staff roles and the Owner protection rules.
-- Authorization is enforced here, in the database, not in the UI.

create type public.user_role as enum ('owner', 'admin', 'seller');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete restrict,
  role public.user_role not null,
  display_name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_not_blank check (btrim(display_name) <> '')
);

comment on table public.profiles is
  'Staff account linked 1:1 to auth.users. Only the service role creates rows; Owner/Admin manage them through RLS.';

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

-- Helper predicates used by row level security policies.
-- They are SECURITY DEFINER so the policy check does not recurse into profiles RLS.
create function public.current_staff_role()
returns public.user_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = auth.uid() and p.is_active;
$$;

create function public.is_active_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p where p.id = auth.uid() and p.is_active
  );
$$;

create function public.is_owner_or_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_active
      and p.role in ('owner', 'admin')
  );
$$;

revoke execute on function public.current_staff_role() from public;
revoke execute on function public.is_active_staff() from public;
revoke execute on function public.is_owner_or_admin() from public;
grant execute on function public.current_staff_role() to authenticated, anon, service_role;
grant execute on function public.is_active_staff() to authenticated, anon, service_role;
grant execute on function public.is_owner_or_admin() to authenticated, anon, service_role;

alter table public.profiles enable row level security;

create policy profiles_select_own_or_admin
on public.profiles
for select
to authenticated
using (id = auth.uid() or public.is_owner_or_admin());

create policy profiles_update_by_admin
on public.profiles
for update
to authenticated
using (public.is_owner_or_admin())
with check (public.is_owner_or_admin());

-- No insert, delete or anon policies: only the service role owns account lifecycle
-- and the controlled bootstrap script. With auto_expose_new_tables disabled,
-- explicit grants are also required for the API roles.
grant select, update on public.profiles to authenticated;

-- The dealership must never lose its last active Owner, even under concurrent requests.
create function public.protect_last_active_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  remaining_owners integer;
begin
  perform pg_advisory_xact_lock(hashtext('public.profiles.last_active_owner'));

  if tg_op = 'DELETE' then
    if old.role = 'owner' and old.is_active then
      select count(*)::int into remaining_owners
      from public.profiles p
      where p.role = 'owner' and p.is_active and p.id <> old.id;

      if remaining_owners = 0 then
        raise exception 'the last active owner cannot be deleted'
          using errcode = '23514';
      end if;
    end if;
    return old;
  end if;

  if old.role = 'owner' and old.is_active
     and (new.role <> 'owner' or new.is_active = false) then
    select count(*)::int into remaining_owners
    from public.profiles p
    where p.role = 'owner' and p.is_active and p.id <> old.id;

    if remaining_owners = 0 then
      raise exception 'the last active owner cannot be demoted or deactivated'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create trigger profiles_protect_last_active_owner
before update or delete on public.profiles
for each row execute function public.protect_last_active_owner();
