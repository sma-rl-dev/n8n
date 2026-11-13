# DEPLOY-SMA — n8n

> Source-build and browser-smoke notes for the `n8n` RL environment.

## Baseline Ref

- Upstream tag: `n8n@2.38.4`
- Commit: `d68d94af3ba54d11ff0f04adbb8ffd7aef4c01db`
- Branch in this fork: `tester-env-baseline` (upstream baseline + tester-env tooling)

## Quick Start

```bash
./tester-env deploy    # Build image from source, start container, wait for /healthz
./tester-env seed      # Populate with 3 deterministic workflows
./tester-env verify    # Assert seeded state via REST API
./tester-env reset     # Remove containers + SQLite volume (image preserved)
./tester-env stop      # Stop containers (preserves data)
./tester-env status    # Compose ps
./tester-env logs      # Tail container logs
```

Environment: `PORT` (default 18567), `RUN_ID` (isolates compose project/data),
`IMAGE_TAG` (default `tester-env-n8n:dev`; supplied by `scripts/rl-env` as a
content-addressed tag — honoured, never suffixed with `RUN_ID`).

## Build

`./tester-env deploy` runs `docker compose up --build` with
`Dockerfile.tester-env`: a two-stage Node 24 build (`pnpm build:deploy`
produces the compiled closure, `isolated-vm` prebuild is rebuilt against the
runtime ABI). Cold dependency fetch ~94s, first full source build ~5m.

## Run

- Local URL: `http://localhost:18567/`
- Health check: `GET /healthz` → 200
- Credentials (owner, managed by env): `admin@tester.local` / `password`
- Single SQLite store in named volume `n8n-data` (`/home/node/.n8n`)

## Deterministic Seed Data

- Seed command: `./tester-env seed` (via `scripts/seed-tester-env.sh`, REST API).
- Verify command: `./tester-env verify` (asserts 3 workflows with names, active states, tags, typed Set node fields, and one successful execution per workflow).
- Workflows: `Daily Sales Report` (active, tag `reporting`), `Support Ticket Triage` (inactive, tag `support`), `Inventory Low Stock Alert` (inactive, tag `inventory`).
- Set node assignments declare `type` (`string`/`number`) because Set v3.3+ validates the declared type at execution; an untyped assignment fails with `Cannot read properties of undefined (reading 'toLowerCase')`.
- Visible node output: `Summarize Orders` → `totalOrders=128`, `revenue=4520`; `Label Ticket` → `priority=high`, `team=support`; `Flag Low Stock` → `sku=ACME-WIDGET-42`, `stock=3`.
- Safe to re-run: existing workflow names are skipped.
- `verify` executes each workflow once, so it adds three execution records to the instance.

## Reset

```bash
./tester-env reset     # docker compose down -v for this RUN_ID project only
./tester-env deploy    # Recreate; /healthz returns 200
```

## Browser Smoke Test

1. Open `http://localhost:18567/` — login page loads without fatal errors.
2. Log in with `admin@tester.local` / `password`.
3. Create a workflow, rename it, execute it manually.
4. Reload and confirm the workflow persists.
5. Reset, redeploy, confirm the workflow is gone (clean state restored).
