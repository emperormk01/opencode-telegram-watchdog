# INSTALL.md — OpenCode Telegram Startup Chain

Clean-room install guide for bringing up the boot chain on a fresh Vellum
Assistant workspace. Written from the actual first deployment — every
section below is a gotcha that bit us the first time, so read the whole thing
before running anything.

**Target end state:** on every assistant boot, an OpenCode server runs on
`127.0.0.1:4096` and a Telegram bot bridge is connected, with a supervisor
keeping both alive. Healthy steady state = the supervisor log repeats
`OK: server healthy, bridge running` on a 15s cadence.

---

## Quick start (recommended)

Skip the manual steps below — `setup.sh` does all of it in one shot: fetches a
**real** Node (the image's `/usr/local/bin/node` is only a Bun shim), installs
OpenCode + the bridge, applies the pinned-message patch, prompts for the three
vault secrets, deploys the launchers + init hook, and launches the supervisor.
Idempotent and safe to re-run.

```bash
cd /workspace/opencode-telegram-startup
./setup.sh
```

Before running, edit `bin/opencode-telegram-bridge` and set
`TELEGRAM_ALLOWED_USER_ID` to the owner's numeric Telegram user id. The 3
secrets are collected via `assistant credentials prompt` (secure UI popups,
never chat). Then verify per section 6. The detailed manual walkthrough below
is only if you want to understand what's happening or need to fix something.

---

## 0. Big-picture prerequisites (don't skip)

The repo is *only* the chain. Everything it launches must be installed by you
into these exact paths, because every script hard-codes them:

| The scripts expect | What must live there |
|---|---|
| `/workspace/bin/*` | the 5 launcher/supervisor scripts (copy from `bin/`) |
| `/workspace/hooks/init.ts` | the startup hook (copy from `hooks/`) |
| `/workspace/.opencode/bin/opencode` | the OpenCode CLI binary |
| `/workspace/runtime/node/bin/node` | a **real** Node.js ≥22.14 binary |
| `/workspace/runtime/opencode-telegram-bot/node_modules/@grinev/opencode-telegram-bot/dist/cli.js` | the installed bridge package |
| `/workspace/data/opencode-telegram/{run,logs}` | runtime PID files + logs |
| `/workspace/data/opencode-telegram/opencode-data/opencode/opencode.db` | the persistent OpenCode session DB (auto-backed-up to `backups/` every 6h, newest 10 kept, by the supervisor) |

Credentials the scripts read at runtime from the assistant vault
(`assistant credentials`) — all three are required, none is optional:
`opencode_proxy/server_password`, `opencode/api_key`, `telegram/bot_token`.

---

## 1. The two Node traps (read before you install anything)

This is the part that will cost you an afternoon if you skim it.

### 1a. This image has no real Node — and `/usr/local/bin/node` is a lie

There is no `npm` on the box and `/usr/local/bin/node` is **not Node**. It is a
Bun shim launcher (`Bun v1.3.x`, often reporting a nonsense version like
`1.3.11` when you run `node --version`). `bun` itself is present.

Consequence: you cannot `npm install` directly, and the bridge **must not**
run under the Bun shim (see 1b). You have to fetch a genuine Node tarball.
This is not optional — do it before installing the bridge package.

```bash
# x86_64 (confirm with `uname -m`)
curl -fsSL -o /tmp/node.tar.xz \
  https://nodejs.org/dist/v24.3.0/node-v24.3.0-linux-x64.tar.xz
tar -xJf /tmp/node.tar.xz -C /tmp
mkdir -p /workspace/runtime/node/bin
cp /tmp/node-v24.3.0-linux-x64/bin/node /workspace/runtime/node/bin/node
# Point the bundled npm at its real cli (the bin/npm wrapper uses a wrong
# relative path `../lib/cli.js` once relocated). Invoke npm-cli.js directly:
NPMCLI=/workspace/runtime/node/lib/node_modules/npm/bin/npm-cli.js
```

Verify the *real* node (not the shim) is in place and that it has Node-API v10:

```bash
/workspace/runtime/node/bin/node --version   # must print v22+, e.g. v24.3.0
/workspace/runtime/node/bin/node -e "console.log(process.versions.napi)"  # 10
```

### 1b. Web-API v10 is a hard requirement — better-sqlite3 SIGSEGVs without it

`@grinev/opencode-telegram-bot` ships a **native** `better-sqlite3` addon that
requires Node-API v10 (Node `22.14+`, `23.6+`, or `24+`). The bridge's own
`node-version.js` gate throws if the running Node is too old — and worse,
`better-sqlite3` crashes the process with a **SIGSEGV** on an unsupported
Node. A segfault cannot be caught. So:

- Do **not** run the bridge under the Bun shim; use the real Node binary.
- The addon's prebuilt binaries come with the package, so you do **not** need
  node-gyp on most targets. If a platform build is missing, rebuild it with
  the bundled real npm:
  ```bash
  "$NODE" "$NPMCLI" rebuild better-sqlite3
  ```
  (first install with `bun` will fail the `better-sqlite3` postinstall with
  `node-gyp: command not found` — that is *expected* and harmless as long as
  the prebuilt linux addon exists later.)

Smoke-test the addon before trusting the bot:
```bash
/workspace/runtime/node/bin/node -e \
  "const Db=require('better-sqlite3'); const d=new Db(':memory:'); d.exec('select 1'); console.log('sqlite OK')"
```

---

## 2. Install the OpenCode CLI

The installer writes to `$HOME/.opencode/bin/opencode`. This shell starts with
`HOME=/data`, so the binary lands in `/data/.opencode/bin/opencode`. The
scripts and the boot `clean-data-caches.sh` both expect `/workspace/.opencode/`
— and a boot guard *prunes* `/data/.opencode`, so leaving it there means it
vanishes on reboot. Copy it to the expected path:

```bash
curl -fsSL https://opencode.ai/install | bash
mkdir -p /workspace/.opencode/bin
cp -f /data/.opencode/bin/opencode /workspace/.opencode/bin/opencode
chmod +x /workspace/.opencode/bin/opencode
/workspace/.opencode/bin/opencode --version   # e.g. 1.18.29
```

---

## 3. Install the bridge package into its expected path

```bash
mkdir -p /workspace/runtime/opencode-telegram-bot
cd /workspace/runtime/opencode-telegram-bot
echo '{"name":"opencode-telegram-bot-runtime","private":true}' > package.json
cd /workspace/runtime/opencode-telegram-bot
bun install @grinev/opencode-telegram-bot
```

Ignore a failed `better-sqlite3` postinstall here (see 1b). Confirm the entry
point exists:
```bash
ls node_modules/@grinev/opencode-telegram-bot/dist/cli.js
```

---

## 4. Vault the secrets

Open the secure credential prompts one at a time (never paste secrets in chat;
use `assistant credentials prompt`, not `set`). People don't read what you type
*after* the popup closes, so put the instructions in the `--description`.

```bash
assistant credentials prompt --service opencode_proxy --field server_password \
  --label "OpenCode Server Password" \
  --description "Password that secures the localhost OpenCode server (127.0.0.1:4096). You choose it."
assistant credentials prompt --service opencode --field api_key \
  --label "OpenCode API Key" \
  --description "API key OpenCode uses to reach its model provider."
assistant credentials prompt --service telegram --field bot_token \
  --label "Telegram Bot Token" \
  --description "Token from @BotFather for the bridge bot."
```

**Before launching:** `bin/opencode-telegram-bridge` hard-codes
`TELEGRAM_ALLOWED_USER_ID`. The value in the repo is **not** necessarily the
user's — confirm the owner's numeric Telegram user ID and edit the line.

---

## 5. Deploy the chain into the workspace

```bash
cd /workspace
cp opencode-telegram-startup/bin/opencode-telegram-supervise \
   opencode-telegram-startup/bin/opencode-telegram-server \
   opencode-telegram-startup/bin/opencode-telegram-bridge \
   opencode-telegram-startup/bin/opencode-telegram-restart \
   opencode-telegram-startup/bin/clean-data-caches.sh \
   /workspace/bin/
chmod +x /workspace/bin/*
cp opencode-telegram-startup/hooks/init.ts /workspace/hooks/init.ts
```

Workspace hooks are discovered as `<workspace>/hooks/<event>.{ts,js}` — the
file name must exactly match the event (`init`), and no plugin/package.json is
required. The `init` hook runs on every boot and spawns the supervisor
detached (guarded so a missing binary is logged, not fatal).

---

## 6. Launch and verify

Start it exactly the way the hook does, then inspect:

```bash
mkdir -p /workspace/data/opencode-telegram/{run,logs}
setsid nohup /workspace/bin/opencode-telegram-supervise \
  >> /workspace/data/opencode-telegram/logs/supervisor.log 2>&1 < /dev/null &
```

Give the converge loop ~30s. Verify the healthy steady state:

```bash
tail -3 /workspace/data/opencode-telegram/logs/supervisor.log
# expect: [..] starting localhost OpenCode server   (a few) then
#         [..] OK: server healthy, bridge running    (repeating every 15s)
```

If it just repeats `starting ...` forever, the health probe is failing — see
Troubleshooting below. The other logs to check:
`/workspace/data/opencode-telegram/logs/{opencode-server.log,telegram-bridge.log}`.

A healthy bridge log ends with the bot announcing itself, e.g.
`Bot @Opencode_xxx_bot started!`. A healthy server probe returns **200** with
auth:

```bash
PW="$(assistant credentials reveal --service opencode_proxy --field server_password)"
curl -u "opencode:$PW" -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4096/   # 200
```

Restart helper included at `/workspace/bin/opencode-telegram-restart` (never
deletes the persistent OpenCode DB).

### 6a. Re-apply the pinned-message patch (required after every reinstall)

Out of the box, the bridge calls Telegram's `unpinAllChatMessages` (unpins
*every* message in the chat) on every project/session change. Telegram rate
limits that call per chat, so the handler stalls behind 429 retries and button
callback queries expire (`query is too old ... invalid`) — buttons and commands
appear to fail. This is fixed by `patches/opencode-telegram-bot-unpin-fix.patch`,
which switches the manager to unpinning only its own status message via
`unpinChatMessage`. `npm install` / `bun install` overwrites the file, so the
patch **must** be reapplied after every install:

