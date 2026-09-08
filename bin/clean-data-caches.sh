#!/usr/bin/env bash
# Guard: /data and /workspace share the same 5.9G backing volume.
# The daemon environment (HOME=/data, BUN_INSTALL=/data/.bun) makes tooling
# write regenerable caches into /data, which is invisible to du -x /workspace
# but consumes the shared volume. This script prunes those caches at boot.
# It NEVER touches /data/system (live platform root) or /data/.vellum.
set -u

KEEP="/data/system /data/.vellum"
for target in /data/.bun /data/.npm /data/.opencode /data/.cache /data/.config /data/.local; do
  if [ -e "$target" ]; then
    rm -rf "$target"
    echo "pruned: $target"
  fi
done

# Report remaining state so the boot log shows the guard ran.
echo "guard: /data remaining:"
du -shx /data/* /data/.[a-z]* 2>/dev/null | sort -rh | head -10
