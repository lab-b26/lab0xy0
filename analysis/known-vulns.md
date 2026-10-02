# Known-CVE map for Mali kbase, and what it says about r54p0-01eac0

Source: NVD API, fetched 2026-10-01 (`services.nvd.nist.gov`, keyword searches
"Arm Mali GPU kernel", "Mali 5th Gen GPU Kernel", individual IDs). The
`check/check-all.sh` harness does not yet verify this file; the two logic gates
that matter elsewhere (PORTABLE evidence, ladder claims) live in other checks.
Nothing here is a claim of exploitability of *our* bundles -- scope is
DISCOVERY-ONLY (DECISION-1), EL0-only (program-scope SS8.2).

## The class pattern from 22 driver CVEs

Nearly the entire public Mali kbase CVE set is ONE class upstream of two effects:

> **improper GPU memory processing** -> use-after-free, write-to-read-only, or
> limited out-of-bounds write, all by a local non-privileged user.

| CVE | Class | Fixed at (families) |
|---|---|---|
| CVE-2021-28663 | memory-mishandling UAF (KEV-added after in-the-wild reports) | Bifrost r29p0, Valhall ~r29p0 |
| CVE-2021-28664 | write to read-only pages | Bifrost r29p0 |
| CVE-2021-29256 | access to freed memory (info leak / privesc) | r30p0 |
| CVE-2021-44828 | write to read-only | Midgard r31p0 / Bifrost-Valhall r35p0 |
| CVE-2022-22706 | write to read-only | r31p0 / r35p0 |
| CVE-2022-28348 | improper mem ops -> UAF | r32p0 / r37p0 |
| CVE-2022-28349 | UAF | Midgard r30p0, Bifrost/Valhall r24p0 |
| CVE-2022-28350 | UAF | Valhall r37p0 |
| CVE-2022-33917 | freed-memory access | Valhall r39p0 |
| CVE-2022-36449 | freed memory + limited OOB write | r37p0-ish |
| CVE-2022-38181 | alias/COW breadth, freed-memory access (Project Zero 2324) | Bifrost/Valhall r40p0 |
| CVE-2022-41757 | write to RO / freed mem | (fixed r39-ish) |
| CVE-2022-42716 | UAF | r38p0 |
| CVE-2022-46891 | UAF | Midgard r32p0+ |
| CVE-2022-46394/46395 | freed-mem / OOB | r33/r42p0 |
| CVE-2022-46781/46396 | OOB access beyond buffer | Valhall r42p0 |
| CVE-2023-28147 | freed-memory access | Midgard r33p0 / r43p0-or-less |
| CVE-2023-28469 | freed-memory access | Valhall r43p0 |
| CVE-2023-4211 | UAF -- **CISA KEV, in-the-wild** | Midgard r32p0, Bifrost/Valhall/5thGen r43p0 |
| CVE-2023-5643 | OOB write | r41p0-r45p0, fixed r46p0 |
| CVE-2024-1067 | UAF cross-process (Armv8.0-specific combination) | r41p0-r47p0, fixed r48p0 |

**Where r54p0 sits:** every public CVE's fix version is r47p0 or earlier.
`r54p0-01eac0` is downstream of all of them, so none is *known-applicable* by
version. Variant hunting is the remaining honest research surface.

## What the variants have historically been

Reading these by technique rather than by ID, the driver keeps being bitten in:

1. **Physical-page aliasing** -- multiple GPU VAs per alloc (alias + mem groups),
   where freeing/shrinking one VA frees pages still mapped elsewhere
   (CVE-2022-38181 is the canonical write-up).
2. **Flags transitions** that flip PROT bits after mapping (the write-to-RO
   family: CVE-2021-28664, CVE-2021-44828, CVE-2022-22706).
3. **JIT / commit growth races** against page faults and soft-stops
   (Midgard/Job-Manager era; CSF mostly retired these paths).
4. **CSF/5th-Gen bookkeeping** -- queue groups, tiler heaps, KCPU fences
   (`r41p0`-era wave: CVE-2023-4211, CVE-2023-5643, CVE-2024-1067).

## How this maps onto the r54p0 tree in this repository

Paths are `work/kbase-patched/driver/product/kernel/drivers/gpu/arm/midgard/`
unless noted. All references were read in that tree on 2026-10-01/02.

