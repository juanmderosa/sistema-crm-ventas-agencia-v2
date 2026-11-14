import assert from "node:assert/strict";
import { test } from "node:test";
import { createInvitationManagementService } from "./management.ts";

const invitationID = "11111111-1111-4111-8111-111111111111";
const actorID = "22222222-2222-4222-8222-222222222222";
const userID = "33333333-3333-4333-8333-333333333333";
const requestID = "44444444-4444-4444-8444-444444444444";
const config = { supabaseUrl: "https://trusted.test/", apiKey: "ordinary-key", serviceRoleKey: "root-secret" };
const input = { requestID, invitationID, actorAccessToken: "caller-session" };
const payload = { invitation_id: invitationID, email: "pending@example.test", role: "seller",
  provenance: requestID, user_id: userID, candidate_user_id: userID };
const failed = (code: string) => ({ ok: false, code });
function harness(replies: (() => Response | Promise<Response>)[] = []) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, init) => {
    calls.push({ url: String(url), init: init! });
    const reply = replies[calls.length - 1];
    return reply ? reply() : Response.json(calls.length === 1 ? { id: actorID } : payload);
  };
  return { calls, fetcher, service: createInvitationManagementService(config, fetcher) };
}
function assertCalls(calls: ReturnType<typeof harness>["calls"], count: number) {
  assert.equal(calls.length, count);
  assert.deepEqual(calls.map((c) => ({ url: c.url, method: c.init.method,
    headers: Object.fromEntries(new Headers(c.init.headers)), body: c.init.body, redirect: c.init.redirect })), [
    { url: "https://trusted.test/auth/v1/user", method: "GET", redirect: "error", body: undefined,
      headers: { apikey: "ordinary-key", authorization: "Bearer caller-session", "content-type": "application/json" } },
    { url: "https://trusted.test/rest/v1/rpc/prepare_bound_staff_invitation_resend", method: "POST", redirect: "error",
      headers: { apikey: "root-secret", authorization: "Bearer root-secret", "content-type": "application/json" },
      body: JSON.stringify({ p_request_id: requestID, p_invitation_id: invitationID, p_actor_id: actorID }) },
  ].slice(0, count));
}

test("prepares only, using authenticated top-level id, never caller/provider metadata authority", async () => {
  const h = harness([() => Response.json({ id: actorID, role: "seller", email: "untrusted@example.test",
    user_metadata: { id: userID, role: "owner" }, app_metadata: { role: "owner" } })]);
  const result = await h.service.prepareBoundResend({ ...input, actorID: userID, role: "owner" } as typeof input);
  assert.deepEqual(result, { ok: true, code: "prepared", preparation: payload });
  assert.deepEqual(Object.keys(h.service), ["prepareBoundResend"]);
  assertCalls(h.calls, 2);
  if (!result.ok) assert.fail("expected private preparation");
  assert.ok(Object.isFrozen(result.preparation));
  assert.throws(() => Object.assign(result.preparation, { email: "changed@example.test" }), TypeError);
});

test("accepts private Admin reply at canonical email length boundary", async () => {
  const preparation = { ...payload, role: "admin", email: `${"a".repeat(247)}@b.test` };
  assert.equal(preparation.email.length, 254);
  const h = harness([() => Response.json({ id: actorID }), () => Response.json(preparation)]);
  assert.deepEqual(await h.service.prepareBoundResend(input), { ok: true, code: "prepared", preparation });
  assertCalls(h.calls, 2);
});

test("lost response after simulated journal persistence is uncertain without retry", async () => {
  const journal: string[] = [];
  const h = harness([() => Response.json({ id: actorID }), () => {
    journal.push(requestID);
    throw new Error("provider-private root-secret caller-session");
  }]);
  assert.deepEqual(await h.service.prepareBoundResend(input), failed("preparation_uncertain"));
  assert.deepEqual(journal, [requestID]);
  assertCalls(h.calls, 2);
});

test("snapshots input before await and config at construction", async () => {
  const mutableConfig = { ...config };
  const mutableInput = { ...input };
  let release!: (response: Response) => void;
  const h = harness([() => new Promise<Response>((resolve) => { release = resolve; })]);
  const service = createInvitationManagementService(mutableConfig, h.fetcher);
  Object.assign(mutableConfig, { supabaseUrl: "https://evil.test", apiKey: "other", serviceRoleKey: "other-root" });
  const pending = service.prepareBoundResend(mutableInput);
  Object.assign(mutableInput, { requestID: userID, invitationID: userID, actorAccessToken: "other-session" });
  release(Response.json({ id: actorID }));
  assert.deepEqual(await pending, { ok: true, code: "prepared", preparation: payload });
  assertCalls(h.calls, 2);
});

