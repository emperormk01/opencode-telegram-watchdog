# OpenCode Telegram Watchdog

Scripts that bring up a localhost OpenCode server and its Telegram bridge
automatically on every assistant boot, and keep them alive afterwards.

## Boot chain

1. **`hooks/init.ts`** — assistant startup hook. Runs on every daemon boot.
   - Launches `bin/clean-data-caches.sh` (prunes regenerable caches; /data and
     /workspace share one storage volume).
   - Launches `bin/opencode-telegram-supervise` detached.
   - Every launch is guarded with an existence check: a missing binary is
     logged and skipped, never fatal to the assistant.
2. **`bin/opencode-telegram-supervise`** — idempotent supervisor.
   - Fetches the OpenCode server password from the assistant credential vault,
     retrying every 5s for up to 2 minutes (the vault may not be ready early
     in boot — do not remove the retry loop).
   - Single-instance via PID file; safe to launch on every boot.
   - Probes every 15s (`OPENCODE_TELEGRAM_SUPERVISOR_INTERVAL` to override)
     and (re)starts the server and bridge as needed.
3. **`bin/opencode-telegram-server`** — starts `opencode serve` on
   `127.0.0.1:4096`, auth from the vault at runtime.
4. **`bin/opencode-telegram-bridge`** — starts the Telegram bot bridge
   (`@grinev/opencode-telegram-bot`), bot token from the vault at runtime.
5. **`bin/opencode-telegram-restart`** — convenience restart helper.

## One-command setup

`./setup.sh` provisions everything on a fresh clone: real Node (the assistant
image only ships a Bun shim as `node`), the OpenCode CLI, the bridge package,
the pinned-message patch in `patches/`, the three vault secrets, deployment of
the launchers + init hook, and launches the supervisor. See `INSTALL.md` for
the full walkthrough and all gotchas.

## Runtime layout

- PID files and logs: `/workspace/data/opencode-telegram/{run,logs}`
- Supervisor log: `logs/supervisor.log` (healthy state logs
  `OK: server healthy, bridge running`)

## Supported environments

Tested on x86_64 Linux cloud VMs. Our deploy:

| Spec | Value |
|------|-------|
| CPU | Intel Xeon Platinum 8581C @ 2.30GHz (4 cores) |
| RAM | 6.1 GiB |
| OS | Debian GNU/Linux 13 (trixie) |
| Disk | 96G root, 5.9G virtiofs (`/workspace` + `/data` shared) |

Also works on GCP, AWS, Azure, Hetzner, DigitalOcean with >=4 GiB RAM.
Minimum: 2 vCPU, 4 GiB RAM, 20G disk, Node >=22.14. See `INSTALL.md` for
full specs.

**Windows:** Use WSL2. The scripts are bash-only with Linux paths. Clone
inside WSL2 (not `/mnt/c/`), install Node inside WSL2, run `setup.sh`.
See `INSTALL.md` > Windows (WSL2) for full instructions and gotchas.

## Secrets

No secrets are stored in these scripts. Everything is resolved at runtime via
`assistant credentials reveal` (services: `opencode`, `opencode_proxy`,
`telegram`).
