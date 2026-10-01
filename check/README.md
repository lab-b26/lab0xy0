# check/ — verifying the claims, and proving the checks work

Two scripts:

| Script | Answers |
|---|---|
| `check/check-all.sh` | "are the claims this repository makes still true?" |
| `check/selftest.sh` | "would those checks notice if they were wrong?" |

Both exit non-zero on failure so either can gate a commit or a CI step.

## Why this directory exists

Every serious defect found in this project had the same shape: **a tooling layer
accepted a wrong input and produced a plausible result.** Nothing crashed.

| | What went wrong | What it reported |
|---|---|---|
| F-20 | `build.sh`'s fragment merge deleted every `# CONFIG_X is not set` line | success; a `choice` silently fell back to its default and `MALI_REAL_HW` came back **on** |
| F-21 | `kasan.config` named no `choice` member | success; the fragment meant the opposite of what it said |
| F-24 | `debug.config` asked for `CONFIG_DEBUG_INFO=y` | a message blaming a Kconfig line **that exists** |
| F-25 | a fragment header claimed a build that had not happened | a readable, confident header |
| F-26 | `CONFIG_DMA_SHARED_BUFFER=y` was inert | `[ ok ]` — the value was right, the *cause* was not |
| F-23 | KCOV counters were read as a bitset | `covered_pcs=656023`; the real figure was **2882** |

A crash is survivable. A confident wrong answer survives review, which is why these
were found late or by accident. So the tests here do not ask "does the code run" —
they ask "is the claim still true", and they check the claim rather than the code
path that produced it.

## Tiers

Cheap tiers need no toolchain and no QEMU, so they can run on every change.

| Tier | Needs | Checks |
|---|---|---|
| **A** | nothing | A1 scripts parse · A2 fragment symbols vs the real Kconfig · A3 §8.3 scope guard · A4 kernel pin vs the tree · A5 vendor patches byte-identical · A6 findings numbered contiguously · A7 header/count/status claims vs the filesystem · A8 cited boot logs exist and show real passes · A9 no build tree committed · A10 no orphan binary · A11 `INERT` annotations are truthful · A12 TODO `DONE` items cite real evidence |
| **B** | `artifacts/` | B1 `SHA256SUMS` · B2 manifest shape **and ladder state** · B3 `PORTABLE` claim backed by a clean-location log · B4 no absolute `build/` path · B5 scope class `DISCOVERY-ONLY` |
| **C** | QEMU | C1 each packaged artifact passes all five boot assertions **with `--strict-artifact`** |
| **D** | nothing | D1 `state.md` current state matches its last transition row · D2 project ladder moves one way only · D3 bundle state is on the *artifact* ladder, never a project-ladder state |

```sh
check/check-all.sh              # A + B  (default)
check/check-all.sh --tier A     # seconds, no build, no QEMU
check/check-all.sh --all        # A + B + C + D — boots every bundle
check/check-all.sh --list       # the checks, and exit
check/selftest.sh               # prove each check goes red
```

## The checks that are not obvious

**A2 judges structurally, not by value.** A fragment line naming a prompt-less
symbol can never take effect. The tempting check is "is the symbol `y` in
`.config`?", and it does not work: kconfig *writes* derived symbols to `.config`
when they are `y`, so `CONFIG_DEBUG_INFO=y` appears there purely because
`CONFIG_DEBUG_INFO_DWARF5=y` on the next line selects it. A value check passes the
exact defect it exists to catch. A2 therefore compares the fragment against the
pinned tree's Kconfig — `absent` (wrong kernel) / `invisible` (derived, set the
`select`ing symbol) / `settable`.

**A2 and A11 are two halves of one rule.** An inert line is acceptable only if the
fragment *says* it is inert. A11 then verifies the annotation is true, so `# INERT`
cannot become a blanket switch for turning A2 off. Requiring the note to name the
symbol — not just the word — is what keeps the annotation attached to its own line:
in `debug.config` the `DMA_SHARED_BUFFER` note sits directly above four further
symbols that would otherwise be swept in with it. (The first version of A11 did
sweep them in, and A11 caught the resulting inconsistency itself.)

**A7 strips negations before matching.** A naive version reads `NOT YET BUILT` as
`BUILT` and fails every honest header. "BUILT" may be backed by `build/<p>/.config`
*or*, when the tree was pruned to reclaim disk, by a full-pass boot log — a boot log
is durable evidence and a 1 GB tree is not. Claiming `BUILT` with neither is the
failure.

**A7 also writes the README table.** It caught `kasan.config` and `kcov.config`
still claiming `NOT BUILT` after both had been built and booted — stale in the
*understating* direction, which is just as wrong.

**A12 reads `TODO.md`.** A task list where `DONE` is an assertion is a wish list.
Every `DONE` step must carry an `Evidence:` line, and every repo path on an
`Evidence:` line must exist. Backticked names in prose are not verified — demanding
a full repo path for every mention would make the document unreadable without making
the plan any more honest.

