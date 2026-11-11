import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRecoveryService } from './recovery.ts';

const config = { authUrl: 'http://127.0.0.1:54321', apiKey: 'synthetic-key', callbackOrigin: 'http://localhost:3001' };
function setup(statuses: number[] = [200, 200, 204]) {
  const calls: { url: string; body: unknown; authorization: string | null; redirect: RequestRedirect | undefined }[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    calls.push({ url: String(input), body: init?.body ? JSON.parse(String(init.body)) : null,
      authorization: new Headers(init?.headers).get('authorization'), redirect: init?.redirect });
    const status = statuses.shift() ?? 200;
    return new Response(status === 204 ? null : JSON.stringify({ access_token: 'synthetic-session' }), { status });
  };
  return { service: createRecoveryService(config, fetcher), calls };
}

test('recovery request is generic for existing, missing and provider-rejected accounts', async () => {
  for (const status of [200, 400, 429, 500]) {
    const { service, calls } = setup([status]);
    assert.deepEqual(await service.request('synthetic@example.test'), { message: 'Si la cuenta permite recuperar el acceso, recibirás un correo con instrucciones.' });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, 'http://127.0.0.1:54321/auth/v1/recover?redirect_to=http%3A%2F%2Flocalhost%3A3001%2Facceso%2Frecuperar');
    assert.deepEqual(calls[0].body, { email: 'synthetic@example.test' });
    assert.equal(calls[0].redirect, 'error');
  }
});

test('invalid email has no provider effects and returns the same generic response', async () => {
  const { service, calls } = setup();
  await service.request('not an email');
  assert.equal(calls.length, 0);
});

test('only verified recovery credentials can change password, then all sessions are revoked', async () => {
  const { service, calls } = setup();
  assert.deepEqual(await service.complete('synthetic-token-hash', 'synthetic-password'), { ok: true });
  assert.deepEqual(calls.map(call => call.url), [
    `${config.authUrl}/auth/v1/verify`, `${config.authUrl}/auth/v1/user`, `${config.authUrl}/auth/v1/logout?scope=global`,
  ]);
  assert.deepEqual(calls[0].body, { token_hash: 'synthetic-token-hash', type: 'recovery' });
  assert.deepEqual(calls[1].body, { password: 'synthetic-password' });
  assert.equal(calls[1].authorization, 'Bearer synthetic-session');
  assert.equal(calls[2].authorization, 'Bearer synthetic-session');
  assert.ok(calls.every(call => call.redirect === 'error'));
});

test('invalid or replayed credentials never update password or revoke sessions', async () => {
  const { service, calls } = setup([403]);
  assert.deepEqual(await service.complete('expired-hash', 'synthetic-password'), { ok: false, code: 'invalid_recovery' });
  assert.equal(calls.length, 1);
});

test('missing provider session fails closed without mutation', async () => {
  let calls = 0;
  const service = createRecoveryService(config, async () => { calls++; return Response.json({}); });
  assert.deepEqual(await service.complete('synthetic-hash', 'synthetic-password'), { ok: false, code: 'invalid_recovery' });
  assert.equal(calls, 1);
});

test('password rejection revokes consumed recovery session but reports failure', async () => {
  const { service, calls } = setup([200, 422, 204]);
  assert.deepEqual(await service.complete('synthetic-hash', 'synthetic-password'), { ok: false, code: 'password_rejected' });
  assert.equal(calls.length, 3);
});

test('failed logout never reports successful recovery', async () => {
  const { service } = setup([200, 200, 500]);
  assert.deepEqual(await service.complete('synthetic-hash', 'synthetic-password'), { ok: false, code: 'session_revocation_failed' });
});

test('short passwords and absent credentials are rejected before consuming a token', async () => {
  const { service, calls } = setup();
  assert.deepEqual(await service.complete('', 'synthetic-password'), { ok: false, code: 'invalid_input' });
  assert.deepEqual(await service.complete('synthetic-hash', 'short'), { ok: false, code: 'invalid_input' });
  assert.equal(calls.length, 0);
});

test('network failure is redacted and recovery requests remain generic', async () => {
  const service = createRecoveryService(config, async () => { throw new Error('sensitive provider payload'); });
  assert.match((await service.request('synthetic@example.test')).message, /^Si la cuenta/);
  assert.deepEqual(await service.complete('synthetic-hash', 'synthetic-password'), { ok: false, code: 'invalid_recovery' });
});

test('callback and Auth origins reject credentials, paths, query, insecure remote URLs', () => {
  for (const origin of ['http://remote.example', 'https://user:secret@example.test', 'https://example.test/path', 'https://example.test?redirect=evil', 'https://example.test#fragment', 'ftp://localhost']) {
    assert.throws(() => createRecoveryService({ ...config, callbackOrigin: origin }));
    assert.throws(() => createRecoveryService({ ...config, authUrl: origin }));
  }
});
