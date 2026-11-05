import { isUuid, requireEnv } from "./config";

/**
 * Trusted-server capture boundary for the public vehicle-detail view metric.
 *
 * Only this server code holds the service-role key and only the page calls
 * this after a successful ficha load (see app/vehiculo/[id]/page.tsx). The
 * User-Agent filter runs before this function is ever scheduled; the database
 * enforces visibility and the rolling 24-hour dedup window itself. Never call
 * this from a client component and never expose SUPABASE_SERVICE_ROLE_KEY to
 * the browser.
 */
export async function recordVehicleView(
  vehicleId: string,
  browserToken: string,
): Promise<boolean> {
  if (!isUuid(vehicleId) || !isUuid(browserToken)) {
    throw new Error("Vehicle id and browser token must be UUIDs");
  }
  const base = requireEnv("SUPABASE_URL");
  const serviceKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
  const response = await fetch(`${base}/rest/v1/rpc/record_vehicle_view`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      p_vehicle_id: vehicleId,
      p_browser_token: browserToken,
    }),
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error(`Vehicle view capture failed with HTTP ${response.status}`);
  }
  return (await response.json()) === true;
}