```bash
cd /workspace
patch -p1 < opencode-telegram-startup/patches/opencode-telegram-bot-unpin-fix.patch
```

Then restart the bridge (stop it; the supervisor relaunches it with the patch
loaded):
```bash
pkill -f "dist/cli.js start"; sleep 3; rm -f /workspace/data/opencode-telegram/run/telegram-bridge.pid
# supervisor detects the bridge is down and relaunches it within ~15s
```
Verify no `unpinAllChatMessages` / `Too Many Requests` lines appear in the
bridge log after the restart.

### 6b. Re-apply the session-recovery patch (required after every reinstall)

Running a Telegram `/stop` then `/start` kills the OpenCode server and wipes its
in-memory session store. The bridge keeps reusing the cached session ID, so
every prompt then fails with `NotFoundError: Session not found: ses_...` until
you manually clear `settings.json` (see Troubleshooting) — or now, one prompt
after the fix, automatically. This is fixed by
`patches/opencode-telegram-bot-session-recovery.patch`, which makes the bridge
detect that "Session not found" error and **recreate a fresh session on its
own** (the equivalent of `/new`), then reply `🔄 OpenCode restarted, so your
session was recreated. Please resend your message.`. Like the unpin patch, it is
**not** part of the package, so it **must** be reapplied after every install:

