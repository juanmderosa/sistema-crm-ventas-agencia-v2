import assert from "node:assert/strict";
import { test } from "node:test";
import { createInvitationOnboardingService } from "./invitations.ts";

const id = "11111111-1111-4111-8111-111111111111";
for (const method of ["acceptInvite", "recoverInterrupted"] as const) {
  test(`${method}: captured configuration and awaited global cleanup at input limits`, {
    timeout: 5000,
  }, async () => {
    const config = {
      supabaseUrl: "https://trusted.test",
      apiKey: "ordinary",
      serviceRoleKey: "privileged",
    };
    const input = {
      invitationID: id, hash: "x".repeat(2048),
      displayName: "😀".repeat(200), password: "123456",
    };
    let release!: () => void;
    let entered!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const waiting = new Promise<void>((resolve) => { entered = resolve; });
    const calls: { url: string; init: RequestInit }[] = [];
    const fetcher: typeof fetch = async (url, init) => {
      calls.push({ url: String(url), init: init! });
      const number = calls.length;
      if (number === 5) {
        entered();
        await gate;
        return new Response(null, { status: 204 });
      }
      return Response.json(number === 1 ? { access_token: "session", user: { id } }
        : number === 2 || number === 4 ? { id } : id);
    };
    const service = createInvitationOnboardingService(config, fetcher);
    Object.assign(config, { supabaseUrl: "https://attacker.test",
      apiKey: "changed", serviceRoleKey: "changed-private" });
    let finished = false;
    const pending = service[method](input).then((result) => {
      finished = true;
      return result;
    });
    await waiting;
    assert.equal(finished, false);
    assert.equal(calls.length, 5);
    release();
    assert.deepEqual(await pending, { ok: true });
    const paths = ["/auth/v1/verify", "/auth/v1/user",
      "/rest/v1/rpc/check_staff_invitation_acceptance", "/auth/v1/user",
      "/auth/v1/logout?scope=global", "/rest/v1/rpc/complete_staff_invitation"];
    assert.deepEqual(calls.map((c) => c.url), paths.map((p) => "https://trusted.test" + p));
    assert.deepEqual(calls.map((c) => c.init.method), ["POST", "GET", "POST", "PUT", "POST", "POST"]);
    const rpc = { p_invitation_id: id, p_user_id: id, p_display_name: input.displayName };
    assert.deepEqual(calls.map((c) => c.init.body ? JSON.parse(String(c.init.body)) : null), [
      { token_hash: input.hash, type: method === "acceptInvite" ? "invite" : "recovery" },
      null, rpc, { password: input.password }, null, rpc,
    ]);
    for (const [index, call] of calls.entries()) {
      const headers = new Headers(call.init.headers);
      const privileged = index === 2 || index === 5;
      assert.equal(headers.get("apikey"), privileged ? "privileged" : "ordinary");
      assert.equal(headers.get("authorization"), privileged ? "Bearer privileged"
        : index === 0 ? null : "Bearer session");
      assert.equal(call.init.redirect, "error");
      assert.ok(call.init.signal instanceof AbortSignal);
    }
  });
}
