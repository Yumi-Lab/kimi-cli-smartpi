# Full methodology — Kimi CLI on 32-bit ARM

How to run the Kimi CLI (Moonshot AI), whose official installer ships no 32-bit
build, on a SoC that can only execute 32-bit code (Allwinner H3, Cortex-A7,
armv7l). Reference document: every choice below was tested on a Yumi SmartPad
(quad-core H3 @ 1.2 GHz, 1 GB RAM, Debian 13 trixie armhf, Python 3.13)
on 2026-07-17.

## 1. The problem

- The Cortex-A7 is **32-bit only** (ARMv7-A): no native aarch64 execution is
  possible, unlike 64-bit SoCs (H5, A53…) which can boot a 32-bit OS.
- The official installer only builds for 64-bit:
  ```
  curl -LsSf https://code.kimi.com/install.sh | bash
  ```
  On armv7l it has no artifact to fetch → dead end. The advertised install path
  simply does not cover 32-bit ARM.

## 2. The key discovery: Kimi CLI is on PyPI as a pure-python wheel

Kimi CLI is *also* published on PyPI as the `kimi-cli` package, and that wheel is
architecture-independent:

```
kimi_cli-<version>-py3-none-any.whl      ← py3, none, any → no arch lock
```

`py3-none-any` means the CLI itself is plain interpreted Python — nothing to
cross-compile, nothing to emulate. It runs natively on armv7l exactly as it does
on x86_64. This is the whole trick: **install the PyPI distribution, not the
64-bit installer's binary bundle.**

We install it with [uv](https://github.com/astral-sh/uv) (Astral's Python tool
manager), which the installer fetches first (standalone installer) if it is
missing:

```
uv tool install kimi-cli          → ~/.local/bin/kimi
```

uv resolves the wheel, creates an isolated tool venv, and links `kimi` (and
`kimi-cli`) into `~/.local/bin`.

## 3. The one real obstacle: native C dependencies compile from source

Although `kimi-cli` itself is pure python, a few of its dependencies ship C
extensions with **no armv7 wheel on PyPI**, so pip/uv builds them from source on
the board — most notably **Pillow**. That needs the armhf build toolchain:

```
python3-dev  gcc  libffi-dev  pkg-config  libjpeg-dev  zlib1g-dev
```

(uv uses the **system** Python 3.13 from Debian trixie, so the system
`python3-dev` headers are the right ones — no managed-interpreter mismatch.)

### Thermal constraint — the one thing to watch

Compiling C on an H3 with 1 GB of RAM is where the board gets hot. The build core
count is configurable via `KIMI_BUILD_CPUS` (default **all 4**):

```
taskset -c ${KIMI_BUILD_CPUS:-0,1,2,3} nice -n 5   uv tool install kimi-cli
```

- **Default (4 cores)**: fastest. The Yumi build bench adds a **fan** for these
  jobs, which keeps a 4-core build comfortably in range.
- **Fanless board**: a 4-core gcc build drives this exact SoC to **~102 °C → full
  machine freeze** (the SmartPad chassis throttles from 75 °C; passive trips at
  75/80/85/90 °C). Throttle it: `KIMI_BUILD_CPUS=0,1` (2 cores, ~88 °C peak in
  normal conditions) or `KIMI_BUILD_CPUS=0` (1 core, coolest). Measured on a
  fanless board that was **already warm** from a previous job, even a 2-core
  build climbed to ~95 °C — re-pinning the running compiler to a single core
  (`taskset -pc 0 <pid>`) brought it back down without losing the build.

Rule on the pad: **one heavy build at a time** — two simultaneous compiles (or a
second CLI install) exhaust the 1 GB of RAM and freeze the machine before the
kernel OOM killer reacts. `earlyoom` is installed as the last line of defence.

## 4. The idempotency pitfall: httptools

Re-running `uv tool install kimi-cli` **over an existing install fails**:

```
uv tool install kimi-cli
  × Failed to build `httptools==…`
    distutils build, no metadata uv can reconcile on the reinstall path
```

So the installer must **not** blindly reinstall. It checks first:

