"""Three functional groups for the existing private completion primitive."""
from db import (INVALID, VERIFY, REVOKED, complete, fixture, literal,
                patch, persisted, revoke)


def functional(db):
    for role in ('admin','seller'):
        f = fixture(db,role)
        name = 'A' * 200 if role == 'admin' else '  Valid Name  '
        db.check(complete(f,name), f[1])
        persisted(db,f,name)
        db.check(complete(f,name), f[1], readonly=True)
        db.check(complete(f,'Changed Name'),error=('23514',VERIFY),readonly=True)
        db.sql(patch(f[1],"role='seller',is_active=false"))
        persisted(db,f,name,False,'seller')
        db.check(complete(f,name), f[1], readonly=True)
        persisted(db,f,name,False,'seller')
    f = fixture(db)
    for name in ('', '   ', 'x'*201, None):
        db.check(complete(f,name),error=('22023',INVALID),readonly=True)
    for invitation,user in ((None,f[1]),(f[0],None),
                            ('00000000-0000-0000-0000-000000000000',f[1]),
                            (f[0],'00000000-0000-0000-0000-000000000000')):
        sql = 'select public.complete_staff_invitation(%s,%s,\'Valid\')' % (
            literal(invitation),literal(user))
        db.check(sql,error=('22023',INVALID) if None in (invitation,user)
                 else ('23514',VERIFY),readonly=True)
    db.sql('update auth.users set raw_app_meta_data=\'{}\'::jsonb where id=' + literal(f[1]))
    db.check(complete(f),error=('23514',VERIFY),readonly=True)
    f = fixture(db)
    db.check(revoke(f),f[0])
    db.check(complete(f),error=('23514',REVOKED),readonly=True)
    db.require('rejected first completion leaves no operational profile',db.sql(
        'select not exists(select 1 from public.profiles where id=%s);' % literal(f[1])) == 't')


def permissions(db):
    f = fixture(db)
    for role in ('anon','authenticated'):
        db.check(complete(f),role=role,readonly=True,error=(
            '42501','permission denied for function complete_staff_invitation'))
    statements = (
        'select invitation_id from public.staff_invitation_completions',
        'insert into public.staff_invitation_completions '
        '(invitation_id,user_id,initial_display_name) values (%s,%s,\'Probe Person\')' % (
            literal(f[0]),literal(f[1])),
        "update public.staff_invitation_completions set initial_display_name='Changed'",
        'delete from public.staff_invitation_completions')
    for role in ('anon','authenticated','service_role'):
        for statement in statements:
            db.check(statement,role=role,readonly=True,error=(
                '42501','permission denied for table staff_invitation_completions'))
    db.check(complete(f),f[1])
    persisted(db,f)


def rollback(db):
    f = fixture(db)
    # Only this owned disposable database receives the temporary failure trigger.
    db.sql("create function public.completion_probe_fail() returns trigger "
           "language plpgsql as $$ begin raise exception 'completion probe injected failure' "
           "using errcode='P0001'; end $$; "
           'create trigger completion_probe_fail before insert on '
           'public.staff_invitation_completions for each row '
           'execute function public.completion_probe_fail();')
    try:
        db.check(complete(f),error=('P0001','completion probe injected failure'),readonly=True)
        db.require('failure rolls back both profile and completion',db.sql(
            'select not exists(select 1 from public.profiles where id=%s) and '
            'not exists(select 1 from public.staff_invitation_completions where invitation_id=%s);'
            % (literal(f[1]),literal(f[0]))) == 't')
    finally:
        db.sql('drop trigger completion_probe_fail on public.staff_invitation_completions; '
               'drop function public.completion_probe_fail();')
    db.check(complete(f),f[1])
    persisted(db,f)
