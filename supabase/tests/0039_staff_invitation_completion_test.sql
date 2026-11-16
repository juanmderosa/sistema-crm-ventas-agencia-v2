-- The completion operation is private to trusted server orchestration.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select has_function(
  'public', 'complete_staff_invitation', array['uuid', 'uuid', 'text'],
  'Invitation completion exposes the expected trusted-server operation'
);

-- Synthetic fixtures live only inside this rolled-back transaction.
insert into auth.users(id, email) values
  ('00000000-0000-0000-0000-000000003901', 'completion-owner@example.invalid'),
  ('00000000-0000-0000-0000-000000003902', 'completion-user@example.invalid'),
  ('00000000-0000-0000-0000-000000003903', 'completion-other@example.invalid');
insert into public.profiles(id, role, display_name, is_active)
values ('00000000-0000-0000-0000-000000003901', 'owner', 'Owner', true);
insert into public.staff_invitation_intents(id, email, role, created_by)
values ('00000000-0000-0000-0000-000000003911', 'completion-user@example.invalid',
        'seller', '00000000-0000-0000-0000-000000003901');
insert into public.staff_invitation_identity_bindings(invitation_id, provenance, user_id, bound_at)
values ('00000000-0000-0000-0000-000000003911', '00000000-0000-0000-0000-000000003921',
        '00000000-0000-0000-0000-000000003902', now());
update auth.users set email_confirmed_at = now(), raw_app_meta_data = jsonb_build_object(
  'staff_invitation_id', '00000000-0000-0000-0000-000000003911',
  'staff_invitation_provenance', '00000000-0000-0000-0000-000000003921')
where id = '00000000-0000-0000-0000-000000003902';
insert into auth.identities(id, user_id, provider_id, provider, identity_data)
values ('00000000-0000-0000-0000-000000003931', '00000000-0000-0000-0000-000000003902',
  '00000000-0000-0000-0000-000000003902', 'email', jsonb_build_object(
    'sub', '00000000-0000-0000-0000-000000003902', 'email', 'completion-user@example.invalid'));

select ok(not has_function_privilege('anon', 'public.complete_staff_invitation(uuid,uuid,text)', 'EXECUTE'),
  'Anonymous callers cannot complete invitations');
select ok(not has_function_privilege('authenticated', 'public.complete_staff_invitation(uuid,uuid,text)', 'EXECUTE'),
  'Authenticated callers cannot complete invitations directly');
select ok(has_function_privilege('service_role', 'public.complete_staff_invitation(uuid,uuid,text)', 'EXECUTE'),
  'Trusted server may complete invitations');

set local role service_role;
select throws_ok(
  $$select public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
    '00000000-0000-0000-0000-000000003903', 'Wrong identity')$$,
  '23514', 'La identidad de la invitación requiere verificación.',
  'Completion rejects a different Auth identity'
);
select throws_ok(
  $$select public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
    '00000000-0000-0000-0000-000000003902', '   ')$$,
  '22023', 'Datos de finalización inválidos.', 'Completion rejects a blank name'
);
reset role;
select is((select count(*)::integer from public.profiles where id = '00000000-0000-0000-0000-000000003902'),
  0, 'Rejected requests do not create an operational profile');
update public.staff_invitation_intents set revoked_at = now()
where id = '00000000-0000-0000-0000-000000003911';
set local role service_role;
select throws_ok(
  $$select public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
    '00000000-0000-0000-0000-000000003902', 'Example Person')$$,
  '23514', 'La invitación fue revocada. Cree una nueva invitación.',
  'A revoked invitation cannot create a profile'
);
reset role;
update public.staff_invitation_intents set revoked_at = null
where id = '00000000-0000-0000-0000-000000003911';
update auth.users set raw_app_meta_data = '{}'::jsonb
where id = '00000000-0000-0000-0000-000000003902';
set local role service_role;
select throws_ok(
  $$select public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
    '00000000-0000-0000-0000-000000003902', 'Example Person')$$,
  '23514', 'La identidad de la invitación requiere verificación.',
  'Completion rejects a missing server provenance marker'
);
reset role;
select is((select count(*)::integer from public.profiles where id = '00000000-0000-0000-0000-000000003902'),
  0, 'Revoked and provenance-rejected requests leave no profile');
update auth.users set raw_app_meta_data = jsonb_build_object(
  'staff_invitation_id', '00000000-0000-0000-0000-000000003911',
  'staff_invitation_provenance', '00000000-0000-0000-0000-000000003921')
where id = '00000000-0000-0000-0000-000000003902';
set local role service_role;
select is(public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
  '00000000-0000-0000-0000-000000003902', 'Example Person'),
  '00000000-0000-0000-0000-000000003902'::uuid, 'Trusted completion returns the bound identity');
select is(public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
  '00000000-0000-0000-0000-000000003902', 'Example Person'),
  '00000000-0000-0000-0000-000000003902'::uuid, 'Exact retry returns the same identity');
reset role;
select is((select count(*)::integer from public.profiles where id = '00000000-0000-0000-0000-000000003902'
  and role = 'seller' and is_active and display_name = 'Example Person'), 1,
  'Exactly one active profile uses the invitation role and submitted name');
update public.profiles set is_active = false where id = '00000000-0000-0000-0000-000000003902';
set local role service_role;
select is(public.complete_staff_invitation('00000000-0000-0000-0000-000000003911',
  '00000000-0000-0000-0000-000000003902', 'Example Person'),
  '00000000-0000-0000-0000-000000003902'::uuid, 'Completed retry remains idempotent after deactivation');
reset role;
select is((select is_active from public.profiles where id = '00000000-0000-0000-0000-000000003902'),
  false, 'A completion retry never reactivates a deactivated profile');

select * from finish();
rollback;