- `command -v kimi` present → **skip the install entirely** (idempotent re-run).
- To update on purpose: `uv tool upgrade kimi-cli` (never a fresh
  `uv tool install` over the top).

This is why the one-liner is safe to re-run on an already-equipped pad.

## 5. Installed layout

```
~/.local/bin/uv                                     Astral tool manager (installed if missing)
~/.local/bin/kimi                                   runtime wrapper → taskset -c ${KIMI_CPUS} …/kimi-cli/bin/kimi
~/.local/bin/kimi-cli                               → …/uv/tools/kimi-cli/bin/kimi-cli (unwrapped)
~/.local/share/uv/tools/kimi-cli/bin/kimi           the real venv entry point (what the wrapper calls)
~/.local/share/uv/tools/kimi-cli/                   isolated tool venv (kimi-cli + deps)
~/.kimi/                                             config.toml, sessions, credentials
```

The installer keys its idempotency check on the venv binary
(`…/uv/tools/kimi-cli/bin/kimi`), not on `~/.local/bin/kimi`, precisely because
that path is turned into the runtime wrapper below.

## 6. Authentication (Kimi account)

```
kimi login
```

The default configuration targets Moonshot's own Kimi servers. `kimi login`
runs the account flow (OAuth in a browser on any machine, or an API key);
credentials and configuration land in `~/.kimi/`.

Notes from real use:
- A **one-shot** call (`kimi -p "…"` / `kimi --quiet -p "…"`) needs a model to be
  selected. If `default_model` is empty in `~/.kimi/config.toml` and no `-m`
  is passed, the CLI exits with `LLM not set`. After `kimi login`, either set a
  default model in the interactive UI (`/model`) or pass `-m <model>`.
- The non-interactive contract is `--print` + `-p`: `kimi --print -p "…"`
  (add `--output-format stream-json` for structured JSONL, or `--quiet` for the
  final text only). Without `--print`, `-p` stays interactive and
  `--output-format` is rejected.

## 7. Performance and memory (1 GB H3)

Measured on the SmartPad (Debian 13 trixie armhf, Python 3.13, kimi-cli 1.49.0):

- `kimi --version`: ~0.9 s (Python cold start)
- One-shot answer (`kimi --quiet -p "…"`): network-bound — inference runs on
  Moonshot's servers, so wall-time is dominated by the remote model and network,
  with only the ~0.9 s CLI start added locally.
- First install: compiles Pillow (and friends) — a few minutes on the H3.
  4 cores by default (with a fan); `KIMI_BUILD_CPUS=0,1` on a fanless board
  keeps the peak around ~88 °C.

Runtime is light: the heavy lifting (inference) happens on Moonshot's servers,
so a signed-in `kimi` session does not saturate the SoC the way a local build
does. Where it *can* spike locally is a long agentic loop with heavy tool use
(compiling, grepping large trees); for that, `~/.local/bin/kimi` is a thin
wrapper that pins the agent to `KIMI_CPUS` cores (default all 4) —
`KIMI_CPUS=0,1 kimi …` is the runtime twin of `GROK_CPUS`. Bound any batch
workload (`systemd-run --scope -p MemoryMax=600M`, `timeout`) and keep an eye on
`cat /sys/class/thermal/thermal_zone0/temp`.

## 8. Dead ends (tested / reasoned)

| Attempt | Result |
|---|---|
| `code.kimi.com/install.sh` | No 32-bit artifact → nothing to install on armv7l |
| Prebuilt PyPI wheels for the C deps | No armv7 wheel for Pillow → must compile locally |
| 4-core build on a **fanless** H3 | ~102 °C → machine freeze (add a fan, or `KIMI_BUILD_CPUS=0,1`) |
| `uv tool install` over an existing install | Fails on httptools → skip if present, `upgrade` to update |

## 9. Maintenance

- **Update**: `uv tool upgrade kimi-cli` (never a fresh `uv tool install` over an
  existing install — httptools, see §4).
- **Repair / reinstall from scratch**: `uv tool uninstall kimi-cli` then re-run
  `install.sh`.
- **Never run two heavy builds at once** on the pad; watch the temperature after
  any compile.
