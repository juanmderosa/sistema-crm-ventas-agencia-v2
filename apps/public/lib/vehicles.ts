import { isUuid, requireEnv } from "./config";

export type PublicVehicle = {
  id: string;
  brand: string;
  model: string;
  version: string | null;
  year: number;
  mileage_km: number;
  availability_status: "available" | "reserved" | "sold";
};

/**
 * Loads a vehicle through the anonymous role so the database's own row-level
 * security decides public visibility (published, not soft-deleted and
 * sale-enabled). Draft, blocked and deleted rows never reach this function,
 * so the page reports 404 for them and nothing is captured.
 */
export async function loadPublishedVehicle(
  id: string,
): Promise<PublicVehicle | null> {
  if (!isUuid(id)) {
    return null;
  }
  const base = requireEnv("SUPABASE_URL");
  const anonKey = requireEnv("SUPABASE_ANON_KEY");
  const url =
    `${base}/rest/v1/vehicles?id=eq.${id}` +
    "&select=id,brand,model,version,year,mileage_km,availability_status&limit=1";
  const response = await fetch(url, {
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${anonKey}`,
    },
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error(`Vehicle load failed with HTTP ${response.status}`);
  }
  const rows = (await response.json()) as PublicVehicle[];
  return rows[0] ?? null;
}