**D2 and D3 split two ladders that share four names.** `research/state.md` has a
*project* ladder (17 states, ending in `FUZZING_STARTED`); `artifacts/README.md` has
an *artifact* ladder (6 states, `BUILT` → `PORTABLE_ARTIFACT_VERIFIED`). Four names
appear in both. D2 originally compared a bundle's status against the project's
`Current state:` and failed on a **true** claim — `artifacts/baseline` really is
portable-verified while the project ledger really is still `NOT_STARTED`. One
bundle's portability is not the same event as the project's state, and comparing them
is meaningless. So each check now validates a claim against the ledger that owns it:
D2 the project, D3 the artifact (and D3 additionally rejects a manifest naming a
project-only state like `SYZKALLER_CONNECTED`, which would be claiming a fuzzer that
does not exist). F-30.

**A mention is not a claim.** D2's first version grepped for bare state *names* and
so failed on `kernel/BUILD-PLAN.md` for defining the ladder and on
`artifacts/README.md` for explaining what `PORTABLE_ARTIFACT_VERIFIED` means. A
check that fires on correct documentation teaches its reader to ignore it, so the
checks match only claim-shaped lines.

**C1 runs with `--strict-artifact`, and that is the point.** `run.sh` resolves
components artifact-first with a `build/` fallback, for convenience before a bundle
exists. Left alone, that fallback is also how a *non-self-contained* bundle passes:
delete `artifacts/<p>/kernel/bzImage` and the boot quietly succeeds from
`build/<p>/`. `--strict-artifact` forbids it, so a missing component is a hard error
naming the bundle. The first implementation of the flag was a no-op — `shift` left
the fallback inside `"$@"`, the candidate loop matched it, and the `STRICT` gate was
never evaluated. `STRICT=1` appeared in the trace while the boot used `build/`
anyway. Only the negative case (hide the file, require refusal) exposed it. F-31.

## `selftest.sh` — the part that makes the rest trustworthy

A checker that never fails is indistinguishable from no checker. `selftest.sh`
re-injects each historical defect and asserts the named check goes **red**:

| Case | Defect re-injected | Check |
|---|---|---|
| F-24 | `CONFIG_DEBUG_INFO=y` (prompt-less) | A2 |
| F-24b | a symbol the kernel does not have at all | A2 |
| F-26 | `# INERT` on a **settable** symbol | A11 |
| F-21 | `MALI_DEBUG=y` outside `debug.config` | A3 |
| F-25 | header claims `BUILT` for a profile with no build | A7 |
| F-25b | `artifacts produced: 99` on disk with 3 | A7 |
| — | cites a boot log that does not exist | A8 |
| — | a gap in the findings numbering | A6 |
| vendor | a byte appended to a vendor patch | A5 |
| F-28 | a byte appended to a `SHA256SUMS`-covered bundle file | B1 |
| F-31 | hide a bundle's `bzImage`; `--strict-artifact` must **refuse** | C1 |

Current result: **15 proven, 0 not-proven, 4 clean-tree positive controls.**

Note the F-28 case: its first version tampered with a bundle's `README.md` and B1
stayed green. The instinct is to suspect the check; here the check was right and the
*test* was wrong — `README.md` is genuinely outside the checksum set, which is
itself finding F-28.

It also runs four **positive controls** first: on the clean tree each of those checks
must stay silent. A check that fires on a correct repository is a false positive and
fails the run, so the suite cannot be satisfied by checks that fail everything.

A case that cannot be made to fail is reported **NOT PROVEN**, never as passing.

**Safety.** Cases mutate real repository files. Each touched file is copied to a
backup directory first and restored by a trap on `EXIT`/`INT`/`TERM`, then compared
with `cmp` to confirm it came back byte-identical. If the script is killed with
`SIGKILL` the backups are left in `/tmp/check-selftest-backup.*` and named on stderr.
A selftest that leaves the repository modified is itself a defect, so that is
verified rather than asserted.

Do not run `check/selftest.sh` concurrently with `check/check-all.sh` or with an
edit to any file it mutates — it temporarily reintroduces known-bad content on
purpose.

## Scope

**DISCOVERY-ONLY.** Per DECISION-1 the x86_64 + `MALI_NO_MALI` harness is
INVESTIGATION-ONLY. A green run here means *the simulator claims are internally
consistent*. It never means the driver is correct on Arm hardware, and no check in
this directory can establish that — there is no such check, deliberately.

Two checks are about **scope** rather than correctness, and are easy to mistake for
bureaucracy:

- **A3** fails if `MALI_DEBUG=y` appears outside `debug.config`, or if the fragment
  holding it does not declare itself non-conforming (§8.3 mandates `MALI_DEBUG=n`).
- **B5** fails if any bundle's `scope_class` is not `DISCOVERY-ONLY`.

A bundle that boots cleanly and is labelled as conformance evidence is the failure
mode this project exists to avoid, so the label is checked like any other claim.