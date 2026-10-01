/* SPDX-License-Identifier: GPL-2.0 */
/*
 * kbase-probe -- exercise the Kbase userspace target interface (EL0).
 *
 * PURPOSE
 * -------
 * Loading mali_kbase.ko only proves the module initialises. It says nothing
 * about whether the interface a fuzzer would actually drive is reachable from
 * an ordinary unprivileged process. This program is the smallest thing that
 * can answer that: open /dev/mali0, perform the API handshake Kbase requires
 * before any other ioctl is honoured, read the GPU property block, and round
 * trip a GPU memory allocation.
 *
 * It is a PROBE, not a fuzzer and not a PoC. It issues well-formed requests
 * with well-formed arguments and reports what came back. Each phase is
 * independent and the exit status is a bitmask, so a partial result is still
 * evidence rather than a single pass/fail.
 *
 * Exit status is the PASS bitmask. A partial success is a non-zero value, but
 * a specific combination is not a failure signal: read "failed=0x000" in the
 * summary line instead. Do not encode failure in the exit status, or a fully
 * successful run (every bit set, 0x1ff) would be indistinguishable from one
 * that passed most phases and then broke.
 *
 * PASS BITMASK (all bits set == every phase succeeded)
 *   0x01  opened /dev/mali0
 *   0x02  KBASE_IOCTL_VERSION_CHECK handshake accepted
 *   0x04  KBASE_IOCTL_SET_FLAGS accepted (this is what creates the context)
 *   0x08  KBASE_IOCTL_GET_GPUPROPS returned a size
 *   0x10  KBASE_IOCTL_GET_GPUPROPS returned a property block
 *   0x20  KBASE_IOCTL_MEM_ALLOC accepted
 *   0x40  the allocation was bound to an address (mmap, when SAME_VA)
 *   0x80  KBASE_IOCTL_MEM_QUERY reported a commit size
 *   0x100 the allocation was released (munmap, or MEM_FREE when not SAME_VA)
 *
 * SCOPE
 * -----
 * Everything here is an unprivileged userspace ioctl on /dev/mali0, i.e. the
 * EL0 criterion in research/program-scope.md 8.2. No module parameter is
 * overridden, so the dynamic-configuration rule in 8.4 is satisfied by
 * construction: the module is loaded with its defaults.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <uapi/gpu/arm/midgard/mali_base_kernel.h>
#include <uapi/gpu/arm/midgard/mali_gpu_props.h>
#include <uapi/gpu/arm/midgard/mali_kbase_ioctl.h>
#include <uapi/gpu/arm/midgard/mali_kbase_mem_flags.h>

#define KBASE_DEV "/dev/mali0"

/* Proposal to the handshake. Kbase clamps minor to min(its own, ours) when
 * major matches, and otherwise answers with its own version so userspace can
 * bail out. Either way the return value tells us what Kbase supports.
 */
#define PROBE_VERSION_MAJOR BASE_UK_VERSION_MAJOR
#define PROBE_VERSION_MINOR BASE_UK_VERSION_MINOR

/* Pass bits occupy 0x001..0x100; the matching failure bit is that pass bit
 * shifted left 16, so the two sets can never collide and a caller can test
 * either independently.
 */
static unsigned int passed;
static unsigned int failed;

/* Record a phase outcome. A phase that already failed is not double-counted as
 * a failure: each failure bit is set once, so "failed" is a set of flags rather
 * than a count of broken lines.
 */
static void phase(const char *name, int ok, unsigned int bit)
{
	unsigned int fbit;

	if (ok) {
		passed |= bit;
		return;
	}
	/* Failure bits start above every pass bit. */
	fbit = bit << 16;
	if (!(failed & fbit)) {
		failed |= fbit;
		printf("PROBE %-22s FAIL\n", name);
	}
}

