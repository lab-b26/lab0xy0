/* SPDX-License-Identifier: GPL-2.0 */
/*
 * kcov-ctl -- drive Linux KCOV coverage collection for the Kbase lab.
 *
 * The protocol is NOT a write() and NOT self-evident from the node name:
 *   KCOV_INIT_TRACE  allocates the coverage area for this task
 *   KCOV_ENABLE      starts collection  (requires the area: without
 *                    INIT_TRACE this fails -EINVAL, see kcov_ioctl_locked)
 *   KCOV_DISABLE     stops collection
 * Counters are read by mmap() of the kcov fd; kcov_fops has no .read handler.
 * KCOV_INIT_TRACE takes the area SIZE IN WORDS as the ioctl argument itself,
 * not a pointer to it; size < 2 is rejected.
 *
 * CRITICAL SEMANTIC (findings F-36): KCOV task-mode coverage DOES NOT SURVIVE
 * fork(): copy_process calls kcov_task_init() -> kcov_task_reset(), which
 * clears kcov_mode on the child (kernel/fork.c -> kernel/kcov.c). An earlier
 * revision of this tool enabled coverage and then forked the workload into a
 * child, which is never traced -- the recorded PCs were only the parent's own
 * fork/waitpid activity, and the run printed a plausible-looking but wrong
 * count. Fuzzing harnesses must therefore run the workload IN THE ENABLED
 * TASK (what syz-executor does per thread), which is what the inline modes
 * below do.
 *
 * Modes:
 *   kcov-ctl --inline-probe           run kbase_probe_run() in this task
 *   kcov-ctl --inline-read <path>     open()+read() the node in this task
 *   kcov-ctl --inline-window <path>   like --inline-read, but additionally
 *                                     records a window measurement: the exact
 *                                     set of PCs appended while open()+read()
 *                                     executed, bucketed by address region
 *   kcov-ctl <command> [args...]      fork+exec (child is NOT traced; only
 *                                     the parent's own execution is measured)
 *
 * Output lines (parsed by the harness and by humans reading boot logs):
 *   KCOV init-trace ok / enable ok / disable ok (counters frozen ...)
 *   KCOV run: ...
 *   KCOV records=N distinct_pcs=D [TRUNCATED(area full)]
 *   KCOV pc_range=0xLO-0xHI
 *   KCOV module_pcs=M ...
 *   KCOV buckets vmlinux=.. below_vmlinux=.. module_region=.. other=..
 *   KCOV kallsyms cov_pc=0x.. mali_text=0x..-0x..
 *   KCOV mali_text_pcs=K
 *   KCOV window records=W in_mali_window=MW in_vmlinux_window=VW   (--inline-window)
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <linux/kcov.h>

#define KCOV_PATH "/sys/kernel/debug/kcov"

/* Linked in from qemu/target/kbase-probe.c with -DKBASE_PROBE_NO_MAIN. */
int kbase_probe_run(void);

static void mali_range(unsigned long *lo, unsigned long *hi, unsigned long *cov_addr,
		       unsigned long *text_addr);

static int fail(const char *what, int err)
{
	fprintf(stderr, "%s: %s\n", what, strerror(err));
	return 1;
}

static int cmp_ulong(const void *a, const void *b)
{
	unsigned long x = *(const unsigned long *)a;
	unsigned long y = *(const unsigned long *)b;
	return (x > y) - (x < y);
}

static volatile unsigned long *g_area;
static unsigned long g_area_words;

static unsigned long area_count(void)
{
	return g_area[0];
}

/*
 * Find symbol addresses from /proc/kallsyms. Note KCOV canonicalizes recorded
 * PCs by subtracting kaslr_offset(), while kallsyms prints RAW addresses:
 * recorded_pc == raw_pc - slide, where slide = raw("_text") - 0xffffffff81000000.
 * So the module range must be converted: canonical_module = raw - slide.
 * Judging coverage by fixed address ranges (as F-23/P6 originally did) is
 * INVALID whenever the slide is nonzero -- vmlinux canonical PCs always land
 * at link base, module canonical PCs sink by the slide.
 */
