import { NextResponse, type NextRequest } from "next/server";

const TOKEN_COOKIE = "bv_token";
const TOKEN_HEADER = "x-bv-token";
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Longer than the rolling 24-hour dedup window so a returning browser keeps
// the same opaque token; the database window remains the counting authority.
const TOKEN_MAX_AGE_SECONDS = 60 * 60 * 24 * 30;

// Mints the opaque per-browser view token at the network boundary. The Server
// Component reads it from a request header this proxy overwrites on every
// request, so a client can never supply its own value. The token is a random
// UUID with no personal data, per the approved statistics definitions.
export function proxy(request: NextRequest) {
  const existing = request.cookies.get(TOKEN_COOKIE)?.value;
  const isValid = existing !== undefined && UUID_PATTERN.test(existing);
  const token = isValid ? existing : crypto.randomUUID();

  const forwarded = new Headers(request.headers);
  forwarded.set(TOKEN_HEADER, token);

  const response = NextResponse.next({ request: { headers: forwarded } });
  if (!isValid) {
    response.cookies.set({
      name: TOKEN_COOKIE,
      value: token,
      path: "/",
      httpOnly: true,
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
      maxAge: TOKEN_MAX_AGE_SECONDS,
    });
  }
  return response;
}

export const config = {
  matcher: ["/vehiculo/:path*"],
};
