// Private server orchestration only. SQL owns current active-role authorization.
export type InvitationManagementConfig = {
  supabaseUrl: string;
  apiKey: string;
  serviceRoleKey: string;
};
export type BoundResendInput = {
  requestID: string;
  invitationID: string;
  actorAccessToken: string;
};
export type BoundResendPreparation = Readonly<{
  invitation_id: string;
  email: string;
  role: "admin" | "seller";
  provenance: string;
  user_id: string;
  candidate_user_id: string;
}>;
export type BoundResendResult =
  | { ok: true; code: "prepared"; preparation: BoundResendPreparation }
  | { ok: false; code: "invalid_input" | "authentication_failed" | "denied" | "preparation_uncertain" };
const record = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);
const uuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const credential = (value: unknown): value is string =>
  typeof value === "string" && /^[\x21-\x7e]+$/.test(value);
function trustedOrigin(value: unknown): string {
  // Validate syntax before URL normalization can erase paths or control characters.
  if (typeof value !== "string" || !/^[a-z]+:\/\/[^/?#@\\]+\/?$/i.test(value) ||
    /[\u0000-\u0020\u007f]/.test(value)) throw new Error();
  const url = new URL(value);
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.username || url.password || url.pathname !== "/" || url.search || url.hash ||
    (url.protocol !== "https:" && !(url.protocol === "http:" && loopback))) throw new Error();
  return url.origin;
}
function privateReply(value: unknown, invitationID: string): value is BoundResendPreparation {
  if (!record(value)) return false;
  const keys = ["invitation_id", "email", "role", "provenance", "user_id", "candidate_user_id"];
  return Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key)) &&
    uuid(value.invitation_id) && value.invitation_id.toLowerCase() === invitationID.toLowerCase() &&
    typeof value.email === "string" && value.email.length <= 254 &&
    value.email === value.email.trim().toLowerCase() && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.email) &&
    (value.role === "admin" || value.role === "seller") && uuid(value.provenance) &&
    uuid(value.user_id) && uuid(value.candidate_user_id) &&
    value.user_id.toLowerCase() === value.candidate_user_id.toLowerCase();
}

export function createInvitationManagementService(
  config: InvitationManagementConfig,
  fetcher: typeof fetch = fetch,
) {
  if (typeof window !== "undefined") throw new Error("Invitation management requires server execution.");
  let base: string;
  let apiKey: string;
  let serviceRoleKey: string;
  try {
    if (!record(config)) throw new Error();
    const captured = { ...config };
    if (!credential(captured.apiKey) || !credential(captured.serviceRoleKey)) throw new Error();
    base = trustedOrigin(captured.supabaseUrl);
    apiKey = captured.apiKey;
    serviceRoleKey = captured.serviceRoleKey;
  } catch {
    throw new Error("Invalid invitation management configuration.");
  }

  async function call<T>(path: string, init: RequestInit, consume: (response: Response) => Promise<T>): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10_000);
    try {
      return await consume(await fetcher(`${base}${path}`, {
        ...init, redirect: "error", signal: controller.signal,
      }));
    } finally {
      // Include body consumption in the deadline; never leave a timer after completion.
      clearTimeout(timer);
    }
  }
  const fail = (code: Extract<BoundResendResult, { ok: false }>["code"]): BoundResendResult => ({ ok: false, code });
  async function prepareBoundResend(input: BoundResendInput): Promise<BoundResendResult> {
    if (typeof window !== "undefined") throw new Error("Invitation management requires server execution.");
    if (!record(input)) return fail("invalid_input");
    const { requestID, invitationID, actorAccessToken } = input;
    if (!uuid(requestID) || !uuid(invitationID) || !credential(actorAccessToken)) return fail("invalid_input");
    let actorID: string;
    try {
      const identity: unknown = await call("/auth/v1/user", {
        method: "GET",
        headers: { apikey: apiKey, Authorization: `Bearer ${actorAccessToken}`, "Content-Type": "application/json" },
      }, async (response) => {
        if (!response.ok) { await response.body?.cancel(); return undefined; }
        return response.json();
      });
      // GET /user returns the User itself. Nested metadata and JWT claims are not authority.
      if (!record(identity) || !uuid(identity.id)) return fail("authentication_failed");
      actorID = identity.id;
    } catch {
      return fail("authentication_failed");
    }
    try {
      return await call("/rest/v1/rpc/prepare_bound_staff_invitation_resend", {
        method: "POST",
        headers: { apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_request_id: requestID, p_invitation_id: invitationID, p_actor_id: actorID }),
      }, async (response): Promise<BoundResendResult> => {
        const reply: unknown = await response.json();
        if (!response.ok) {
          if (response.status >= 400 && response.status < 500 && record(reply) &&
            ["22023", "42501", "23514"].includes(String(reply.code))) return fail("denied");
          return fail("preparation_uncertain");
        }
        if (!privateReply(reply, invitationID)) return fail("preparation_uncertain");
        return { ok: true, code: "prepared", preparation: Object.freeze({ ...reply }) };
      });
    } catch {
      // Dispatch may have committed the request journal. No retry or no-effect promise.
      return fail("preparation_uncertain");
    }
  }
  return { prepareBoundResend };
}
