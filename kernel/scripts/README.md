# kernel/ scripts

Build machinery for the portable lab. These scripts run on the **build host**
(not the machine that organised the repo).

## Execution status — read this before trusting anything

| Script | Syntax-checked here | Fully executed here |
|---|---|---|
| `preflight.sh` | yes | yes, read-only (correctly reported `NOT READY`) |
| `bootstrap.sh` | yes | yes, `--check` mode only (read-only) |
| `codespace-setup.sh` | yes | yes, all modes, against an **isolated repo copy with a fake `HOME`** and stubbed `apt-get`/`sudo`, so the git-identity / SSH / gh logic was exercised without installing anything or touching this host's keys |
| `resolve-kernel-pin.sh` | yes | **yes** — failed first (404s, F-13), fixed, then wrote the real pin |
| `fetch-kernel.sh` | yes | **yes** — 6.18.54 and 6.12.111, both checksums verified |
| `apply-patches.sh` | yes | **yes** — 6/6 vendor + 1 research patch applied |
| `build.sh` | yes | **yes** — a real kernel, twice; the second build succeeded |

### Executed against a real kernel (2026-10-01)

The stubbed-tree test in `build.sh` was **not sufficient**. Running these scripts
against a real kernel found **three defects that both `bash -n` and the stub
passed**:

| Script | Defect found only by real execution | Finding |
|---|---|---|
| `resolve-kernel-pin.sh` | built `v6.18/…` URLs; kernel.org files the current series under `v6.x`/`v7.x`. Also mis-parsed `releases.json` (whitespace `read` collapsed an empty field, silently shifting the URL into the wrong variable) | **F-13** |
| `build.sh` | wrote a C comment `/* … */` into `drivers/gpu/Kconfig`; valid in a Makefile, a hard kconfig syntax error. `make defconfig` died | **F-14** |
| `build.sh` | step 5/8 grepped only `^CONFIG_X=`, so it reported every `=n` line MISSING — including the mandatory `CONFIG_MALI_DEBUG=n`, which is present and correct | **F-15** |

All three are fixed and re-verified. This is recorded rather than quietly fixed
because the stub was specifically designed to catch this class, and it did not.

Two more failures came from the kernel/Kbase side, not the tooling:
`__SetPageMovable` removed in v6.17 (**F-16**) and `__clk_is_enabled` never built
without `CONFIG_COMMON_CLK` (**F-17**). No stub could have found either.

**Known limitation, stated plainly:** step 5/8 verifies `.config`, **not the
link**. It correctly caught a broken Kconfig and a mis-set option, but it cannot
see an undefined symbol — that only appears in modpost, after every object has
already compiled. A build passing step 5/8 is necessary, not sufficient.

## Scripts (run in this order)

| # | Script | What it does | Network? |
|---|---|---|---|
| 0a | `codespace-setup.sh [--check] [--yes] [--https]` | **Start here on a fresh clone/Codespace.** Checks the machine spec against `BUILD-HOST.md`, installs the toolchain via `bootstrap.sh`, sets a git identity, arranges GitHub access (SSH key or HTTPS), installs `gh`, then runs `preflight.sh`. `--check` reports only. | apt |
| 0b | `bootstrap.sh [--check] [--yes]` | installs the build dependencies (`../BUILD-HOST.md` package list), then runs `preflight.sh`. `codespace-setup.sh` calls this, so invoke it directly only if you want just the packages. | apt |
| 0c | `resolve-kernel-pin.sh [--dry-run] [--force]` | picks the newest kernel.org release marked `longterm` (**that set is the LTS series**), takes its SHA-256 from kernel.org's own `sha256sums.asc`, and writes `kernel/sources/kernel.pin`. Implements Arm's "latest ACK or latest stable/longterm" guidance literally. | yes |
| 1 | `preflight.sh` | read-only host check (arch, disk, RAM, tools, headers, checksums, pin). Exits non-zero if the host cannot build. | no |
| 2 | `fetch-kernel.sh` | reads `kernel.pin`, downloads the exact tarball, **verifies SHA-256 (fatal on mismatch)**, extracts to `kernel/sources/linux/<version>/`. No floating "latest". | yes |
| 3 | `apply-patches.sh` | extracts pristine r54p0 to `work/kbase-pristine/` (never patched in place), copies to `work/kbase-patched/`, applies the six Arm patches in order with `patch -p1`, then applies this project's research patches from `kernel/patches/` **after** them, and writes a separate hash for each series. | no |
| 4 | `build.sh --profile <p>` | stages Kbase into the kernel tree, kbuild-ifies it, wires `drivers/gpu`, seeds and **verifies** `.config`, compiles the kernel, builds the module, emits metadata. | no |

There is deliberately **one** `build.sh --profile …`, not four
`build-<profile>.sh` scripts.

## What `codespace-setup.sh` exists to solve

A fresh Codespace fails in ways that have nothing to do with kernel building, and
each failure lands at a confusing moment:

