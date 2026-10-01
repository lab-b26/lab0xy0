# Build logs

Failure logs from real build attempts, kept because the repository's value is
auditability: a reader should be able to see **what was actually tried and what
actually happened**, not just a summary of the outcome.

Successful builds write their log to `build/logs/<profile>.log` on the build
host, which is git-ignored. This directory holds the **failed** attempts, which
are the ones worth preserving, because each one is the evidence for a finding.

| File | Kernel | What it proves | Finding |
|---|---|---|---|
| `6.18.54-baseline-FAILED.log` | 6.18.54 (newest LTS) | Kbase did not compile: `__SetPageMovable` / `__ClearPageMovable` implicitly declared. The symbol left `include/linux/migrate.h` in v6.17 and r54p0 calls it unguarded | **F-16** |
| `6.18.54-baseline-FAILED.errors.txt` | " | just the two `error:` lines, for quick reference | F-16 |
| `6.12.111-baseline-FAILED-modpost.log` | 6.12.111 | All of Kbase **compiled** (128 objects, 0 errors) and the build then failed in modpost: `__clk_is_enabled` undefined. A link-time failure, invisible to any config check | **F-17** |
| `6.12.111-baseline-FAILED-modpost.errors.txt` | " | just the `undefined!` line | F-17 |

The full logs are kept verbatim, including all the successful compile lines
before the failure. That is deliberate: "5 Kbase objects compiled then it
stopped" and "all 128 Kbase objects compiled and only the link failed" are very
different statements, and the second one is what made F-17 diagnosable.

Note what is *not* here: no log for a successful build, and no log for the two
tooling failures (F-14, F-15), which happened before compilation started and are
reproducible from the scripts plus the `git` history of the fixes.
