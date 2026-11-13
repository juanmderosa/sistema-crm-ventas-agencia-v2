"""Bounded SQL transport and public-interface fixture setup; no credentials printed."""
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OWNER = '00000000-0000-0000-0000-000000008001'
LOCK = 'public.staff_invitation_intents'
INVALID = 'Datos de finalización inválidos.'
VERIFY = 'La identidad de la invitación requiere verificación.'
REVOKED = 'La invitación fue revocada. Cree una nueva invitación.'
STATE = (HERE / 'state.sql').read_text(encoding='utf-8')


def literal(value):
    return 'null' if value is None else "'" + str(value).replace("'", "''") + "'"


def finish(process, payload=None, timeout=25):
    try:
        out, err = process.communicate(payload, timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise RuntimeError('SQL subprocess deadline exceeded') from None
    return process.returncode, out, err


def wrapped(sql, role='service_role'):
    # Catch the exact public response without printing SQL or fixture values.
    return "set role %s; do $probe$ declare v text; c text; m text; begin " % role + (
        'begin execute ' + literal(sql) + ' into v; '
        "c := '00000'; m := ''; exception when others then "
        'get stacked diagnostics c = returned_sqlstate, m = message_text; end; '
        "perform set_config('completion_probe.reply',jsonb_build_object("
        "'code',c,'message',m,'value',v)::text,false); end $probe$; "
        "reset role; select current_setting('completion_probe.reply');\n")


class DB:
    def __init__(self, project):
        self.command = ['docker','exec','-i','supabase_db_' + project,
                        'psql','-X','-qAt','-U','postgres','-d','postgres',
                        '-v','ON_ERROR_STOP=1']
        self.assertions = self.outcomes = self.protected = self.waits = 0
        self.groups = {}

    def require(self, label, condition):
        if not condition:
            raise AssertionError(label)
        self.assertions += 1

    def launch(self):
        return subprocess.Popen(self.command, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')

    def sql(self, sql):
        code, out, err = finish(self.launch(),
            "set statement_timeout='12s'; set lock_timeout='10s';\n" + sql)
        if code != 0 or err != '':
            raise RuntimeError('SQL transport failed; diagnostics withheld')
        return out.strip()

    def snapshot(self):
        return json.loads(self.sql(STATE))

    def unchanged(self, before, after):
        self.require('all public/Auth table counts and hashes unchanged',
                     before['tables'] == after['tables'])
        self.require('all public/Auth sequence states unchanged',
                     before['sequences'] == after['sequences'])
        self.protected += 1

    def reply(self, result, expected):
        code, out, err = result
        self.require('exact process exit and empty stderr', code == 0 and err == '')
        self.require('exact SQLSTATE message and result', json.loads(out) == expected)
        self.outcomes += 1

    def check(self, sql, value=None, error=None, role='service_role', readonly=False):
        before = self.snapshot() if readonly else None
        expected = {'code': error[0] if error else '00000',
                    'message': error[1] if error else '', 'value': value}
        self.reply(finish(self.launch(),
            "set statement_timeout='12s'; set lock_timeout='10s';\n" + wrapped(sql,role)),
            expected)
        if readonly:
            self.unchanged(before, self.snapshot())

    def group(self, name, action):
        before = (self.assertions,self.outcomes,self.protected,self.waits)
        action(self)
        after = (self.assertions,self.outcomes,self.protected,self.waits)
        delta = dict(zip(('assertions','outcomes','protected','waits'),
                         (a-b for a,b in zip(after,before))))
        self.groups[name] = delta
        print('PASS group ' + name + ' ' + json.dumps(delta,sort_keys=True), flush=True)


def complete(fixture, name='Probe Person'):
    invitation, user, _, _ = fixture
    return 'select public.complete_staff_invitation(%s,%s,%s)' % tuple(
        literal(v) for v in (invitation,user,name))


def revoke(fixture):
    invitation, _, email, role = fixture
    return 'select public.manage_staff_invitation_intent(%s,%s,%s,\'revoke\',%s,%s)' % tuple(
        literal(v) for v in (uuid.uuid4(),invitation,OWNER,email,role))


def patch(user, fields):
    return "select set_config('request.jwt.claim.sub',%s,false); " % literal(OWNER) + (
        'set role authenticated; update public.profiles set ' + fields +
        ' where id=' + literal(user) + '; reset role;')


def fixture(db, role='seller'):
    invitation, user, provenance = (str(uuid.uuid4()) for _ in range(3))
    email = user + '@example.invalid'
    db.check('select public.manage_staff_invitation_intent(%s,%s,%s,\'create\',%s,%s)' % tuple(
        literal(v) for v in (uuid.uuid4(),invitation,OWNER,email,role)), invitation)
    db.check('select public.prepare_staff_invitation_identity(%s,%s,%s)->>\'provenance\'' % tuple(
        literal(v) for v in (invitation,OWNER,provenance)), provenance)
    db.sql('insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values '
        '(%s,%s,now(),jsonb_build_object(\'staff_invitation_id\',%s::text,'
        '\'staff_invitation_provenance\',%s::text));' % tuple(
        literal(v) for v in (user,email,invitation,provenance)) +
        'insert into auth.identities(id,user_id,provider_id,provider,identity_data) values '
        '(%s,%s,%s,\'email\',jsonb_build_object(\'sub\',%s::text,\'email\',%s::text));' % tuple(
        literal(v) for v in (uuid.uuid4(),user,user,user,email)))
    db.check('select public.bind_staff_invitation_identity(%s,%s,%s,%s)' % tuple(
        literal(v) for v in (invitation,OWNER,user,provenance)), user)
    return invitation,user,email,role


def persisted(db, f, name='Probe Person', active=True, role=None):
    invitation,user,_,invited_role = f
    # Operational profile read is role-authorized, not a private-table-only assertion.
    query = ('select (count(*)=1 and bool_and(role=%s and display_name=%s '
             'and is_active=%s))::text from public.profiles where id=%s') % (
                 literal(role or invited_role),literal(name),str(active).lower(),literal(user))
    # SET_CONFIG belongs in the same SQL session as the public read.
    out = db.sql("select set_config('request.jwt.claim.sub',%s,false); " % literal(OWNER) +
                 'set role authenticated;' + query + ';')
    db.require('public Owner sees exact retained profile',out.splitlines()[-1] == 'true')
    db.require('one permanent completion with initial name', db.sql(
        'select count(*)=1 and bool_and(user_id=%s and initial_display_name=%s '
        'and completed_at is not null) from public.staff_invitation_completions '
        'where invitation_id=%s;' % (literal(user),literal(name),literal(invitation))) == 't')
