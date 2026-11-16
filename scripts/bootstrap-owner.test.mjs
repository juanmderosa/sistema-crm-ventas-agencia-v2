import test from 'node:test';
import assert from 'node:assert/strict';

const { run, HELP } = await import('./bootstrap-owner.mjs');
const id = '11111111-1111-4111-8111-111111111111';
const email = 'owner@example.invalid';
const env = {
  SUPABASE_URL: 'https://synthetic.supabase.co',
  OWNER_BOOTSTRAP_TARGET: 'https://synthetic.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'synthetic-secret',
  OWNER_BOOTSTRAP_EMAIL: email,
  OWNER_BOOTSTRAP_NAME: 'Synthetic Owner',
  OWNER_BOOTSTRAP_PASSWORD: 'synthetic-password-123',
};
const verified = () => ({ id, email, email_confirmed_at: '2026-01-01T00:00:00Z',
  identities: [{ user_id: id, provider: 'email', identity_data: { email } }] });
function provider(options = {}) {
  const state = { users: options.existing ? [verified()] : [], profiles: [], passwords: [], mail: 0 };
  const calls = [];
  const fetch = async (url, init) => {
    const path = new URL(url).pathname;
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ path, method: init.method, body, headers: init.headers });
    assert.equal(init.redirect, 'error');
    assert.equal(init.headers.apikey, env.SUPABASE_SERVICE_ROLE_KEY);
    assert.equal(init.headers.Authorization, `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`);
    let data;
    let status = 200;
    if (path === '/rest/v1/rpc/bootstrap_initial_owner') {
      if (options.blocked || (body.p_finalize && options.finalizeFailure)) {
        return new Response(JSON.stringify({ message: 'synthetic-secret private upstream detail' }), { status: 409 });
      }
      if (body.p_finalize) {
        assert.equal(body.p_user_id, id);
        assert.equal(body.p_email, email);
        state.profiles.push({ id, role: 'owner', is_active: true, display_name: body.p_display_name });
        data = 'created';
      } else data = options.preflight ?? (state.users.length ? 'auth_only' : 'missing');
    } else if (path === '/auth/v1/admin/users' && init.method === 'POST') {
      assert.deepEqual(body, { email, password: env.OWNER_BOOTSTRAP_PASSWORD, email_confirm: true });
      if (options.createFailure) return new Response('{}', { status: 422 });
      state.users.push(verified());
      state.passwords.push(body.password);
      data = options.createResponse ?? verified();
    } else if (path === `/auth/v1/admin/users/${id}` && init.method === 'GET') {
      if (options.readFailure) return new Response('{}', { status: 503 });
      data = options.identity ?? state.users[0];
    } else assert.fail(`Unexpected provider operation: ${init.method} ${path}`);
    return new Response(JSON.stringify(data), { status });
  };
  return { state, calls, fetch };
}
async function invoke(p, overrides = {}, args = []) {
  return run(args, { env: { ...env, ...overrides }, fetch: p.fetch });
}
const failed = (stderr) => ({ exitCode: 1, stdout: '', stderr: `${stderr}\n` });
const success = { exitCode: 0, stdout: 'Dueño inicial aprovisionado correctamente.\n', stderr: '' };

test('help is exact and makes no provider calls, even without configuration', async () => {
  const p = provider();
  assert.deepEqual(await run(['--help'], { env: {}, fetch: p.fetch }), { exitCode: 0, stdout: HELP, stderr: '' });
  assert.equal(p.calls.length, 0);
});
for (const [name, overrides, args] of [
  ['missing credential', { SUPABASE_SERVICE_ROLE_KEY: '' }, []],
  ['missing password', { OWNER_BOOTSTRAP_PASSWORD: '' }, []],
  ['weak password', { OWNER_BOOTSTRAP_PASSWORD: 'short' }, []],
  ['missing name', { OWNER_BOOTSTRAP_NAME: ' ' }, []],
  ['invalid email', { OWNER_BOOTSTRAP_EMAIL: 'invalid' }, []],
  ['different target', { OWNER_BOOTSTRAP_TARGET: 'https://other.supabase.co' }, []],
  ['insecure remote URL', { SUPABASE_URL: 'http://synthetic.supabase.co', OWNER_BOOTSTRAP_TARGET: 'http://synthetic.supabase.co' }, []],
  ['URL credentials', { SUPABASE_URL: 'https://user:pass@synthetic.supabase.co' }, []],
  ['URL path', { SUPABASE_URL: 'https://synthetic.supabase.co/other' }, []],
  ['invalid recovery ID', { OWNER_BOOTSTRAP_USER_ID: 'not-a-uuid' }, ['--recover']],
  ['missing recovery ID', {}, ['--recover']],
  ['implicit recovery ID', { OWNER_BOOTSTRAP_USER_ID: id }, []],
  ['unknown argument', {}, ['--password=secret']],
  ['mixed help', {}, ['--help', '--recover']],
]) test(`reject ${name} before HTTP with unchanged state`, async () => {
  const p = provider();
  const before = structuredClone(p.state);
  assert.deepEqual(await invoke(p, overrides, args), failed('Configuración inválida. Consulte --help; no se realizó ninguna operación.'));
  assert.deepEqual(p.state, before);
  assert.equal(p.calls.length, 0);
});

