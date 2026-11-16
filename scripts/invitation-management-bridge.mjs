// Fixed actual service; credentials and canonical payload stay inside private pipes.
import { readFile, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';

async function main() {
  if (process.argv.length !== 2) throw new Error();
  let raw = '';
  for await (const chunk of process.stdin) {
    raw += chunk;
    if (Buffer.byteLength(raw) > 32768) throw new Error();
  }
  const p = JSON.parse(raw);
  const owned = await realpath(p.workdir);
  const project = basename(owned);
  if (dirname(owned) !== await realpath(tmpdir()) || !/^http-jwt-[0-9a-f]{16}$/.test(project)) throw new Error();
  const context = JSON.parse(await readFile(join(owned, 'context.json'), 'utf8'));
  const config = await readFile(join(owned, 'supabase/config.toml'), 'utf8');
  if (context.project !== project || !Number.isInteger(context.port) || context.port < 1 || context.port > 65535
      || !config.split(/\r?\n/).includes(`project_id = "${project}"`)
      || p.api !== `http://127.0.0.1:${context.port}` || !['none', 'afterRPC'].includes(p.fault)) throw new Error();
  const { createInvitationManagementService } = await import('../apps/backoffice/features/accounts/invitations/management.ts');
  const trace = [];
  let injected = false;
  const rpc = '/rest/v1/rpc/prepare_bound_staff_invitation_resend';
  const observe = async (url, init) => {
    const parsed = new URL(url);
    const path = parsed.pathname;
    const isRPC = path === rpc;
    if (parsed.origin !== p.api || parsed.search || parsed.hash
        || !(isRPC || path === '/auth/v1/user') || init.method !== (isRPC ? 'POST' : 'GET')
        || init.redirect !== 'error' || !(init.signal instanceof AbortSignal)) throw new Error();
    const headers = new Headers(init.headers);
    const credential = isRPC ? p.service : p.input.actorAccessToken;
    const headersMatch = headers.get('apikey') === (isRPC ? p.service : p.key)
      && headers.get('authorization') === `Bearer ${credential}`;
    const actorMatch = !isRPC || JSON.stringify(JSON.parse(init.body)) === JSON.stringify({
      p_request_id: p.input.requestID, p_invitation_id: p.input.invitationID, p_actor_id: p.actor });
    if (!headersMatch || !actorMatch) throw new Error();
    const response = await fetch(url, init);
    trace.push({ path, method: init.method, status: response.status,
      headersMatch, actorMatch, redirect: true, signal: true });
    if (isRPC && p.fault === 'afterRPC' && response.status === 200) {
      await response.arrayBuffer(); // Observe actual committed response, then discard it.
      injected = true;
      throw new Error('Observed reply discarded.');
    }
    return response;
  };
  const service = createInvitationManagementService({ supabaseUrl: p.api,
    apiKey: p.key, serviceRoleKey: p.service }, observe);
  const result = await service.prepareBoundResend(p.input); // Preserve caller extras unchanged.
  const codes = ['prepared', 'invalid_input', 'authentication_failed', 'denied', 'preparation_uncertain'];
  if (!codes.includes(result.code)) throw new Error();
  const canonical = result.ok && !!p.expected && Object.keys(result.preparation).length === 6
    && Object.keys(p.expected).length === 6
    && Object.entries(p.expected).every(([key, value]) => result.preparation[key] === value);
  process.stdout.write(JSON.stringify({ code: result.code, canonical: !!canonical,
    frozen: result.ok && Object.isFrozen(result.preparation), privateOmitted: true, injected, trace }));
}
main().catch(() => {
  process.stderr.write('Bridge failed; private diagnostics suppressed.\n');
  process.exitCode = 1;
});