```bash
cd /workspace
patch -p1 < opencode-telegram-startup/patches/opencode-telegram-bot-session-recovery.patch
```

Then restart the bridge as above. Verify the bridge log shows
`Stale session detected (OpenCode restarted); recreating session` instead of
repeated `Failed to send request to OpenCode` lines after a `/stop` + `/start`.

In general, prefer `/new` over `/stop`/`/start` in the bot — it starts a fresh
session without killing the server.

### 6c. Re-apply the keep-session-on-stop patch (required after every reinstall)

OpenCode wipes its in-memory session store the moment the server process is
killed, and it cannot restore a persisted session by ID afterwards (`GET
/session/{id}` returns `NotFound`). So `/opencode_stop` (or a server stop)
silently destroys whatever conversation you were in. The fix in
`patches/opencode-telegram-bot-keep-session-on-stop.patch` makes the bot
**refuse to stop the server while a session still exists**, telling you to use
`/new` instead — so stop/start can never wipe your work. Like the other two
patches it is not in the package, so it **must** be reapplied after every
install:

```bash
cd /workspace
patch -p1 < opencode-telegram-startup/patches/opencode-telegram-bot-keep-session-on-stop.patch
```

Then restart the bridge as above. Verify by running `/opencode_stop` with an
active session — you should get the `🛡️ Can't stop while a session still
exists...` refusal instead of a successful stop.

> Note: `/opencode_start` and `/opencode_stop` were later removed from the bot
> entirely (see 6e); the guard remains as defense-in-depth.

### 6d. Safe Telegram restart command

`patches/opencode-telegram-bot-safe-restart-command.patch` adds a dedicated
`/opencode_restart` command. It replies first, then gracefully terminates only
the Telegram bridge process; the external supervisor relaunches the bridge
within about 15 seconds. The OpenCode server process is never touched, so the
current session ID and conversation remain intact.

The setup script applies this patch automatically. After a manual bridge
package reinstall, reapply it with:

```bash
cd /workspace
patch -p1 < opencode-telegram-startup/patches/opencode-telegram-bot-safe-restart-command.patch
```

Use `/opencode_restart` whenever the Telegram bot itself needs a reload.

### 6e. Restart upgrade: confirmation edit, menu refresh, removal of unsafe commands

`patches/opencode-telegram-bot-restart-upgrade.patch` (applies **after** 6d)
upgrades `/opencode_restart`:

- The `🔄 Restarting...` reply is edited to `✅ Restarted.` by the freshly
  launched bridge (the old process is gone by then; a small
  `pending-restart.json` marker in the bot home carries the message ref).