for (const patch of [{ requestID: "bad" }, { invitationID: null }, { actorAccessToken: "" },
  { actorAccessToken: "line\nbreak" }, { actorAccessToken: "space token" }]) {
  test(`invalid input ${JSON.stringify(patch)} makes no request`, async () => {
    const h = harness();
    assert.deepEqual(await h.service.prepareBoundResend({ ...input, ...patch } as typeof input), failed("invalid_input"));
    assertCalls(h.calls, 0);
  });
}
for (const auth of [null, [], {}, { id: "bad" }, { user: { id: actorID } },
  { user_metadata: { id: actorID } }]) {
  test(`malformed authenticated user ${JSON.stringify(auth)} never reaches root`, async () => {
    const h = harness([() => Response.json(auth)]);
    assert.deepEqual(await h.service.prepareBoundResend(input), failed("authentication_failed"));
    assertCalls(h.calls, 1);
  });
}
for (const reply of [() => new Response("caller-session root-secret provider-private", { status: 401 }),
  () => new Response("not json"), () => { throw new Error("caller-session root-secret provider-private"); }]) {
  test("authentication failure is fixed and redacted with no privileged request", async () => {
    const h = harness([reply]);
    assert.deepEqual(await h.service.prepareBoundResend(input), failed("authentication_failed"));
    assertCalls(h.calls, 1);
  });
}
const invalidPayloads: unknown[] = [null, [], { ...payload, extra: "private" },
  ...Object.keys(payload).map((key) => Object.fromEntries(Object.entries(payload).filter(([k]) => k !== key))),
  ...["owner", "Admin", null].map((role) => ({ ...payload, role })),
  ...[" Pending@example.test", "Pending@example.test", "no-at", "a@b", "a@b. c", `${"a".repeat(250)}@b.test`]
    .map((email) => ({ ...payload, email })),
  { ...payload, invitation_id: requestID }, { ...payload, user_id: null },
  { ...payload, candidate_user_id: actorID }, { ...payload, provenance: "bad" }];
for (const [index, value] of invalidPayloads.entries()) {
  test(`invalid private reply ${index} is uncertain, never claims no journal effect`, async () => {
    const h = harness([() => Response.json({ id: actorID }), () => Response.json(value)]);
    assert.deepEqual(await h.service.prepareBoundResend(input), failed("preparation_uncertain"));
    assertCalls(h.calls, 2);
  });
}
for (const code of ["22023", "42501", "23514"]) {
  test(`recognized SQL rejection ${code} is fixed and redacted`, async () => {
    const h = harness([() => Response.json({ id: actorID }),
      () => Response.json({ code, message: "root-secret caller-session provider-private" }, { status: 400 })]);
    assert.deepEqual(await h.service.prepareBoundResend(input), failed("denied"));
    assertCalls(h.calls, 2);
  });
}
for (const reply of [() => { throw new Error("root-secret caller-session provider-private"); },
  () => new Response("not json"), () => new Response("private", { status: 502 }),
  () => Response.json({ code: "unknown", message: "private" }, { status: 400 })]) {
  test("lost or unrecognized RPC reply may have journaled and is never retried", async () => {
    const h = harness([() => Response.json({ id: actorID }), reply]);
    assert.deepEqual(await h.service.prepareBoundResend(input), failed("preparation_uncertain"));
    assertCalls(h.calls, 2);
  });
}

test("fresh independent 10s deadlines cover response bodies and clear on completion", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const h = harness();
  assert.deepEqual(await h.service.prepareBoundResend(input), { ok: true, code: "prepared", preparation: payload });
  const signals = h.calls.map((c) => c.init.signal!);
  assert.notEqual(signals[0], signals[1]);
  t.mock.timers.tick(10_000);
  assert.deepEqual(signals.map((s) => s.aborted), [false, false]);
  for (const stage of [0, 1]) {
    const stalled = harness();
    let entered!: () => void;
    const waiting = new Promise<void>((resolve) => { entered = resolve; });
    const fetcher: typeof fetch = async (url, init) => {
      if (String(url).includes(stage === 0 ? "/auth/" : "/rest/")) {
        entered();
        return { ok: true, json: () => new Promise((_, reject) => {
          init!.signal!.addEventListener("abort", () => reject(new Error("private timeout")), { once: true });
        }) } as Response;
      }
      return stalled.fetcher(url, init);
    };
    const pending = createInvitationManagementService(config, fetcher).prepareBoundResend(input);
    await waiting;
    t.mock.timers.tick(9999);
    let finished = false;
    void pending.then(() => { finished = true; });
    await Promise.resolve();
    assert.equal(finished, false);
    t.mock.timers.tick(1);
    assert.deepEqual(await pending, failed(stage === 0 ? "authentication_failed" : "preparation_uncertain"));
  }
});

for (const supabaseUrl of ["https://trusted.test/path", "https://user:pass@trusted.test", "https://trusted.test/?x",
  "https://trusted.test/#x", "http://remote.test", "https://trusted.test/..", "https://trusted.test\\evil", " https://trusted.test"]) {
  test(`rejects untrusted origin ${supabaseUrl} at construction`, () => {
    assert.throws(() => createInvitationManagementService({ ...config, supabaseUrl }),
      { message: "Invalid invitation management configuration." });
  });
}
test("construction validates credentials, accepts loopback, rejects browser use", () => {
  for (const key of ["apiKey", "serviceRoleKey"]) {
    for (const value of ["", "bad\nkey", undefined]) {
      assert.throws(() => createInvitationManagementService({ ...config, [key]: value } as typeof config),
        { message: "Invalid invitation management configuration." });
    }
  }
  for (const supabaseUrl of ["http://localhost:54321", "http://127.0.0.1:54321", "http://[::1]:54321"]) {
    assert.ok(createInvitationManagementService({ ...config, supabaseUrl }));
  }
  Object.defineProperty(globalThis, "window", { value: {}, configurable: true });
  try {
    assert.throws(() => createInvitationManagementService(config), { message: "Invitation management requires server execution." });
  } finally {
    Reflect.deleteProperty(globalThis, "window");
  }
});
