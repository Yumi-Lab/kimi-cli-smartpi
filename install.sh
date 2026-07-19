#!/usr/bin/env bash
# Kimi CLI (Moonshot AI) on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/kimi-cli-smartpi/main/install.sh | bash
#
# This script installs:
#   uv                      Astral standalone installer (if missing) → ~/.local/bin/uv
#   kimi-cli (PyPI wheel)   installed as a uv tool → ~/.local/bin/kimi
#   ~/.local/bin/kimi       runtime wrapper (all 4 cores + nice, KIMI_CPUS to throttle)
#   ~/.local/bin/kimi-check-update   update probe (JSON one-liner, OTA contract)
#   armhf build deps        python3-dev gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev
#                           (Pillow compiles from source on armv7 — no wheel)
#   ~/.local/bin on PATH    (uv does NOT add it to login shells)
#   earlyoom                anti-freeze memory safety net (1 GB RAM + SD swap)
#
# OTA contract (shared by every Yumi-Lab/*-smartpi repo):
#   * re-running this script IS the update: already installed → `uv tool upgrade
#     kimi-cli` (fast no-op when current — NEVER `uv tool install` over an
#     existing install, it fails on httptools), then the KIMI_CPUS wrapper is
#     restored (an upgrade rewrites ~/.local/bin/kimi);
#   * `kimi-check-update` prints one JSON line {installed, latest,
#     update_available} — what the Yumi AI Gateway polls for its update badge;
#   * everything lives under $HOME → no sudo needed after the first install
#     (apt build deps): the gateway service user updates unprivileged.
#
# Why the PyPI path and not the official installer: `code.kimi.com/install.sh`
# ships no 32-bit build → dead end on armv7l. The `kimi-cli` PyPI distribution is
# a pure-python wheel (py3-none-any) and runs natively once its few C deps compile.
# See docs/METHODOLOGY.md for the reasoning behind every choice.
set -euo pipefail

