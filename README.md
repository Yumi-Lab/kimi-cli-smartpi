# Kimi CLI for Yumi Smart Pi One (32-bit ARM)

The **Kimi CLI** (Moonshot AI) running on **Allwinner H3 / armv7l** (Smart Pi One,
Yumi SmartPad) — a platform the official installer has no build for.

It runs **natively** (no emulation): the `kimi-cli` PyPI distribution is a
pure-python wheel (`py3-none-any`), so it only needs Python and a few C
dependencies that compile from source. Sign in with a **Kimi account**
(no API key required), full interactive agent, full tool use.

```
╭──────────────────────────────────────────────────────────╮
│  Kimi, your next CLI agent.            1.49.0 · armv7l    │
│                                                          │
│  › _                                                     │
│                                                          │
│  /login  ·  /help  ·  kimi -p "…" for one-shot           │
╰──────────────────────────────────────────────────────────╯
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/kimi-cli-smartpi/main/install.sh | bash
```

Then sign in with your Kimi account (default: Moonshot's Kimi servers):

```bash
kimi login
```

Follow the prompt (OAuth in a browser on any machine, or an API key). Credentials
are stored in `~/.kimi/`.

## Usage

| Command | Purpose |
|---|---|
| `kimi` | **Full interactive agent** — the real official TUI, running natively (pure python) |
| `kimi -p "question"` | Start from a prompt, then keep going interactively |
| `kimi --quiet -p "task"` | One-shot, non-interactive, final answer only (`--print --output-format text --final-message-only`) |
| `kimi login` | Sign in with a Kimi account (OAuth or API key) |
| `kimi --version` | Sanity check (~1 s) |
| `KIMI_CPUS=0,1 kimi …` | Limit the running agent to 2 cores (default: all 4) |

`~/.local/bin` must be on your `PATH`. The uv installer adds it to your shell
profile; open a new shell or run `export PATH="$HOME/.local/bin:$PATH"`.

**Two core knobs** (both default to all 4 cores; the Yumi build bench adds a fan
for heavy jobs, so lower these only on a bare fanless board):

- `KIMI_BUILD_CPUS` — cores for the one-time **compile** at install
  (`KIMI_BUILD_CPUS=0,1 curl … | bash`).
- `KIMI_CPUS` — cores for the **running agent** at launch
  (`KIMI_CPUS=0,1 kimi …`), the runtime twin of `GROK_CPUS` on
  [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi). Installed as a
  small wrapper over `~/.local/bin/kimi`; after `uv tool upgrade kimi-cli`, re-run
  `install.sh` to restore it.

⚠️ **Never re-run `uv tool install kimi-cli` over an existing install** — it fails
on `httptools` (a distutils build with no metadata to reconcile). To update:
`uv tool upgrade kimi-cli`. The installer is idempotent and skips the install if
`kimi` is already present.

## How it works

1. The official installer (`code.kimi.com/install.sh`) ships **no 32-bit build**
   → dead end on armv7l. But Kimi CLI is also published on PyPI as `kimi-cli`, a
   **pure-python wheel** (`py3-none-any`) — architecture-independent.
2. We install it with [uv](https://github.com/astral-sh/uv) (`uv tool install
   kimi-cli`), which the installer fetches first if it is missing. The final
   binary is `~/.local/bin/kimi`.
3. A handful of C dependencies have **no armv7 wheel and compile from source**
   (notably Pillow), so the installer pulls the armhf build toolchain
   (`python3-dev gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev`). The build
   runs on **all 4 cores by default** (fast — the Yumi build bench adds a fan for
   these jobs). On a **fanless** H3 a 4-core gcc build drives the SoC to ~102 °C
   and freezes it, so throttle the build there:
   `KIMI_BUILD_CPUS=0,1 curl … | bash` (2 cores, ~88 °C peak) or
   `KIMI_BUILD_CPUS=0` (1 core, coolest).
4. `earlyoom` completes the safety net (1 GB of RAM + SD-card swap freezes the
   machine before the kernel OOM killer reacts).

Unlike its sister project [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)
(which needs QEMU 64-on-32 emulation), Kimi CLI runs **natively** — like
[claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi), it is pure
interpreted code, so it is stable for heavy multi-turn agentic tasks.

Full details (the PyPI-vs-installer story, the httptools pitfall, thermal
measurements): [docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Target hardware

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf, Python 3.13). Any armv7l SBC with ≥ 1 GB RAM should work.
Measured performance (kimi-cli 1.49.0): `kimi --version` **~0.9 s**. A one-shot
answer (`kimi --quiet -p "…"`) runs its inference on Moonshot's servers, so
wall-time is set by the remote model and network — the H3 only adds the ~0.9 s
CLI start on top. First install compiles Pillow (a few minutes on the H3) —
4 cores by default, `KIMI_BUILD_CPUS=0,1` on a fanless board. `earlyoom` is
installed as a memory safety net.

## Sister projects (same pads, same method)

- [claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi) — official Claude Code CLI, native (pinned npm 2.1.112)
- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI Grok CLI, QEMU 64-on-32 emulation

## Licensing

- Scripts in this repo: MIT (Yumi Lab)
- Kimi CLI itself is installed from the official PyPI registry (the `kimi-cli`
  package) at install time (it is not redistributed here) and remains subject to
  Moonshot AI's terms.