- The Telegram `/` command menu is force-refreshed on every boot, so it always
  matches the registered commands.
- `/opencode_start` and `/opencode_stop` are removed from the menu and router —
  stopping/starting the OpenCode server from Telegram is inherently unsafe
  (it wipes the in-memory session store), and the supervisor already owns the
  server lifecycle.

The setup script applies this patch automatically. After a manual bridge
package reinstall, reapply it (after 6d) with:

```bash
cd /workspace
patch -p1 < opencode-telegram-startup/patches/opencode-telegram-bot-restart-upgrade.patch
```

### 6f. Delete-session command

`patches/opencode-telegram-bot-delete-session-command.patch` (applies **after**
6e) adds the `/delete_session` Telegram command:

- It lists the project's sessions in an inline keyboard, same numbered
  `title (date)` style as `/sessions`, with pagination.
- Tapping a session replaces the menu with a confirmation:
  `⚠️ Are you sure you want to delete "<title>"?` plus `✅ Yes, delete` /
  `❌ No, cancel` inline buttons.
- **Yes** deletes the session and all its messages from the OpenCode database
  via the SDK (`session.delete`). If the deleted session was the active one,
  the bridge clears its session state (detach + clear), so the next prompt
  automatically creates a fresh session.
- **No** cancels: nothing is deleted, the interaction state is released, and
  the user continues with whatever they were doing.

New files: `bot/commands/delete-session-command.js`,
`bot/callbacks/delete-session-callback-handler.js`. Edited: command router,
callback router (new `delses` prefix route), command definitions, the inline
menu kinds list, and the English texts (`delses.*` keys).

The setup script applies this patch automatically. After a manual bridge
package reinstall, reapply it (after 6e) with:

```bash
cd /workspace
patch -p1 < opencode-telegram-startup/patches/opencode-telegram-bot-delete-session-command.patch
```

---

## 7. Troubleshooting

**AGENTS.md / instructions not applied to new sessions**
The bridge's auto-restart can spawn the OpenCode server itself (`opencode serve
--port 4096`), and that child inherits the *bridge's* environment. If the
bridge launcher does not export `XDG_CONFIG_HOME`/`XDG_DATA_HOME`, a
bridge-spawned server reads `~/.config/opencode` instead of
`/workspace/data/opencode-telegram/opencode-config` — so the global
`AGENTS.md` there is never injected and sessions land in the wrong DB.
`bin/opencode-telegram-bridge` therefore exports the same XDG dirs as
`bin/opencode-telegram-server`. The supervisor additionally self-heals: its
`server_config_ok` check replaces any server found running with the wrong XDG
paths. To verify the running server:
`tr '\0' '\n' < /proc/$(pgrep -f 'opencode serve')/environ | grep XDG` —
it must show the `/workspace/data/opencode-telegram/...` paths.

**`starting ... starting ...` forever in supervisor.log**
The `server_healthy()` probe (`curl -u "opencode:$PW" $SERVER_URL`) isn't
returning. Causes in order of likelihood:
1. Server crashed at boot — check `opencode-server.log` for why it exited.
2. Bridge / server running under the *Bun shim* node, not real Node → see 1a.
3. `$SERVER_PW` empty because the vault wasn't ready (the supervisor retries
   for 2 min; the box's boot order may simply need it launched later).
4. Server bound but auth mismatch — unauthenticated curl returns `401`,
   authenticated should return `200`.

**`node-gyp: command not found` during install**
Normal and ignorable **iff** the prebuilt `better-sqlite3` addon exists under
`node_modules/better-sqlite3/prebuilds/linux-x64.node`. If it's not there,
rebuild with the real bundled npm (see 1b).

**`Cannot find module '../lib/cli.js'` when running npm**
The relocated `npm` wrapper keeps a stale relative path. Invoke npm-cli.js
directly: `node /workspace/runtime/node/lib/node_modules/npm/bin/npm-cli.js …`.

**Bot connects then dies under load / after a few minutes**
Almost always the native addon + Node mismatch. Confirm real Node (not the
shim) is the interpreter in `ps` and that `process.versions.napi === 10`.

---

## 8. Repo layout reference

```
bin/
  clean-data-caches.sh          # prune regenerable caches from /data at boot
  opencode-telegram-supervise   # idempotent probe supervisor (15s)
  opencode-telegram-server      # launch `opencode serve` on 127.0.0.1:4096
  opencode-telegram-bridge      # launch the @grinev Telegram bridge bot
  opencode-telegram-restart     # safe restart helper (keeps OpenCode DB)
hooks/
  init.ts                       # boot hook: runs supervise + cache guard
README.md
INSTALL.md
```
