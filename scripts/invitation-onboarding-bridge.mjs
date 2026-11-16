// Private pipe only. No caller-selectable module, origin, proxy or executable code.
import { readFile, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInvitationOnboardingService } from '../apps/backoffice/features/accounts/invitations/invitations.ts';

async function main() {
  if (process.argv.length !== 2) throw new Error();
  let raw = '';
  for await (const chunk of process.stdin) {
    raw += chunk;
    if (raw.length > 32768) throw new Error();
  }
  const p = JSON.parse(raw);
  const path = await realpath(p.workdir);
  const project = basename(path);
  if (dirname(path) !== await realpath(tmpdir()) || !/^http-jwt-[0-9a-f]{16}$/.test(project)) throw new Error();
  const context = JSON.parse(await readFile(join(path, 'context.json'), 'utf8'));
  const config = await readFile(join(path, 'supabase/config.toml'), 'utf8');
  if (context.project !== project || !Number.isInteger(context.port)
      || !config.includes(`project_id = "${project}"`)
      || p.api !== `http://127.0.0.1:${context.port}`) throw new Error();
  if (!['acceptInvite', 'recoverInterrupted'].includes(p.method)
      || !['none', 'beforeCompletion', 'afterCompletion'].includes(p.fault)) throw new Error();
  const paths = ['/auth/v1/verify', '/auth/v1/user',
    '/rest/v1/rpc/check_staff_invitation_acceptance',
    '/auth/v1/logout?scope=global', '/rest/v1/rpc/complete_staff_invitation'];
  const trace = [];
  let refresh;
  let injected = false;
  const observe = async (url, init) => {
    const parsed = new URL(url);
    const path = parsed.pathname + parsed.search;
    if (parsed.origin !== p.api || !paths.includes(path)
        || init.redirect !== 'error' || !(init.signal instanceof AbortSignal)) throw new Error();
    const completion = path === paths[4];
    if (completion && p.fault === 'beforeCompletion') {
      injected = true;
      throw new Error();
    }
    const response = await fetch(url, init);
    const entry = { path, method: init.method, status: response.status };
    if (path === paths[0]) {
      entry.type = JSON.parse(init.body).type;
      const body = await response.clone().json();
      if (response.ok) refresh = body.refresh_token;
      else entry.code = body.error_code ?? body.code;
    }
    trace.push(entry);
    if (completion && p.fault === 'afterCompletion' && response.ok) {
      await response.body?.cancel();
      injected = true;
      throw new Error();
    }
    return response;
  };
  const service = createInvitationOnboardingService({ supabaseUrl: p.api,
    apiKey: p.key, serviceRoleKey: p.service }, observe);
  const result = await service[p.method](p.input);
  let revoked = null;
  if (refresh) {
    const response = await fetch(p.api + '/auth/v1/token?grant_type=refresh_token', {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10000),
      headers: { apikey: p.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refresh }),
    });
    const body = await response.json();
    const code = body.error_code ?? body.code;
    if (response.status !== 400 || !['refresh_token_not_found', 'refresh_token_already_used'].includes(code)) throw new Error();
    revoked = { status: 400, code };
  }
  const codes = ['invalid_input', 'invalid_token', 'invalid_identity', 'preflight_rejected',
    'password_rejected', 'password_update_uncertain', 'session_revocation_failed',
    'completion_rejected', 'completion_uncertain'];
  if (!(result.ok === true || result.ok === false && codes.includes(result.code))) throw new Error();
  for (const entry of trace) {
    if (entry.code !== undefined && entry.code !== 'otp_expired') throw new Error();
  }
  process.stdout.write(JSON.stringify({ protocol: 1, result, trace, injected, revoked }));
}
main().catch(() => {
  process.stderr.write('Bridge failed; private diagnostics suppressed.\n');
  process.exitCode = 1;
});
