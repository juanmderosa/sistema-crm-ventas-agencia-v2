import { after } from "next/server";
import { headers } from "next/headers";
import Link from "next/link";
import { notFound } from "next/navigation";

import { isKnownBotUa } from "@/lib/bots";
import { isUuid } from "@/lib/config";
import { recordVehicleView } from "@/lib/capture";
import { loadPublishedVehicle, type PublicVehicle } from "@/lib/vehicles";

const AVAILABILITY_LABELS: Record<PublicVehicle["availability_status"], string> =
  {
    available: "Disponible",
    reserved: "Reservado",
    sold: "Vendido",
  };

export default async function VehicleDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const vehicle = await loadPublishedVehicle(id);
  if (!vehicle) {
    notFound();
  }

  const requestHeaders = await headers();
  const userAgent = requestHeaders.get("user-agent");
  const browserToken = requestHeaders.get("x-bv-token");
  const vehicleId = vehicle.id;

  // A view is the successful load of this public ficha, never a catalog
  // appearance (docs/product-plan.md). The capture runs after this response
  // has been sent, only from this trusted server boundary, and never for
  // known bot User-Agents; identity is never verified.
  if (!isKnownBotUa(userAgent) && isUuid(browserToken)) {
    after(async () => {
      try {
        await recordVehicleView(vehicleId, browserToken);
      } catch (error) {
        // A metric must never break an already-served ficha. Log the failure
        // without the User-Agent or any other personal data.
        console.error(
          "vehicle view capture failed",
          error instanceof Error ? error.message : String(error),
        );
      }
    });
  }

  const title =
    `${vehicle.brand} ${vehicle.model}` +
    (vehicle.version ? ` ${vehicle.version}` : "");

  return (
    <main>
      <h1>{title}</h1>
      <p>
        {vehicle.year} · {vehicle.mileage_km.toLocaleString("es-AR")} km
      </p>
      <p>Estado: {AVAILABILITY_LABELS[vehicle.availability_status]}</p>
      <p>
        <Link href="/">Volver al catálogo</Link>
      </p>
    </main>
  );
}