| Problem | Consequence if unhandled |
|---|---|
| 2-core/8 GB machine | `preflight.sh` fails on disk/RAM only after you start a build |
| no git identity | `git commit` of the kernel pin fails — and the pin is what makes the kernel reproducible |
| no SSH key, but the remote is `git@github.com:` | the clone itself fails |
| no `gh` | cannot push the resolved pin back without extra manual auth |

It generates an SSH key **and tells you to add the public key** (it cannot add it
for you), or `--https` to switch the remote instead. It writes git identity
repo-locally so nothing leaks into unrelated repositories on a shared host.

## Two things that are easy to get wrong, and are handled here

**1. kbuild prefers `Makefile` over `Kbuild`.** Every directory Kbase owns ships
*both*, and the `Makefile` is the Android/out-of-tree one (it expects `KDIR` and
errors otherwise). A plain copy therefore never reaches
`obj-$(CONFIG_MALI_MIDGARD) += midgard/`. `build.sh` step 2 sets the Android
`Makefile` aside as `Makefile.android-orig` and installs `Kbuild` in its place.
This happens only inside the disposable fetched tree — `vendor/arm/` is never
touched. To reset: `rm -rf kernel/sources/linux/<version>` and re-fetch.

**2. The payload root is the kernel tree root.** `driver/product/kernel/` contains
`drivers/`, `include/` and `Documentation/`, so staging merges it into the kernel
*source root*, not into `drivers/gpu/arm/`.

Step 5/8 then re-reads the merged `.config` and checks that **every** `CONFIG_*` in
the profile fragment actually took effect — detecting symbols dropped as unknown
(values silently clobbered back to defaults is the dangerous case). If any symbol
did not take, it prints a table and exits non-zero *before* compiling, because a
kernel that quietly lacks Kbase is worse than no kernel.

Two subtleties this check now handles, both learned by getting them wrong:

- **kconfig never writes `CONFIG_X=n`.** A symbol set to `n` appears as
  `# CONFIG_X is not set`, so matching only `^CONFIG_X=` reports every disabling
  line as missing (F-15). The check accepts either spelling, and reports MISSING
  only when the symbol is absent from the Kconfig entirely.
- **The injected marker must be a `#` comment, not `/* … */`.** The same tag is
  written to `drivers/gpu/Makefile` *and* `drivers/gpu/Kconfig`; a C comment is
  valid in the first and a fatal syntax error in the second (F-14).

And what it still cannot do: catch a **link** failure. Every fragment symbol
verifying correctly does not mean the module links — that is a separate failure
class which only appears in modpost (F-17).

## Design rules these scripts follow

- **Repository-relative paths.** No hard-coded host paths, so a clone runs anywhere.
- **Pinned and verified inputs.** The kernel comes from `kernel.pin` with a
  mandatory checksum. A cached tarball that does not match the pin is a hard
  error, never silently overwritten.
- **Fail loudly.** Bad arguments exit non-zero; checksum mismatch is fatal; the
  host preflight refuses an inadequate machine; a fragment symbol that did not take
  stops the build.
- **Nothing hidden.** Each build writes a log under `build/logs/` and a
  `build-metadata.txt` (config hash, patch-series hash, payload fingerprint,
  compiler, host, timestamp).
- **Non-destructive.** The pristine Kbase tree is never patched in place; the
  patched tree is rebuilt from pristine each run.

## What these scripts do NOT do

- They do **not** boot QEMU, package an artifact, or mark anything portable
  (separate steps; see `../../artifacts/README.md`).
- They do **not** build a rootfs or install syzkaller — `qemu/rootfs/` and
  `syzkaller/` are documentation placeholders, so those states are not reachable
  from this repository alone.
- They do **not** advance `research/state.md`; state advances only after
  human/tool verification, per `../BUILD-PLAN.md`.
- They do **not** duplicate program scope policy — see
  `../../research/program-scope.md`.

## Order of operations

```bash
bash kernel/scripts/bootstrap.sh --yes
bash kernel/scripts/resolve-kernel-pin.sh --dry-run   # inspect the choice first
bash kernel/scripts/resolve-kernel-pin.sh
bash kernel/scripts/preflight.sh                      # expect READY
# COMMIT the pin, so the kernel choice is reproducible rather than local.
bash kernel/scripts/fetch-kernel.sh
bash kernel/scripts/apply-patches.sh
bash kernel/scripts/build.sh --profile baseline
```

This exact sequence has now been run (2026-10-01), with one deviation that is
recorded rather than hidden: `resolve-kernel-pin.sh` selected 6.18.54, the
newest LTS, and that kernel **cannot build Kbase** (F-16). The pin was moved to
**6.12.111** — the newest LTS that does build — and `kernel/sources/kernel.pin`
records both the rejected candidate and the reason.

Then follow `../BUILD-PLAN.md` for baseline validation, the instrumented
profiles, rootfs/QEMU, packaging, and the clean-location portability test.

**On a 32 GB build host**, build one profile, package and checksum it, then
delete the tree before the next (measured costs: 141 MB tarball, ~1.7 GB
extracted, ~1.5 GB per `O=` output, ~15 min compile on 4 jobs).