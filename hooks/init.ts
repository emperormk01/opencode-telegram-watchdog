import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

export default async function init(ctx: {
  logger?: { info: (obj: unknown, msg: string) => void };
}): Promise<void> {
  // /data and /workspace share the same backing volume.  Prune regenerable
  // caches from /data so they don't silently consume the shared quota.
  if (existsSync("/workspace/bin/clean-data-caches.sh")) {
    spawn("/workspace/bin/clean-data-caches.sh", [], {
      cwd: "/workspace",
      stdio: "inherit",
      env: { ...process.env },
    });
  }

  if (existsSync("/workspace/bin/opencode-telegram-supervise")) {
    const child = spawn("/workspace/bin/opencode-telegram-supervise", [], {
      cwd: "/workspace",
      detached: true,
      stdio: "ignore",
      env: { ...process.env },
    });
    child.unref();
    ctx.logger?.info(
      { pid: child.pid, service: "opencode-telegram" },
      "OpenCode Telegram supervisor launched",
    );
  }

  // Cline Telegram supervisor (guarded: binary may be absent)
  if (existsSync("/workspace/bin/cline-telegram-supervise")) {
    const clineChild = spawn("/workspace/bin/cline-telegram-supervise", [], {
      cwd: "/workspace",
      detached: true,
      stdio: "ignore",
      env: { ...process.env },
    });
    clineChild.unref();
    ctx.logger?.info(
      { pid: clineChild.pid, service: "cline-telegram" },
      "Cline Telegram supervisor launched",
    );
  } else {
    ctx.logger?.info(
      { service: "cline-telegram" },
      "cline-telegram-supervise not found; skipping launch",
    );
  }
}