static void mali_range(unsigned long *lo, unsigned long *hi, unsigned long *cov_addr,
		       unsigned long *text_addr)
{
	FILE *f = fopen("/proc/kallsyms", "r");
	char line[512];
	*lo = ~0UL; *hi = 0; *cov_addr = 0; *text_addr = 0;
	while (f && fgets(line, sizeof(line), f)) {
		unsigned long a; char t; char n[128]; char m[64] = {0};
		int nf = sscanf(line, "%lx %c %127s [%63[^]]]", &a, &t, n, m);
		if (nf >= 3 && !strcmp(n, "__sanitizer_cov_trace_pc"))
			*cov_addr = a;
		if (nf >= 3 && !strcmp(n, "_text"))
			*text_addr = a;
		if (nf == 4 && !strcmp(m, "mali_kbase")) {
			if (a < *lo) *lo = a;
			if (a > *hi) *hi = a;
		}
	}
	if (f) fclose(f);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: kcov-ctl --inline-probe | --inline-read <path> | "
			"--inline-window <path> | <command> [args...]\n"
			"inline-* run the workload in THIS task (which is what kcov\n"
			"traces). fork+exec measures only the parent's lifecycle.\n");
		return 2;
	}

	int window = argc >= 3 && !strcmp(argv[1], "--inline-window");
	unsigned long mlo = ~0UL, mhi = 0, cov_addr = 0, mtext = 0;

	int fd = open(KCOV_PATH, O_RDWR);
	if (fd < 0)
		return fail("open " KCOV_PATH, errno);

	/*
	 * 8 MiB / 8 = 1 Mi words. With KCOV instrumentation on mali_kbase the
	 * probe path touches far more code than vmlinux-only runs; the old
	 * 256 KiB area could truncate silently and report a lower bound as if
	 * it were a complete count.
	 */
	const unsigned long area_words = 8 * 1024 * 1024 / 8;
	if (ioctl(fd, KCOV_INIT_TRACE, area_words) < 0) {
		int e = errno;
		close(fd);
		return fail("KCOV_INIT_TRACE", e);
	}
	printf("KCOV init-trace ok (area=%lu words / %lu KiB)\n",
	       area_words, area_words * sizeof(unsigned long) / 1024);

	/*
	 * mmap BEFORE enable: the area must exist for tracing, and mapping it
	 * now lets the windowed mode snapshot area[0] around single operations.
	 */
	const size_t map_len = area_words * sizeof(unsigned long);
	unsigned long *area = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, 0);
	if (area == MAP_FAILED) {
		int e = errno;
		close(fd);
		return fail("mmap " KCOV_PATH, e);
	}
	g_area = area;
	g_area_words = area_words;

	/* must run BEFORE ENABLE: reading /proc/kallsyms in the traced task
	 * generates ~1M records of vmlinux string-handling noise and saturates
	 * the area before the measured window starts. */
	{
		unsigned long ta;
		mali_range(&mlo, &mhi, &cov_addr, &ta);
		mtext = ta;
	}

	if (ioctl(fd, KCOV_ENABLE, 0) < 0) {
		int e = errno;
		close(fd);
		return fail("KCOV_ENABLE", e);
	}
	printf("KCOV enable ok (collecting)\n");

	int code = 0;
	char run_desc[256] = "";
	long wn0 = -1, wn1 = -1;      /* window bounds into area[], -1 = none */
	long win_mali = 0, win_vm = 0, win_other = 0;
	if (argc >= 2 && !strcmp(argv[1], "--inline-probe")) {
		/* The workload runs IN THIS TASK: this is what gets traced. */
		wn0 = (long)area_count();
		code = kbase_probe_run();
		wn1 = (long)area_count();
		snprintf(run_desc, sizeof(run_desc), "inline kbase_probe_run() returned %d", code);
	} else if (argc >= 3 &&
		   (!strcmp(argv[1], "--inline-read") || window)) {
		wn0 = (long)area_count();
		int tfd = open(argv[2], O_RDONLY | O_CLOEXEC);
		if (tfd < 0) {
			snprintf(run_desc, sizeof(run_desc), "inline read %s open failed: %s",
				 argv[2], strerror(errno));
			code = 126;
		} else {
			char buf[512];
			ssize_t n = read(tfd, buf, sizeof(buf));
			close(tfd);
			snprintf(run_desc, sizeof(run_desc), "inline read %s -> %zd", argv[2], n);
		}
		wn1 = (long)area_count();
	} else {
		/* Legacy fork+exec: the child is NOT traced (kcov_task_init). */
		pid_t pid = fork();
		if (pid < 0) {
			int e = errno;
			close(fd);
			return fail("fork", e);
		}
		if (pid == 0) {
			execvp(argv[1], &argv[1]);
			fprintf(stderr, "exec %s: %s\n", argv[1], strerror(errno));
			_exit(127);
		}
		int status = 0;
		if (waitpid(pid, &status, 0) < 0) {
			int e = errno;
			close(fd);
			return fail("waitpid", e);
		}
		code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
		snprintf(run_desc, sizeof(run_desc), "%s exited %d (untraced child)", argv[1], code);
	}

	/*
	 * Freeze BEFORE counting: while KCOV is still enabled, the counting
	 * loop itself is traced and keeps appending to the area (a live-area
	 * count once printed records together with a spurious TRUNCATED flag).
	 * KCOV_DISABLE clears this task's tracing (kcov_stop) but does NOT free
	 * the area, so the counters stay readable as a frozen snapshot.
	 */
	if (ioctl(fd, KCOV_DISABLE, 0) < 0)
		fprintf(stderr, "warning: KCOV_DISABLE: %s\n", strerror(errno));
	else
		printf("KCOV disable ok (counters frozen before counting)\n");

	/* All reporting happens AFTER DISABLE: printing to a serial console
	 * from a traced task floods the area with console-path PCs (observed:
	 * area filled to TRUNCATION between the end of the workload and the
	 * stats line). The measurement window closes at DISABLE; printing is
	 * deliberately not part of it. */
	if (run_desc[0])
		printf("KCOV run: %s\n", run_desc);
	if (wn0 >= 0 && wn1 >= wn0) {
		unsigned long sl_ = mtext ? mtext - 0xffffffff81000000UL : 0;
		unsigned long cm_ = mlo != ~0UL ? mlo - sl_ : 0;
		unsigned long ch_ = mhi ? mhi - sl_ : 0;
		for (unsigned long i = (unsigned long)wn0 + 1;
		     i <= (unsigned long)wn1 && i < area_words; i++) {
			unsigned long pc = g_area[i];
			if (mhi && pc >= cm_ && pc <= ch_)
				win_mali++;
			else if (pc >= 0xffffffff80000000UL)
				win_vm++;
			else
				win_other++;
		}
		printf("KCOV window records=%ld in_mali_window=%ld in_vmlinux_window=%ld other=%ld "
		       "(mali_text_canonical=0x%lx-0x%lx)\n",
		       wn1 - wn0, win_mali, win_vm, win_other, cm_, ch_);
	}

	unsigned long total = area[0];
	if (total > area_words - 1)
		total = area_words - 1;   /* defensive: never read past the area */

	unsigned long *pcs = malloc(total * sizeof(unsigned long));
	if (!pcs) {
		munmap(area, map_len);
		close(fd);
		return fail("malloc", ENOMEM);
	}
	for (unsigned long i = 0; i < total; i++)
		pcs[i] = area[i + 1];

	/* Sort + unique, compacting IN PLACE so pcs[0..distinct) really are the
	 * distinct set. (The first version counted over an un-compacted prefix
	 * of the sorted array: module PCs, which sort high, were never looked
	 * at -- reported module coverage of 0 against 540k module records.) */
	qsort(pcs, total, sizeof(unsigned long), cmp_ulong);
	unsigned long distinct = 0;
	for (unsigned long i = 0; i < total; i++)
		if (i == 0 || pcs[i] != pcs[i - 1])
			pcs[distinct++] = pcs[i];

	const int truncated = (area[0] >= area_words - 1);

	/*
	 * P6's falsifiable acceptance test, computed here: on x86_64 module
	 * text is allocated at MODULES_VADDR (0xffffffffa0000000) and up, and
	 * canonicalize_ip() only subtracts the KASLR offset (zero when KASLR
	 * did not slide, as on this harness -- recorded min sits at
	 * _text+0x5xxxx, not at a 2 MiB boundary). With slide==0 any PC at or
	 * above 0xffffffffa0000000 came from a loadable module.
	 */
	unsigned long module_pcs = 0, vmlinux_pcs = 0, other_pcs = 0;
	unsigned long klo = ~0UL, khi = 0, kcov = 0, ktext = 0, msize = 0;
	{
		unsigned long k_lo, k_hi, k_cov, k_text;
		mali_range(&k_lo, &k_hi, &k_cov, &k_text);
		klo = k_lo; khi = k_hi; kcov = k_cov; ktext = k_text;
	}
	/* slide is what canonicalize_ip() subtracted from every recorded pc */
	const unsigned long slide = ktext ? ktext - 0xffffffff81000000UL : 0;
	const unsigned long cmlo = klo != ~0UL ? klo - slide : 0;
	const unsigned long cmhi = khi ? khi - slide : 0;
	if (klo != ~0UL)
		msize = khi - klo;
	for (unsigned long i = 0; i < distinct; i++) {
		if (msize && pcs[i] >= cmlo && pcs[i] <= cmhi)
			module_pcs++;
		else if (pcs[i] >= 0xffffffff81000000UL && pcs[i] < 0xffffffffa0000000UL)
			vmlinux_pcs++;
		else
			other_pcs++;
	}

	printf("KCOV records=%lu distinct_pcs=%lu%s\n",
	       total, distinct,
	       truncated ? " TRUNCATED(area full)" : "");
	if (distinct > 0)
		printf("KCOV pc_range=0x%lx-0x%lx\n", pcs[0], pcs[distinct - 1]);
	printf("KCOV slide=0x%lx mali_text_raw=0x%lx-0x%lx canonical=0x%lx-0x%lx\n",
	       (unsigned long)(ktext ? ktext - 0xffffffff81000000UL : 0),
	       klo == ~0UL ? 0 : klo, khi, cmlo, cmhi);
	printf("KCOV module_pcs=%lu%s\n", module_pcs,
	       module_pcs ? " (module text covered)" : " (VMLINUX ONLY -- module not traced)");
	printf("KCOV buckets vmlinux=%lu module(canonical)=%lu other=%lu\n",
	       vmlinux_pcs, module_pcs, other_pcs);

	printf("KCOV kallsyms cov_pc=0x%lx\n", kcov);
	{
		FILE *f = fopen("/proc/modules", "r");
		char line[512];
		while (f && fgets(line, sizeof(line), f)) {
			char name[64]; unsigned long sz, addr; int rc;
			if (sscanf(line, "%63s %lu %d %*s %*s %lx", name, &sz, &rc, &addr) == 4)
				if (!strcmp(name, "mali_kbase"))
					printf("KCOV procmodules mali_kbase base=0x%lx size=%lu\n",
					       addr, sz);
		}
		if (f)
			fclose(f);
	}

	free(pcs);
	munmap(area, map_len);
	close(fd);
	/* Propagate the workload status: a run that crashed the workload must
	 * not look like a clean one. */
	return code == 0 ? 0 : (code & 0xff);
}
