-- The public server integration previously recorded as pending now exists: the
-- vehicle-detail page in apps/public records a view only after a successful
-- load, behind a server-side known-bot User-Agent filter, with the opaque
-- browser token minted at the server boundary (HTTP proof in
-- scripts/test-public-capture.py). Migrations are immutable history, so the
-- corrected contract statement lands here instead of editing the original file.
comment on function public.record_vehicle_view(uuid, uuid) is
  'Trusted-server ingestion only: true counts a view, false is a duplicate within rolling 24h. Called by the public vehicle-detail page after a successful load, behind a server-side known-bot User-Agent filter; never from the browser. No caller timestamps, identity checks or page/UA claims.';
