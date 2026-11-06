-- Preserve the existing direct profile-update interface, but enforce the
-- Owner/Admin management boundary on both existing and resulting rows.
drop policy profiles_update_by_admin on public.profiles;
create policy profiles_update_by_admin on public.profiles
for update to authenticated
using (
  public.current_staff_role() = 'owner'
  or (public.current_staff_role() = 'admin' and (role = 'seller' or id = auth.uid()))
)
with check (
  public.current_staff_role() = 'owner'
  or (public.current_staff_role() = 'admin' and (
    (id <> auth.uid() and role = 'seller')
    or (id = auth.uid() and role = 'admin' and is_active)
  ))
);

-- Allow the existing self display-name update, not self role/deactivation.
-- Identity links and audit timestamps are never caller-managed columns.
revoke update on public.profiles from authenticated;
grant update (role, display_name, is_active) on public.profiles to authenticated;
comment on policy profiles_update_by_admin on public.profiles is
  'Active Owner manages staff; active Admin manages Seller targets without elevation and may rename self while remaining active Admin. Existing/resulting roles are checked. Existing statement-snapshot authorization and last-active-Owner trigger are preserved.';