int main(void)
{
	int fd = -1;
	int rc;

	struct kbase_ioctl_version_check ver = {
		.major = PROBE_VERSION_MAJOR,
		.minor = PROBE_VERSION_MINOR,
	};
	struct kbase_ioctl_set_flags setflags;
	struct kbase_ioctl_get_gpuprops props;
	struct gpu_props_user_data *g;
	union kbase_ioctl_mem_alloc alloc;
	struct kbase_ioctl_mem_free fre;
	union kbase_ioctl_mem_query query;
	void *props_buf = NULL;
	void *mapped = NULL;
	size_t mapped_len = 0;
	__u64 gpu_va = 0;

	printf("PROBE build              kbase-probe, EL0 ioctl exerciser\n");
	printf("PROBE device             %s\n", KBASE_DEV);

	/* --- phase 1: open ------------------------------------------------ */
	fd = open(KBASE_DEV, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		printf("PROBE open                FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("open", 0, 0x01);
		goto out;
	}
	phase("open", 1, 0x01);

	/* --- phase 2: API handshake --------------------------------------- */
	/* Kbase rejects every ioctl other than the handshake itself until a
	 * context exists, so this must come first or nothing else is testable.
	 */
	rc = ioctl(fd, KBASE_IOCTL_VERSION_CHECK, &ver);
	if (rc < 0) {
		printf("PROBE version_check       FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("version_check", 0, 0x02);
		goto out;
	}
	printf("PROBE version_check       negotiated major=%u minor=%u "
	       "(proposed %d.%d)\n",
	       ver.major, ver.minor, PROBE_VERSION_MAJOR, PROBE_VERSION_MINOR);
	phase("version_check", 1, 0x02);

	/* --- phase 3: create the kernel context --------------------------- */
	/* Ordering matters and is not obvious from the header. The handshake
	 * above does NOT create a context on this API version: r54p0 supports
	 * the System Monitor capability, so kbase_api_handshake() skips context
	 * creation on purpose. Until KBASE_IOCTL_SET_FLAGS is issued, every
	 * other ioctl fails with -EPERM because no context exists yet.
	 *
	 * create_flags must be a subset of BASEP_CONTEXT_CREATE_KERNEL_FLAGS.
	 * Zero is a valid subset and means an ordinary context with job
	 * submission enabled.
	 */
	memset(&setflags, 0, sizeof(setflags));
	setflags.create_flags = BASE_CONTEXT_CREATE_FLAG_NONE;
	rc = ioctl(fd, KBASE_IOCTL_SET_FLAGS, &setflags);
	if (rc < 0) {
		printf("PROBE set_flags           FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("set_flags", 0, 0x04);
		goto out;
	}
	phase("set_flags", 1, 0x04);

	/* --- phase 4+5: GPU properties ------------------------------------ */
	/* size == 0 is the documented size query: no data is copied out, the
	 * return value is the number of bytes the full block needs.
	 */
	memset(&props, 0, sizeof(props));
	props.buffer = (__u64)(uintptr_t)0; /* unused when size == 0 */
	props.size = 0;
	props.flags = 0;
	rc = ioctl(fd, KBASE_IOCTL_GET_GPUPROPS, &props);
	if (rc < 0) {
		printf("PROBE gpuprops_size       FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("gpuprops_size", 0, 0x08);
		goto out;
	}
	if (rc == 0) {
		printf("PROBE gpuprops_size       FAIL kernel reported 0 bytes\n");
		phase("gpuprops_size", 0, 0x08);
		goto out;
	}
	printf("PROBE gpuprops_size       %d bytes\n", rc);
	phase("gpuprops_size", 1, 0x08);

	props_buf = calloc(1, (size_t)rc);
	if (!props_buf) {
		printf("PROBE gpuprops_read       FAIL out of memory\n");
		phase("gpuprops_read", 0, 0x10);
		goto out;
	}
	memset(&props, 0, sizeof(props));
	props.buffer = (__u64)(uintptr_t)props_buf;
	props.size = (__u32)rc;
	props.flags = 0;
	rc = ioctl(fd, KBASE_IOCTL_GET_GPUPROPS, &props);
	if (rc < 0) {
		printf("PROBE gpuprops_read       FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("gpuprops_read", 0, 0x10);
		goto out;
	}

	g = (struct gpu_props_user_data *)props_buf;
	printf("PROBE gpuprops product_id=0x%04x version_status=0x%04x "
	       "major=%u minor=%u\n",
	       g->core_props.product_id, g->core_props.version_status,
	       g->core_props.major_revision, g->core_props.minor_revision);
	printf("PROBE gpuprops gpu_freq_khz_max=%u log2_pc_size=%u "
	       "num_exec_engines=%u log2_l2_line_size=%u\n",
	       g->core_props.gpu_freq_khz_max, g->core_props.log2_program_counter_size,
	       g->core_props.num_exec_engines, g->l2_props.log2_line_size);
	printf("PROBE gpuprops raw gpu_id=0x%016llx\n",
	       (unsigned long long)g->raw_props.gpu_id);
	phase("gpuprops_read", 1, 0x10);

	/* --- phase 6: GPU memory allocation ------------------------------- */
	/* One page of GPU VA, zero pages actually backed. commit_pages == 0
	 * means the region grows on demand, which is the documented way to
	 * reserve VA without requiring a working MMU to fault it in yet.
	 *
	 * Do not assume the returned gpu_va is a usable GPU address. Kbase
	 * forces BASE_MEM_SAME_VA for non-compat 64-bit clients, and a
	 * SAME_VA region is handed back as a COOKIE (an index into the
	 * context's pending-region table) which only becomes a real address
	 * once the caller mmaps it. That is why phase 7 below checks the
	 * returned flags instead of assuming.
	 */
	memset(&alloc, 0, sizeof(alloc));
	alloc.in.va_pages = 1;
	alloc.in.commit_pages = 0;
	alloc.in.extension = 0;
	alloc.in.flags = BASE_MEM_PROT_CPU_RD | BASE_MEM_PROT_CPU_WR |
			 BASE_MEM_PROT_GPU_RD | BASE_MEM_PROT_GPU_WR;
	rc = ioctl(fd, KBASE_IOCTL_MEM_ALLOC, &alloc);
	if (rc < 0) {
		printf("PROBE mem_alloc           FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("mem_alloc", 0, 0x20);
		goto out;
	}
	gpu_va = alloc.out.gpu_va;
	printf("PROBE mem_alloc           gpu_va=0x%llx out_flags=0x%llx%s\n",
	       (unsigned long long)gpu_va, (unsigned long long)alloc.out.flags,
	       (alloc.out.flags & BASE_MEM_SAME_VA) ? " (SAME_VA cookie)" : "");
	phase("mem_alloc", 1, 0x20);

	/* --- phase 7: bind the allocation --------------------------------- */
	/* With SAME_VA the mmap IS the GPU mapping: the returned address is
	 * also the CPU address, and the kernel gives the region its real GPU
	 * VA during the mapping. Passing the cookie as the file offset is
	 * what selects the pending region.
	 */
	if (alloc.out.flags & BASE_MEM_SAME_VA) {
		void *p = mmap(NULL, (size_t)sysconf(_SC_PAGESIZE), PROT_READ | PROT_WRITE,
			       MAP_SHARED, fd, (off_t)gpu_va);
		if (p == MAP_FAILED) {
			printf("PROBE mmap                FAIL errno=%d (%s)\n", errno,
			       strerror(errno));
			phase("mmap", 0, 0x40);
			goto out;
		}
		mapped = p;
		mapped_len = (size_t)sysconf(_SC_PAGESIZE);
		/* SAME_VA: the CPU address just returned is the GPU address. */
		gpu_va = (__u64)(uintptr_t)p;
		printf("PROBE mmap                bound cookie 0x%llx -> cpu=gpu=0x%llx\n",
		       (unsigned long long)alloc.out.gpu_va, (unsigned long long)gpu_va);
	}
	phase("mmap", 1, 0x40);

	/* --- phase 8: query the allocation -------------------------------- */
	memset(&query, 0, sizeof(query));
	query.in.gpu_addr = gpu_va;
	query.in.query = KBASE_MEM_QUERY_COMMIT_SIZE;
	rc = ioctl(fd, KBASE_IOCTL_MEM_QUERY, &query);
	if (rc < 0) {
		printf("PROBE mem_query           FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		phase("mem_query", 0, 0x80);
		goto out;
	}
	printf("PROBE mem_query           commit_size=%llu bytes\n",
	       (unsigned long long)query.out.value);
	phase("mem_query", 1, 0x80);

	/* --- phase 9: release it ------------------------------------------ */
	/* SAME_VA memory is released by munmap, not by MEM_FREE: Kbase
	 * rejects MEM_FREE on a SAME_VA region because the mapping, not the
	 * ioctl, owns the lifetime. Follow whichever path applies.
	 */
	if (alloc.out.flags & BASE_MEM_SAME_VA) {
		if (munmap(mapped, mapped_len) != 0) {
			printf("PROBE munmap              FAIL errno=%d (%s)\n", errno,
			       strerror(errno));
			phase("munmap", 0, 0x100);
			goto out;
		}
		mapped = NULL;
		phase("munmap", 1, 0x100);
	} else {
		memset(&fre, 0, sizeof(fre));
		fre.gpu_addr = gpu_va;
		rc = ioctl(fd, KBASE_IOCTL_MEM_FREE, &fre);
		if (rc < 0) {
			printf("PROBE mem_free            FAIL errno=%d (%s)\n", errno,
			       strerror(errno));
			phase("mem_free", 0, 0x100);
			goto out;
		}
		phase("mem_free", 1, 0x100);
	}

out:
	if (mapped)
		munmap(mapped, mapped_len);
	free(props_buf);
	if (fd >= 0)
		close(fd);
	printf("PROBE summary             passed=0x%03x failed=0x%03x\n", passed,
	       failed);
	return (int)(passed | failed);
}
