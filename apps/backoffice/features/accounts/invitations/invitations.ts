// Server-only orchestration. SQL remains authoritative for identity, role and retries.
export type InvitationOnboardingConfig = {
  supabaseUrl: string;
  apiKey: string;
  serviceRoleKey: string;
};
export type InvitationOnboardingInput = {
  invitationID: string;
  hash: string;
  displayName: string;
  password: string;
};
export type InvitationOnboardingFailure =
  | "invalid_input"
  | "invalid_token"
  | "invalid_identity"
  | "preflight_rejected"
  | "password_rejected"
  | "password_update_uncertain"
  | "session_revocation_failed"
  | "completion_rejected"
  | "completion_uncertain";
export type InvitationOnboardingResult =
  | { ok: true }
  | { ok: false; code: InvitationOnboardingFailure };
const fail = (
  code: InvitationOnboardingFailure,
): InvitationOnboardingResult => ({ ok: false, code });
const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const credential = (value: unknown): value is string =>
  typeof value === "string" && /^[\x21-\x7e]+$/.test(value);
function record(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
function userID(value: unknown): string | undefined {
  return record(value) && uuid(value.id) ? value.id : undefined;
}
function trustedOrigin(value: unknown): string {
  // Reject syntax before URL normalization can erase paths or control characters.
  if (
    typeof value !== "string" ||
    !/^[a-z]+:\/\/[^/?#@\\]+\/?$/i.test(value) ||
    /[\u0000-\u0020\u007f]/.test(value)
  )
    throw new Error();
  const url = new URL(value);
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    url.username ||
    url.password ||
    url.pathname !== "/" ||
    url.search ||
    url.hash ||
    (url.protocol !== "https:" && !(url.protocol === "http:" && loopback))
  )
    throw new Error();
  return url.origin;
}
function validInput(value: unknown): value is InvitationOnboardingInput {
  if (!record(value)) return false;
  const { invitationID, hash, displayName, password } = value;
  return (
    uuid(invitationID) &&
    typeof hash === "string" &&
    !!hash &&
    hash.length <= 2048 &&
    !/\s/.test(hash) &&
    typeof displayName === "string" &&
    !!displayName.trim() &&
    [...displayName].length <= 200 &&
    !/\u0000|[\uD800-\uDFFF]/u.test(displayName) &&
    typeof password === "string" &&
    password.length >= 6
  );
}

export function createInvitationOnboardingService(
  config: InvitationOnboardingConfig,
  fetcher: typeof fetch = fetch,
) {
  if (typeof window !== "undefined")
    throw new Error("El servicio requiere ejecución del lado del servidor.");
  let base: string;
  let apiKey: string;
  let serviceRoleKey: string;
  try {
    if (
      !record(config) ||
      !credential(config.apiKey) ||
      !credential(config.serviceRoleKey)
    )
      throw new Error();
    base = trustedOrigin(config.supabaseUrl);
    // Snapshot secrets so later mutation of the configuration cannot reroute requests.
    apiKey = config.apiKey;
    serviceRoleKey = config.serviceRoleKey;
  } catch {
    throw new Error("Configuración de invitaciones inválida.");
  }

  async function call(
    path: string,
    method: string,
    body?: unknown,
    token?: string,
    privileged = false,
  ) {
    return fetcher(`${base}${path}`, {
      method,
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
      headers: {
        apikey: privileged ? serviceRoleKey : apiKey,
        "Content-Type": "application/json",
        ...(privileged || token
          ? { Authorization: `Bearer ${privileged ? serviceRoleKey : token}` }
          : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  }
  async function discard(response: Response) {
    await response.body?.cancel();
  }
  async function revoke(token: string): Promise<boolean> {
    try {
      const response = await call(
        "/auth/v1/logout?scope=global",
        "POST",
        undefined,
        token,
      );
      await discard(response);
      return response.ok;
    } catch {
      return false;
    }
  }
  async function complete(
    input: InvitationOnboardingInput,
    type: "invite" | "recovery",
  ): Promise<InvitationOnboardingResult> {
    if (!validInput(input)) return fail("invalid_input");
    // Retain original name, including whitespace, for SQL's permanent exact retry.
    const { invitationID, hash, displayName, password } = input;
    let token: string;
    let verifiedID: string | undefined;
    try {
      const response = await call("/auth/v1/verify", "POST", {
        token_hash: hash,
        type,
      });
      if (!response.ok) {
        await discard(response);
        return fail("invalid_token");
      }
      const payload: unknown = await response.json();
      if (!record(payload) || !credential(payload.access_token))
        return fail("invalid_token");
      token = payload.access_token;
      verifiedID = userID(payload.user);
    } catch {
      return fail("invalid_token");
    }

    let failure: InvitationOnboardingFailure | undefined;
    let identity: string | undefined;
    if (!verifiedID) failure = "invalid_identity";
    else {
      try {
        const response = await call("/auth/v1/user", "GET", undefined, token);
        if (!response.ok) {
          await discard(response);
          failure = "invalid_identity";
        } else {
          identity = userID(await response.json());
          if (identity !== verifiedID) failure = "invalid_identity";
        }
      } catch {
        failure = "invalid_identity";
      }
    }
    const parameters = {
      p_invitation_id: invitationID,
      p_user_id: identity,
      p_display_name: displayName,
    };
    if (!failure) {
      try {
        const response = await call(
          "/rest/v1/rpc/check_staff_invitation_acceptance",
          "POST",
          parameters,
          undefined,
          true,
        );
        if (!response.ok) {
          await discard(response);
          failure = "preflight_rejected";
        } else if ((await response.json()) !== identity)
          failure = "preflight_rejected";
      } catch {
        failure = "preflight_rejected";
      }
    }
    if (!failure) {
      try {
        const response = await call(
          "/auth/v1/user",
          "PUT",
          { password },
          token,
        );
        if (!response.ok) {
          await discard(response);
          failure = "password_rejected";
        } else if (userID(await response.json()) !== identity)
          failure = "password_update_uncertain";
      } catch {
        failure = "password_update_uncertain";
      }
    }
    // Both paths revoke consumed sessions, even on failed identity/preflight/update.
    // Never activate after uncertain password persistence or failed cleanup.
    if (!(await revoke(token))) return fail("session_revocation_failed");
    if (failure) return fail(failure);
    try {
      const response = await call(
        "/rest/v1/rpc/complete_staff_invitation",
        "POST",
        parameters,
        undefined,
        true,
      );
      if (!response.ok) {
        await discard(response);
        return fail("completion_rejected");
      }
      if ((await response.json()) !== identity)
        return fail("completion_uncertain");
      return { ok: true };
    } catch {
      // The transaction may have committed; never promise absence of a profile.
      return fail("completion_uncertain");
    }
  }
  return {
    acceptInvite: (input: InvitationOnboardingInput) =>
      complete(input, "invite"),
    recoverInterrupted: (input: InvitationOnboardingInput) =>
      complete(input, "recovery"),
  };
}