log()  { printf '\033[1;36m[kimi-smartpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kimi-smartpi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[kimi-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit, use the official installer: curl -LsSf https://code.kimi.com/install.sh | bash"
command -v curl >/dev/null || fail "curl is required"

export PATH="$HOME/.local/bin:$PATH"   # uv and kimi live here; make them visible now

# Cores used for the (hot) compilation step. Default: all 4 — fast, and the Yumi
# build bench adds a fan for these jobs. On a FANLESS H3 a 4-core gcc build drives
# the SoC to ~102 °C and freezes it, so drop the count on a bare board:
#   KIMI_BUILD_CPUS=0,1  curl -fsSL …/install.sh | bash   # 2 cores (~88 °C peak)
#   KIMI_BUILD_CPUS=0    curl -fsSL …/install.sh | bash   # 1 core  (coolest, slowest)
BUILD_CPUS="${KIMI_BUILD_CPUS:-0,1,2,3}"
THROTTLE="taskset -c ${BUILD_CPUS} nice -n 5"

RAW="https://raw.githubusercontent.com/Yumi-Lab/kimi-cli-smartpi/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"

# Fetch a repo file: local copy if run from a clone, otherwise raw GitHub.
# Target lives under $HOME (user-owned) — no sudo.
fetch_user() { # $1 repo-relative path, $2 destination
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    install -m755 "$HERE/$1" "$2"
  else
    tmpf=$(mktemp); curl -fsSL "$RAW/$1" -o "$tmpf" && install -m755 "$tmpf" "$2"; rm -f "$tmpf"
  fi
}

# apt is possible when: root, passwordless sudo, or an interactive run where
# sudo can prompt on the tty. The gateway service user (no sudo, no tty) skips
# apt cleanly — the gateway installer set the build deps up as root.
can_apt() {
  command -v apt-get >/dev/null || return 1
  [ "$(id -u)" -eq 0 ] && return 0
  sudo -n true 2>/dev/null && return 0
  [ -t 1 ] && command -v sudo >/dev/null
}

# --- 1. Build dependencies (Pillow has no armv7 wheel → it compiles) ---------
if can_apt; then
  log "Installing armhf build dependencies (python3-dev, gcc, libjpeg…)…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    python3-dev gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev >/dev/null \
    || warn "Some build deps failed to install — the kimi build may fail below."
else
  warn "apt unavailable (no sudo/tty) — assuming the armhf build deps are already installed."
fi

# --- 2. uv (Astral) — the Python tool manager that carries kimi --------------
if command -v uv >/dev/null 2>&1; then
  log "uv already present ($(uv --version 2>/dev/null))."
else
  log "Installing uv (Astral standalone installer)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || fail "uv install failed (expected at ~/.local/bin/uv)."
fi

# --- 3. kimi-cli — install or UPDATE (re-run = the updater) ------------------
# IMPORTANT: re-running `uv tool install kimi-cli` over an existing install
# fails on httptools (a distutils build with no metadata uv can reconcile).
# So: already installed → `uv tool upgrade kimi-cli` (the safe path; fast no-op
# when current, and only a real upgrade may recompile Pillow — throttled). The
# check is keyed on the venv binary, NOT on ~/.local/bin/kimi, which step 3b
# turns into a wrapper (and which any upgrade rewrites — step 3b restores it).
KIMI_TOOL_BIN="$HOME/.local/share/uv/tools/kimi-cli/bin/kimi"
if [ -x "$KIMI_TOOL_BIN" ]; then
  log "kimi-cli already installed ($("$KIMI_TOOL_BIN" --version 2>/dev/null | head -1)) — checking for an upgrade…"
  $THROTTLE uv tool upgrade kimi-cli || warn "uv tool upgrade failed — keeping the installed version."
else
  log "Installing kimi-cli (PyPI, compiles Pillow on cores ${BUILD_CPUS} — patience on the H3)…"
  $THROTTLE uv tool install kimi-cli \
    || fail "kimi-cli install failed (see output above)."
  [ -x "$KIMI_TOOL_BIN" ] || fail "kimi-cli venv not found at $KIMI_TOOL_BIN after install."
fi

# --- 3b. Runtime core control (KIMI_CPUS) -----------------------------------
# Replace uv's ~/.local/bin/kimi symlink with a wrapper that pins the running
# agent to a configurable set of cores — the runtime counterpart of GROK_CPUS on
# grok-cli-smartpi. Default: all 4 cores. On a fanless board running a heavy local
# agentic loop, throttle without reinstalling:   KIMI_CPUS=0,1 kimi …
# The wrapper always calls the real venv binary (never itself → no recursion).
# NB: `uv tool upgrade kimi-cli` rewrites this symlink, so re-run install.sh after
# an upgrade to restore the wrapper.
WRAP="$HOME/.local/bin/kimi"
[ -x "$KIMI_TOOL_BIN" ] || fail "real kimi binary missing at $KIMI_TOOL_BIN — cannot build wrapper."
# CRITICAL: ~/.local/bin/kimi is a SYMLINK to $KIMI_TOOL_BIN. `cat > "$WRAP"`
# would FOLLOW it and overwrite the real venv binary with a wrapper that points to
# itself → infinite taskset/nice recursion (a hung `kimi`). `rm -f` removes the
# link itself (never the target), so we then create a fresh regular file.
rm -f "$WRAP"
cat > "$WRAP" <<EOF
#!/bin/sh
# kimi-cli-smartpi runtime wrapper — cores set by KIMI_CPUS (default: all 4).
exec taskset -c "\${KIMI_CPUS:-0,1,2,3}" nice -n 5 "$KIMI_TOOL_BIN" "\$@"
EOF
chmod +x "$WRAP"
log "kimi runtime wrapper installed (KIMI_CPUS default 0,1,2,3)."

# --- 3c. PATH fix -----------------------------------------------------------
# uv drops kimi into ~/.local/bin but does NOT add it to the PATH of login shells
# → `kimi: command not found` after a reconnect. Add it to the shell rc files if
# it isn't there already (idempotent — same fix as vibe-cli-smartpi).
add_path_line() {
  local rc="$1"
  [ -e "$rc" ] || { [ "$rc" = "$HOME/.profile" ] || return 0; }  # create ~/.profile if missing
  grep -qsF '.local/bin' "$rc" 2>/dev/null && return 0
  printf '\n# Added by kimi-cli-smartpi: uv and kimi live here\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
  log "PATH: added ~/.local/bin to $(basename "$rc")"
}
add_path_line "$HOME/.bashrc"
add_path_line "$HOME/.profile"

# --- 3d. Update probe (OTA contract shared by every *-smartpi repo) ----------
# One JSON line {installed, latest, update_available} — polled by the gateway.
if fetch_user bin/kimi-check-update "$HOME/.local/bin/kimi-check-update"; then
  log "installed kimi-check-update (update probe)"
else
  warn "kimi-check-update not installed (non-fatal)."
fi

# --- 4. Anti-freeze safety net ----------------------------------------------
# Kills the largest process before memory exhaustion (1 GB RAM + SD-card swap =
# full machine freeze before the kernel OOM killer reacts). Optional — skipped
# cleanly when apt/sudo is unavailable (unprivileged OTA update).
if can_apt; then
  sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && sudo systemctl enable --now earlyoom >/dev/null 2>&1 \
    && log "earlyoom active" || true
fi

hash -r 2>/dev/null || true
# `timeout` so the installer never hangs on the check (kimi startup is normally
# ~1 s on the H3, but a heavily-contended board can stall it).
log "Check: $(timeout 20 kimi --version 2>/dev/null || echo 'kimi --version did not answer in 20 s — try again on an idle board')"

cat <<'MSG'

✔ Install complete.

Sign in with your Kimi account (default: Moonshot's Kimi servers):
    kimi login
  → follow the prompt (OAuth in a browser on any machine, or an API key).
    Credentials are stored in ~/.kimi/.

Usage:
    kimi                       full interactive agent (TUI)
    kimi -p "question"         one-shot, then keep going interactively
    kimi --quiet -p "task"     one-shot, non-interactive, final answer only
    kimi --version             sanity check (~1 s)

    KIMI_CPUS=0,1 kimi …       limit the running agent to 2 cores (default: all 4)

Note:
    This installer added ~/.local/bin to your PATH (~/.bashrc, ~/.profile). If
    `kimi` is "command not found" after reconnecting, open a new shell or run:
    . ~/.profile

Update:
    kimi-check-update          →  {"installed":…,"latest":…,"update_available":…}
    re-run install.sh          upgrades kimi-cli and restores the wrapper

DO NOT:
    re-run `uv tool install kimi-cli` over an existing install (it fails on
    httptools — install.sh upgrades via `uv tool upgrade`).
    a bare `uv tool upgrade kimi-cli` either: it rewrites ~/.local/bin/kimi and
    drops the KIMI_CPUS wrapper — install.sh restores it.
MSG