test('create verified identity then finalize active Owner; no mail or extra writes', async () => {
  const p = provider();
  assert.deepEqual(await invoke(p), success);
  assert.deepEqual(p.state, { users: [verified()], passwords: [env.OWNER_BOOTSTRAP_PASSWORD], mail: 0,
    profiles: [{ id, role: 'owner', is_active: true, display_name: 'Synthetic Owner' }] });
  assert.deepEqual(p.calls.map(c => [c.method, c.path]), [
    ['POST', '/rest/v1/rpc/bootstrap_initial_owner'], ['POST', '/auth/v1/admin/users'],
    ['GET', `/auth/v1/admin/users/${id}`], ['POST', '/rest/v1/rpc/bootstrap_initial_owner'],
  ]);
});
test('explicit recovery verifies exact existing identity without password mutation or mail', async () => {
  const p = provider({ existing: true });
  assert.deepEqual(await invoke(p, { OWNER_BOOTSTRAP_USER_ID: id, OWNER_BOOTSTRAP_PASSWORD: '' }, ['--recover']), success);
  assert.deepEqual(p.state, { users: [verified()], passwords: [], mail: 0,
    profiles: [{ id, role: 'owner', is_active: true, display_name: 'Synthetic Owner' }] });
  assert.equal(p.calls.some(c => c.path === '/auth/v1/admin/users'), false);
});
for (const [name, options, recovery, message] of [
  ['existing active Owner or conflicting profile', { existing: true, blocked: true }, true, 'No se pudo verificar el estado inicial. No se modificó ninguna identidad.'],
  ['existing identity without explicit recovery', { existing: true }, false, 'La identidad ya existe. Use recuperación explícita con el identificador verificado; no se modificó la cuenta.'],
  ['recovery missing identity', {}, true, 'No se encontró la identidad prevista para recuperación. No se modificó ninguna cuenta.'],
  ['unexpected preflight response', { preflight: {} }, false, 'No se pudo verificar el estado inicial. No se modificó ninguna identidad.'],
  ['Auth creation rejection', { createFailure: true }, false, 'No se pudo confirmar el alta de Auth. Verifique el estado antes de reintentar; no se eliminó ninguna identidad.'],
  ['recovery finalization rejection', { existing: true, finalizeFailure: true }, true, 'No se pudo finalizar el perfil. Conserve la identidad y verifique el estado antes de una recuperación explícita.'],
]) test(`fail closed: ${name}`, async () => {
  const p = provider(options);
  const before = structuredClone(p.state);
  assert.deepEqual(await invoke(p, recovery ? { OWNER_BOOTSTRAP_USER_ID: id } : {}, recovery ? ['--recover'] : []), failed(message));
  assert.deepEqual(p.state, before);
});
for (const [name, identity] of [
  ['different ID', { ...verified(), id: '22222222-2222-4222-8222-222222222222' }],
  ['different email', { ...verified(), email: 'other@example.invalid' }],
  ['unconfirmed email', { ...verified(), email_confirmed_at: null }],
  ['banned account', { ...verified(), banned_until: '2999-01-01T00:00:00Z' }],
  ['pending email change', { ...verified(), new_email: 'other@example.invalid' }],
  ['anonymous account', { ...verified(), is_anonymous: true }],
  ['SSO account', { ...verified(), is_sso_user: true }],
  ['deleted account', { ...verified(), deleted_at: '2026-01-01T00:00:00Z' }],
  ['wrong identity user', { ...verified(), identities: [{ ...verified().identities[0], user_id: '22222222-2222-4222-8222-222222222222' }] }],
  ['ambiguous identities', { ...verified(), identities: [...verified().identities, ...verified().identities] }],
  ['different identity email', { ...verified(), identities: [{ user_id: id, provider: 'email', identity_data: { email: 'other@example.invalid' } }] }],
  ['different provider', { ...verified(), identities: [{ user_id: id, provider: 'google', identity_data: { email } }] }],
]) test(`recovery rejects ${name} without stored changes`, async () => {
  const p = provider({ existing: true, identity });
  const before = structuredClone(p.state);
  assert.deepEqual(await invoke(p, { OWNER_BOOTSTRAP_USER_ID: id }, ['--recover']), failed('La identidad no coincide con la cuenta prevista o no está habilitada. No se creó ningún perfil.'));
  assert.deepEqual(p.state, before);
  assert.equal(p.calls.length, 2);
});
test('profile failure preserves newly created Auth identity, never compensates by deletion', async () => {
  const p = provider({ finalizeFailure: true });
  assert.deepEqual(await invoke(p), failed('No se pudo finalizar el perfil. Conserve la identidad y verifique el estado antes de una recuperación explícita.'));
  assert.deepEqual(p.state, { users: [verified()], passwords: [env.OWNER_BOOTSTRAP_PASSWORD], profiles: [], mail: 0 });
  assert.equal(p.calls.some(c => ['DELETE', 'PUT', 'PATCH'].includes(c.method)), false);
});
test('failed new finalization can be recovered without duplicating Auth or changing its password', async () => {
  const options = { finalizeFailure: true };
  const p = provider(options);
  assert.deepEqual(await invoke(p), failed('No se pudo finalizar el perfil. Conserve la identidad y verifique el estado antes de una recuperación explícita.'));
  const authBefore = structuredClone(p.state.users);
  options.finalizeFailure = false;
  assert.deepEqual(await invoke(p, { OWNER_BOOTSTRAP_USER_ID: id, OWNER_BOOTSTRAP_PASSWORD: '' }, ['--recover']), success);
  assert.deepEqual(p.state.users, authBefore);
  assert.deepEqual(p.state.passwords, [env.OWNER_BOOTSTRAP_PASSWORD]);
  assert.deepEqual(p.state.profiles, [{ id, role: 'owner', is_active: true, display_name: 'Synthetic Owner' }]);
  assert.equal(p.state.mail, 0);
  assert.equal(p.calls.filter(c => c.path === '/auth/v1/admin/users').length, 1);
});
for (const recovery of [false, true]) test(`Auth read failure preserves ${recovery ? 'existing' : 'new'} identity without finalization`, async () => {
  const p = provider({ existing: recovery, readFailure: true });
  const before = structuredClone(p.state);
  assert.deepEqual(await invoke(p, recovery ? { OWNER_BOOTSTRAP_USER_ID: id } : {}, recovery ? ['--recover'] : []),
    failed('La identidad no coincide con la cuenta prevista o no está habilitada. No se creó ningún perfil.'));
  assert.deepEqual(p.state, recovery ? before : { users: [verified()], passwords: [env.OWNER_BOOTSTRAP_PASSWORD], mail: 0, profiles: [] });
  assert.equal(p.calls.filter(c => c.body?.p_finalize).length, 0);
});
for (const createResponse of [{}, { ...verified(), email: 'other@example.invalid' }]) test('unverifiable Auth creation never finalizes or removes the new identity', async () => {
  const p = provider({ createResponse });
  assert.deepEqual(await invoke(p), failed('No se pudo confirmar el alta de Auth. Verifique el estado antes de reintentar; no se eliminó ninguna identidad.'));
  assert.deepEqual(p.state, { users: [verified()], passwords: [env.OWNER_BOOTSTRAP_PASSWORD], mail: 0, profiles: [] });
  assert.equal(p.calls.length, 2);
});
test('transport failure is sanitized and never automatically retried', async () => {
  let calls = 0;
  const result = await run([], { env, fetch: async () => { calls++; throw new Error('synthetic-secret'); } });
  assert.deepEqual(result, failed('No se pudo verificar el estado inicial. No se modificó ninguna identidad.'));
  assert.equal(calls, 1);
});
