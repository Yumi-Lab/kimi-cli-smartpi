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
# So: skip entirely if kimi is already there. Updating = `uv tool upgrade`.
if command -v kimi >/dev/null 2>&1; then
  log "kimi already installed ($(kimi --version 2>/dev/null | head -1)) — skipping."
  log "To update it later:  uv tool upgrade kimi-cli"
else
  log "Installing kimi-cli (PyPI, compiles Pillow on cores ${BUILD_CPUS} — patience on the H3)…"
  $THROTTLE uv tool install kimi-cli \
    || fail "kimi-cli install failed (see output above)."
  command -v kimi >/dev/null 2>&1 || fail "kimi not found after install (expected ~/.local/bin/kimi)."
fi

# --- 4. Anti-freeze safety net ----------------------------------------------
# Kills the largest process before memory exhaustion (1 GB RAM + SD-card swap =
# full machine freeze before the kernel OOM killer reacts).
if command -v apt-get >/dev/null; then
  sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && sudo systemctl enable --now earlyoom >/dev/null 2>&1 \
    && log "earlyoom active" || true
fi

hash -r 2>/dev/null || true
log "Check: $(kimi --version 2>/dev/null || echo 'kimi --version failed')"   # ~1 s on the H3

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

Note:
    ~/.local/bin must be on your PATH. uv adds it to your shell profile; open a
    new shell, or run:  export PATH="$HOME/.local/bin:$PATH"

DO NOT:
    re-run `uv tool install kimi-cli` over an existing install (it fails on
    httptools). To update:  uv tool upgrade kimi-cli
MSG
