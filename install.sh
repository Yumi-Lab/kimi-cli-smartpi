#!/usr/bin/env bash
# Kimi CLI (Moonshot AI) on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/kimi-cli-smartpi/main/install.sh | bash
#
# This script installs:
#   uv                      Astral standalone installer (if missing) → ~/.local/bin/uv
#   kimi-cli (PyPI wheel)   installed as a uv tool → ~/.local/bin/kimi
#   armhf build deps        python3-dev gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev
#                           (Pillow compiles from source on armv7 — no wheel)
#   earlyoom                anti-freeze memory safety net (1 GB RAM + SD swap)
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

# --- 1. Build dependencies (Pillow has no armv7 wheel → it compiles) ---------
log "Installing armhf build dependencies (python3-dev, gcc, libjpeg…)…"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  python3-dev gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev >/dev/null \
  || warn "Some build deps failed to install — the kimi build may fail below."

# --- 2. uv (Astral) — the Python tool manager that carries kimi --------------
if command -v uv >/dev/null 2>&1; then
  log "uv already present ($(uv --version 2>/dev/null))."
else
  log "Installing uv (Astral standalone installer)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null 2>&1 || fail "uv install failed (expected at ~/.local/bin/uv)."
fi

# --- 3. kimi-cli — idempotent ------------------------------------------------
# IMPORTANT: re-running `uv tool install kimi-cli` over an existing install
# fails on httptools (a distutils build with no metadata uv can reconcile).
# So: skip the install if the uv tool venv is already there (we key the check on
# the venv binary, NOT on ~/.local/bin/kimi, which step 3b turns into a wrapper).
# Updating = `uv tool upgrade kimi-cli`.
KIMI_TOOL_BIN="$HOME/.local/share/uv/tools/kimi-cli/bin/kimi"
if [ -x "$KIMI_TOOL_BIN" ]; then
  log "kimi-cli already installed ($("$KIMI_TOOL_BIN" --version 2>/dev/null | head -1)) — skipping."
  log "To update it later:  uv tool upgrade kimi-cli  (then re-run this script)"
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
cat > "$WRAP" <<EOF
#!/bin/sh
# kimi-cli-smartpi runtime wrapper — cores set by KIMI_CPUS (default: all 4).
exec taskset -c "\${KIMI_CPUS:-0,1,2,3}" nice -n 5 "$KIMI_TOOL_BIN" "\$@"
EOF
chmod +x "$WRAP"
log "kimi runtime wrapper installed (KIMI_CPUS default 0,1,2,3)."

# --- 4. Anti-freeze safety net ----------------------------------------------
# Kills the largest process before memory exhaustion (1 GB RAM + SD-card swap =
# full machine freeze before the kernel OOM killer reacts).
if command -v apt-get >/dev/null; then
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
    ~/.local/bin must be on your PATH. uv adds it to your shell profile; open a
    new shell, or run:  export PATH="$HOME/.local/bin:$PATH"

DO NOT:
    re-run `uv tool install kimi-cli` over an existing install (it fails on
    httptools). To update:  uv tool upgrade kimi-cli
MSG
