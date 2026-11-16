import { pathToFileURL } from 'node:url';

export const HELP = `Uso: node scripts/bootstrap-owner.mjs [--recover | --help]

Aprovisionamiento manual del primer Dueño desde un entorno confiable.
Requiere autorización independiente antes de operar sobre cualquier proveedor.

Variables de entorno (no pase credenciales como argumentos):
  SUPABASE_URL                 Origen HTTPS; HTTP solo en localhost/127.0.0.1.
  OWNER_BOOTSTRAP_TARGET       Confirmación explícita: igual a SUPABASE_URL.
  SUPABASE_SERVICE_ROLE_KEY    Credencial privilegiada; nunca se imprime.
  OWNER_BOOTSTRAP_EMAIL        Correo exacto de la cuenta prevista, en minúsculas.
  OWNER_BOOTSTRAP_NAME         Nombre visible del Dueño.
  OWNER_BOOTSTRAP_PASSWORD     Contraseña inicial (mínimo 12 caracteres); solo alta.
  OWNER_BOOTSTRAP_USER_ID      UUID verificado por el operador; solo --recover.

Sin opciones: crea Auth con correo confirmado, verifica y finaliza el perfil.
--recover: completa solo un perfil ausente de la identidad verificada; no cambia
contraseñas, no elimina identidades ni envía invitaciones o correo de recuperación.
Rechaza perfiles existentes, cuentas ambiguas y cualquier Dueño ya registrado.
--help: muestra esta ayuda sin contactar al proveedor.
`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const failure = (message) => ({ exitCode: 1, stdout: '', stderr: `${message}\n` });
function configuration(args, env) {
  if (!(args.length === 0 || (args.length === 1 && args[0] === '--recover'))) throw new Error();
  const recover = args[0] === '--recover';
  const origin = new URL(env.SUPABASE_URL);
  if (origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/'
      || env.SUPABASE_URL !== origin.origin || env.OWNER_BOOTSTRAP_TARGET !== origin.origin
      || !(origin.protocol === 'https:' || (origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) throw new Error();
  const email = env.OWNER_BOOTSTRAP_EMAIL;
  const name = env.OWNER_BOOTSTRAP_NAME;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  const userId = env.OWNER_BOOTSTRAP_USER_ID;
  if (!key?.trim() || !email || email !== email.trim().toLowerCase()
      || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254
      || !name?.trim() || name.length > 200
      || (recover ? !uuid.test(userId ?? '') : Boolean(userId) || (env.OWNER_BOOTSTRAP_PASSWORD?.length ?? 0) < 12)) throw new Error();
  return { origin: origin.origin, recover, email, name: name.trim(), key, userId, password: env.OWNER_BOOTSTRAP_PASSWORD };
}
function verifyIdentity(user, id, email) {
  const identities = user?.identities;
  return user?.id === id && user.email === email && Boolean(user.email_confirmed_at)
    && !user.is_anonymous && !user.is_sso_user && !user.deleted_at && !user.new_email
    && (!user.banned_until || Date.parse(user.banned_until) <= Date.now())
    && Array.isArray(identities) && identities.length === 1
    && identities[0].provider === 'email' && identities[0].user_id === id
    && identities[0].identity_data?.email === email;
}

// Dependency injection is restricted to the HTTP boundary; the CLI uses native fetch.
export async function run(args, { env = process.env, fetch = globalThis.fetch } = {}) {
  if (args.length === 1 && args[0] === '--help') return { exitCode: 0, stdout: HELP, stderr: '' };
  let config;
  try { config = configuration(args, env); }
  catch { return failure('Configuración inválida. Consulte --help; no se realizó ninguna operación.'); }
  const { origin, recover, email, name, key, password } = config;
  async function request(path, method, body) {
    const response = await fetch(`${origin}${path}`, {
      method, redirect: 'error', signal: AbortSignal.timeout(15000),
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!response.ok) throw new Error('Provider request rejected');
    return response.json();
  }
  const rpc = (finalize, id = config.userId ?? null) => request('/rest/v1/rpc/bootstrap_initial_owner', 'POST', {
    p_email: email, p_user_id: id, p_display_name: finalize ? name : null, p_finalize: finalize,
  });
  let state;
  try {
    state = await rpc(false);
    if (!['missing', 'auth_only'].includes(state)) throw new Error();
  } catch { return failure('No se pudo verificar el estado inicial. No se modificó ninguna identidad.'); }
  if (!recover && state === 'auth_only') return failure('La identidad ya existe. Use recuperación explícita con el identificador verificado; no se modificó la cuenta.');
  if (recover && state !== 'auth_only') return failure('No se encontró la identidad prevista para recuperación. No se modificó ninguna cuenta.');
  let id = config.userId;
  if (!recover) {
    try {
      const created = await request('/auth/v1/admin/users', 'POST', { email, password, email_confirm: true });
      id = created?.id;
      if (!uuid.test(id ?? '') || !verifyIdentity(created, id, email)) throw new Error();
    } catch { return failure('No se pudo confirmar el alta de Auth. Verifique el estado antes de reintentar; no se eliminó ninguna identidad.'); }
  }
  try {
    const user = await request(`/auth/v1/admin/users/${id}`, 'GET');
    if (!verifyIdentity(user, id, email)) throw new Error();
  } catch { return failure('La identidad no coincide con la cuenta prevista o no está habilitada. No se creó ningún perfil.'); }
  try {
    if (await rpc(true, id) !== 'created') throw new Error();
  } catch { return failure('No se pudo finalizar el perfil. Conserve la identidad y verifique el estado antes de una recuperación explícita.'); }
  return { exitCode: 0, stdout: 'Dueño inicial aprovisionado correctamente.\n', stderr: '' };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const result = await run(process.argv.slice(2));
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  process.exitCode = result.exitCode;
}
