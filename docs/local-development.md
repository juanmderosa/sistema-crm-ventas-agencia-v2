# Local development: initial shell

The two application shells run on loopback only. They contain no dealership data, login, persistence or privileged operations. The backoffice landing page is **not** a protected application: do not add private features until backend authentication, authorization and database policies are implemented and verified.

## Start the shells

1. Install Node.js 20.9 or newer and pnpm 10.18.3. From the repository root, run `pnpm install --frozen-lockfile`.
2. Run `pnpm dev:public` and `pnpm dev:backoffice` in separate terminals.
3. Open `http://127.0.0.1:3000` for the public shell and `http://127.0.0.1:3001` for the backoffice shell. Only placeholder pages are expected.

Run `pnpm typecheck` and `pnpm build` to check the shells. Do not put real customer data, privileged keys or draft images in them.

If PowerShell refuses to run a `.ps1` shim because script execution is disabled, call the batch shim explicitly: `pnpm.cmd typecheck`. This machine installs pnpm with only a `.cmd` shim, so plain `pnpm` already works there; npm is not so lucky because it ships `npm.ps1`.

pnpm blocks dependency build scripts by default and reports `sharp` as ignored. That warning is expected for now, but image optimization must be verified before adding vehicle photos; run `pnpm approve-builds` only after reviewing the package that needs it.

## Local backend

Supabase runs locally through the pinned CLI (`supabase@3.0.0`) and requires Docker Desktop to be started first. Verified on this machine: `pnpm db:start`, `pnpm db:status`, REST `200`, Auth health `200` and signup rejected with `422`.

| Command | Purpose |
|---|---|
| `pnpm db:start` | Start the local stack (Postgres, Auth, REST, Storage, Studio, Mailpit) |
| `pnpm db:status` | Print local URLs and keys; use `-o json` for scripts |
| `pnpm db:reset` | Reapply migrations and `supabase/seed.sql` from scratch |
| `pnpm db:stop` | Stop the containers |

| Service | Local URL |
|---|---|
| API / REST | `http://127.0.0.1:55321` |
| Database | `postgresql://postgres:postgres@127.0.0.1:55322/postgres` |
| Studio | `http://127.0.0.1:55323` |
| Mailpit (captured email) | `http://127.0.0.1:55324` |

Ports are shifted from Supabase's defaults because Windows reserves TCP `54079-54578` on this host (`netsh interface ipv4 show excludedportrange protocol=tcp`), which made the default `5432x` ports fail to bind. Keep `supabase/config.toml` as the source of truth.

Two hardening defaults are set in `supabase/config.toml`: `api.auto_expose_new_tables = false`, so new tables need explicit grants, and `auth.enable_signup = false`, because the MVP has no public registration and the initial Owner is created by a controlled script. Local keys printed by `db:status` are throwaway development credentials; do not reuse them outside the local stack.

## Still missing

No schema migrations, database policies, Auth bootstrap or business flows exist yet. The applications do not connect to the local backend. Hosting, email delivery, storage quotas and recovery remain separate pilot validation gates; local success does not prove free-tier viability.