| Area | Hardening observed (with line refs) | Verdict this audit |
|---|---|---|
| `KBASE_IOCTL_MEM_ALIAS` | overflow-checked `stride*nents` (1758-1768); aliased regions must be NATIVE, non-JIT, non-ephemeral, coherent-match, bounds checked vs `alloc->nents` (1818-1865); pins `gpu_mappings` immediately (1882) | hardened vs the aliasing class; legacy aliasing of *imported UMM* is pre-rejected (1843) -- the CVE-2022-38181 shape |
| `MEM_FLAGS_CHANGE` | masks restrict to `BASE_MEM_FLAGS_MODIFIABLE_*` subsets (1085-1103) -- write-to-RO is structurally excluded via this ioctl; remaining knob is coherency + evictable-invariants (gpu_mappings==1, kernel_mappings==0) | the CVE-2021-28664 class is closed here |
| `MEM_COMMIT` / JIT | requires GROWABLE, not multi-mapped, not shrinkable, not ACTIVE_JIT, bounds vs `nr_pages`; two-phase alloc/rollback (`kbase_alloc_phy_pages_helper` then mapping update) | hardened |
| CSF tiler heap | `buf_desc_reg` lifetime pinned with no_user_free inc/dec paired at 739/529; list-based `find_tiler_heap` under one mutex; generation counter (`heap_id`) distinguishes ABA re-use at 998 | no user-controlled arithmetic slides through (chunk_size/mask/counters all validated 686-699) |
| KCPU command queues | `id` domain is u8, array is 256 (BUILD_BUG_ON, kcpu_defs:46); CQS object count capped by `BASEP_KCPU_CQS_MAX_NUM_OBJS` + `check_mul_overflow` + alignment pre-screen (859-893); fences `fd_install` last (1910-1914) | the fd-lifetime family (CVE-2023-4211 shape) looks closed here |
| `kbase_ioctl_read_user_page` | neutered to `LATEST_FLUSH` register only (1596-1607) | the old read-page info-leak is gone |
| ioctl macro layer | `_IOC_DIR`/`_IOC_SIZE` `BUILD_BUG_ON`s; copy-into-stack-param; padding check per cmd (mali_kbase_ioctl_helpers.h) | clean construction |
| `kbase_vmap_phy_pages` | page_count wrap check (3053), page_index+page_count wrap check (3060), backed-size bound (3063) | hard |

## Seams NOT yet proved safe, candidates for coverage-guided work (blocked on F-2)

1. `kbase_csf_queue_group_create*` deep validation (mask/threshold/capacity
   combinations) -- only surface-reading done here.
2. HWCNT reader fd (`kbase_api_hwcnt_reader_setup`) -- fd-backed ring mmap is a
   historically fragile pattern.
3. `csf/mali_kbase_csf_tl_reader.c` -- firmware timeline ring shared with
   userspace.
4. Memory group manager cross-process sharing (`memory_group_manager.c`) -- the
   CVE-2024-1067 family ("other processes' userspace memory affected").
5. Error-path ordering under `MALI_UNIT_TEST` / NO_MALI backdoor ioctls -- only
   partially audited.

## The honest scope limit, recorded where it bites

The three decisive kbase CVEs of record (28663, 4211, and the COW/aliasing
write-ups) all required a **real GPU** because their exploitation goes through
GPU page-fault / COW / soft-stop paths that no `MALI_NO_MALI` dummy model
executes. In this harness the CSF firmware is stubbed (`kbase_csf_firmware_no_mali.c`),
so this audit can only cover *argument validation and bookkeeping* -- which is
the class this repository's own `qemu/target/kbase-negargs.c` battery now tests at
runtime. Anything further needs the coverage patch (P6 / F-2) plus GPU-side
fault injection, which is out of scope here by DECISION-1.

## Runtime coverage of this audit

`qemu/target/kbase-negargs.c` runs on every profile boot (assertion 6) and
currently rejects all 17 malformed-ioctl cases (2 controls must accept):
`unexpected=0`, see any `*-BOOT.log`. Cases are labelled by the finding they
verify (`F-37`). The battery verifies *what the audit says must be rejected* is
rejected -- it is not proof of absence of a variant.
