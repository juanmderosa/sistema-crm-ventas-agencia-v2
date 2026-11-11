// Server-side recovery core; HTTP handlers and browser completion are separate work.
// Never return provider sessions, response payloads, emails or tokens to the caller.
type Config = { authUrl: string; apiKey: string; callbackOrigin: string };
type FailureCode = 'invalid_input' | 'invalid_recovery' | 'password_rejected'
  | 'password_update_uncertain' | 'session_revocation_failed';
type Completion = { ok: true } | { ok: false; code: FailureCode };
const MESSAGE = 'Si la cuenta permite recuperar el acceso, recibirás un correo con instrucciones.';

function origin(value: string): string {
  const url = new URL(value);
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.username || url.password || url.pathname !== '/' || url.search || url.hash
    || (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback))) {
    throw new Error('Se requiere un origen HTTPS o loopback sin ruta ni credenciales.');
  }
  return url.origin;
}

export function createRecoveryService(config: Config, fetcher: typeof fetch = fetch) {
  if (typeof window !== 'undefined') throw new Error('El servicio requiere ejecución del lado del servidor.');
  if (!config.apiKey.trim()) throw new Error('Falta configurar la clave de acceso a Auth.');
  const base = `${origin(config.authUrl)}/auth/v1`;
  const callback = `${origin(config.callbackOrigin)}/acceso/recuperar`;
  async function call(path: string, method: string, body?: unknown, token?: string) {
    return fetcher(`${base}${path}`, {
      method, redirect: 'error', signal: AbortSignal.timeout(10_000),
      headers: { apikey: config.apiKey, 'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  }
  return {
    async request(email: string): Promise<{ message: string }> {
      if (typeof email === 'string' && email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        try {
          const response = await call(`/recover?redirect_to=${encodeURIComponent(callback)}`, 'POST', { email });
          // Ignore provider details equally for all addresses. No response payload is retained.
          await response.body?.cancel();
        } catch { /* Network/provider failure must not reveal account existence. */ }
      }
      return { message: MESSAGE };
    },
    async complete(tokenHash: string, password: string): Promise<Completion> {
      if (typeof tokenHash !== 'string' || !tokenHash || tokenHash.length > 2048
        || /\s/.test(tokenHash) || typeof password !== 'string' || password.length < 6) {
        return { ok: false, code: 'invalid_input' };
      }
      let session: string;
      try {
        const verification = await call('/verify', 'POST', { token_hash: tokenHash, type: 'recovery' });
        if (!verification.ok) {
          await verification.body?.cancel();
          return { ok: false, code: 'invalid_recovery' };
        }
        const payload: unknown = await verification.json();
        if (!payload || typeof payload !== 'object' || !('access_token' in payload)
          || typeof payload.access_token !== 'string' || !payload.access_token) {
          return { ok: false, code: 'invalid_recovery' };
        }
        session = payload.access_token;
      } catch { return { ok: false, code: 'invalid_recovery' }; }

      let updateFailure: FailureCode | undefined;
      try {
        const update = await call('/user', 'PUT', { password }, session);
        if (!update.ok) updateFailure = 'password_rejected';
        await update.body?.cancel();
      } catch {
        // A timeout can occur after persistence. Do not promise that nothing changed.
        updateFailure = 'password_update_uncertain';
      }
      try {
        const logout = await call('/logout?scope=global', 'POST', undefined, session);
        await logout.body?.cancel();
        if (!logout.ok) return { ok: false, code: 'session_revocation_failed' };
      } catch { return { ok: false, code: 'session_revocation_failed' }; }
      return updateFailure ? { ok: false, code: updateFailure } : { ok: true };
    },
  };
}
