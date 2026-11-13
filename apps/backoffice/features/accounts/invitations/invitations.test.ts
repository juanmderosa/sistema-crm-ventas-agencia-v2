import assert from "node:assert/strict";
import { test } from "node:test";
import { createInvitationOnboardingService } from "./invitations.ts";

test("configuration and browser execution fail closed with fixed, secret-free diagnostics", () => {
  const invalidOrigins = [
    "",
    "not-url",
    "http://remote.test",
    "ftp://localhost",
    "https://user:secret@host.test",
    "https://host.test/path",
    "https://host.test?x=secret",
    "https://host.test#secret",
    "https://host.test/path/..",
    "https://host.test/?",
    "https://host.test/#",
    "https://ho\nst.test",
    "https://@host.test",
    "https://host.test\\",
  ];
  const invalid = [
    null,
    {},
    ...invalidOrigins.map((supabaseUrl) => ({ ...config, supabaseUrl })),
    ...["apiKey", "serviceRoleKey"].flatMap((key) =>
      ["", " ", 7, "bad\nkey"].map((value) => ({ ...config, [key]: value })),
    ),
  ];
  for (const value of invalid) {
    assert.throws(() => createInvitationOnboardingService(value as never), {
      message: "Configuración de invitaciones inválida.",
    });
  }
  for (const supabaseUrl of [
    "https://host.test",
    "http://localhost:54321",
    "http://[::1]:54321",
  ]) {
    assert.ok(createInvitationOnboardingService({ ...config, supabaseUrl }));
  }
  Object.defineProperty(globalThis, "window", {
    value: {},
    configurable: true,
  });
  try {
    assert.throws(() => createInvitationOnboardingService(config), {
      message: "El servicio requiere ejecución del lado del servidor.",
    });
  } finally {
    Reflect.deleteProperty(globalThis, "window");
  }
});

const config = {
  supabaseUrl: "http://127.0.0.1:54321",
  apiKey: "ordinary-key",
  serviceRoleKey: "private-service-key",
};
const id = "11111111-1111-4111-8111-111111111111";
const other = "22222222-2222-4222-8222-222222222222";
const input = {
  invitationID: other,
  hash: "private-hash",
  displayName: "  María 😀  ",
  password: "123456",
};
const session = "private-session";
const user = { id };
type Call = {
  url: string;
  method: string | undefined;
  body: unknown;
  headers: Headers;
  redirect: RequestRedirect | undefined;
  signal: AbortSignal | null | undefined;
};
type Step = unknown | Error | Response;
function setup(overrides: Record<number, Step> = {}) {
  const calls: Call[] = [];
  const steps: Step[] = [
    { access_token: session, user },
    user,
    id,
    user,
    new Response(null, { status: 204 }),
    id,
  ];
  const fetcher: typeof fetch = async (url, init) => {
    const index = calls.length;
    calls.push({
      url: String(url),
      method: init?.method,
      body: init?.body ? JSON.parse(String(init.body)) : null,
      headers: new Headers(init?.headers),
      redirect: init?.redirect,
      signal: init?.signal,
    });
    const step = Object.hasOwn(overrides, index)
      ? overrides[index]
      : steps[index];
    if (step instanceof Error) throw step;
    return step instanceof Response ? step : Response.json(step);
  };
  return { calls, service: createInvitationOnboardingService(config, fetcher) };
}
for (const method of ["acceptInvite", "recoverInterrupted"] as const) {
  test(`${method}: every rejected or uncertain password update requires cleanup and never completes`, async () => {
    for (const [value, code] of [
      [reject(), "password_rejected"],
      [new Error("timeout private"), "password_update_uncertain"],
      [new Response("bad"), "password_update_uncertain"],
      [{}, "password_update_uncertain"],
      [{ id: other }, "password_update_uncertain"],
    ] as const) {
      const { service, calls } = setup({ 3: value });
      assert.deepEqual(await service[method](input), failed(code));
      assert.deepEqual(
        calls.map((c) => c.url),
        paths.slice(0, 5).map((p) => config.supabaseUrl + p),
      );
    }
  });
  test(`${method}: required logout failure overrides update outcome and blocks completion`, async () => {
    for (const update of [user, reject(), new Error("private timeout")]) {
      for (const logout of [reject(), new Error("private logout")]) {
        const { service, calls } = setup({ 3: update, 4: logout });
        assert.deepEqual(
          await service[method](input),
          failed("session_revocation_failed"),
        );
        assert.equal(calls.length, 5);
      }
    }
  });
}

test("each request has a fresh finite ten-second timeout", async (context) => {
  const durations: number[] = [];
  const timeout = AbortSignal.timeout.bind(AbortSignal);
  context.mock.method(AbortSignal, "timeout", (milliseconds: number) => {
    durations.push(milliseconds);
    return timeout(milliseconds);
  });
  const { service, calls } = setup();
  assert.deepEqual(await service.acceptInvite(input), { ok: true });
  assert.deepEqual(durations, Array(6).fill(10_000));
  assert.equal(new Set(calls.map((c) => c.signal)).size, 6);
});

test("completion rejection and uncertain transport/payload never falsely report success", async () => {
  for (const [value, code] of [
    [reject(), "completion_rejected"],
    [new Error("private committed?"), "completion_uncertain"],
    [new Response("bad"), "completion_uncertain"],
    [other, "completion_uncertain"],
    [{ id }, "completion_uncertain"],
  ] as const) {
    const { service, calls } = setup({ 5: value });
    assert.deepEqual(await service.acceptInvite(input), failed(code));
    assert.equal(calls.length, 6);
  }
});

const paths = [
  "/auth/v1/verify",
  "/auth/v1/user",
  "/rest/v1/rpc/check_staff_invitation_acceptance",
  "/auth/v1/user",
  "/auth/v1/logout?scope=global",
  "/rest/v1/rpc/complete_staff_invitation",
];
function failed(code: string) {
  return { ok: false, code };
}

for (const method of ["acceptInvite", "recoverInterrupted"] as const) {
  for (const verification of [
    reject,
    () => ({}),
    () => ({ access_token: "" }),
    () => new Response("not-json"),
    () => new Error("private token and provider error"),
  ]) {
    test(`${method}: invalid/replayed/malformed verification is redacted`, async () => {
      const { service, calls } = setup({ 0: verification() });
      assert.deepEqual(await service[method](input), failed("invalid_token"));
      assert.equal(calls.length, 1);
    });
  }
}

test("verified session identity must be structural and corroborated, never caller asserted", async () => {
  for (const [stage, value] of [
    [0, { access_token: session }],
    [0, { access_token: session, user: { id: "bad" } }],
    [1, { id: other }],
    [1, {}],
    [1, reject()],
    [1, new Error("private identity")],
  ] as const) {
    const { service, calls } = setup({
      [stage]: value,
      [stage + 1]: new Response(null, { status: 204 }),
    });
    assert.deepEqual(
      await service.acceptInvite(input),
      failed("invalid_identity"),
    );
    assert.equal(calls.length, stage + 2);
    assert.equal(calls.at(-1)?.url, config.supabaseUrl + paths[4]);
    assert.equal(
      calls.at(-1)?.headers.get("authorization"),
      `Bearer ${session}`,
    );
  }
});

test("wrong, revoked, mismatched or uncertain preflight prevents password and completion", async () => {
  for (const value of [
    reject(),
    other,
    { id },
    null,
    new Error("private preflight"),
    new Response("bad"),
  ]) {
    const { service, calls } = setup({
      2: value,
      3: new Response(null, { status: 204 }),
    });
    assert.deepEqual(
      await service.recoverInterrupted(input),
      failed("preflight_rejected"),
    );
    assert.deepEqual(
      calls.map((c) => c.url),
      [0, 1, 2, 4].map((i) => config.supabaseUrl + paths[i]),
    );
  }
});
function reject() {
  return new Response("private provider secret", { status: 403 });
}

for (const method of ["acceptInvite", "recoverInterrupted"] as const) {
  test(`${method}: exact ordered requests, private credentials and fixed success`, async () => {
    const { service, calls } = setup();
    const supplied = {
      ...input,
      userID: other,
      role: "owner",
      type: "signup",
      access_token: "caller-token",
    };
    assert.deepEqual(await service[method](supplied), { ok: true });
    assert.deepEqual(
      calls.map((c) => c.url),
      paths.map((p) => config.supabaseUrl + p),
    );
    assert.deepEqual(
      calls.map((c) => c.method),
      ["POST", "GET", "POST", "PUT", "POST", "POST"],
    );
    const rpc = {
      p_invitation_id: other,
      p_user_id: id,
      p_display_name: input.displayName,
    };
    assert.deepEqual(
      calls.map((c) => c.body),
      [
        {
          token_hash: input.hash,
          type: method === "acceptInvite" ? "invite" : "recovery",
        },
        null,
        rpc,
        { password: input.password },
        null,
        rpc,
      ],
    );
    for (const [i, call] of calls.entries()) {
      const privileged = i === 2 || i === 5;
      assert.equal(
        call.headers.get("apikey"),
        privileged ? config.serviceRoleKey : config.apiKey,
      );
      assert.equal(
        call.headers.get("authorization"),
        privileged
          ? `Bearer ${config.serviceRoleKey}`
          : i === 0
            ? null
            : `Bearer ${session}`,
      );
      assert.equal(call.headers.get("content-type"), "application/json");
      assert.equal(call.redirect, "error");
      assert.ok(call.signal instanceof AbortSignal);
      assert.equal(call.signal.aborted, false);
    }
  });
}

test("runtime validation precedes token consumption; Unicode code points and original name survive", async () => {
  const invalid = [
    null,
    {},
    { ...input, invitationID: "bad" },
    { ...input, hash: "" },
    { ...input, hash: "a b" },
    { ...input, hash: "x".repeat(2049) },
    { ...input, hash: 3 },
    { ...input, displayName: " \t\n" },
    { ...input, displayName: null },
    { ...input, displayName: "😀".repeat(201) },
    { ...input, password: "12345" },
    { ...input, password: null },
    { ...input, displayName: "\u0000" },
    { ...input, displayName: "\ud800" },
  ];
  for (const value of invalid) {
    const { service, calls } = setup();
    for (const method of ["acceptInvite", "recoverInterrupted"] as const) {
      assert.deepEqual(
        await service[method](value as never),
        failed("invalid_input"),
      );
    }
    assert.equal(calls.length, 0);
  }
  const { service, calls } = setup();
  assert.deepEqual(
    await service.acceptInvite({ ...input, displayName: "😀".repeat(200) }),
    { ok: true },
  );
  assert.equal(
    (calls[2].body as { p_display_name: string }).p_display_name,
    "😀".repeat(200),
  );
});
