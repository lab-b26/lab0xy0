/*
 * kbase-negargs -- negative-argument battery for the LEBUS harness.
 *
 * Companion to kbase-probe (which proves the *happy path* works). This program
 * proves the *validation path* works: it aims a dozen deliberately invalid
 * invocations at /dev/mali0 and requires that the driver reject each one with a
 * userspace-visible error instead of a kernel oops, a WARN, or success.
 *
 * One line per case:  NEGARGS <name> rc=<n> verdict=<REJECTED|ACCEPTED|BAD>
 * Final summary:      NEGARGS summary ran=N rejected=R expected-ok=K unexpected=U
 *
 * The last field is the only one verify-boot.sh's assertion reads: U must be 0.
 * "unexpected" covers three failure shapes that are equally bad for the kernel:
 *   (a) a call that was supposed to fail returned success,
 *   (b) a call that was supposed to succeed (a control pair) failed,
 *   (c) the kernel printed something fatal during the run -- detected by
 *       verify-boot.sh's serial-scan assertion, not here.
 *
 * Why this exists instead of fuzzing: coverage-guided fuzzing of Kbase is
 * blocked upstream of this (F-2 -- KCOV covers vmlinux, not the module), and
 * the MALI_NO_MALI backend cannot exercise GPU-fault-triggered paths at all
 * (F-37: the fault-triggered CVE classes cannot trigger on a dummy backend).
 * What CAN be tested here, today, without coverage, is the argument-validation
 * envelope of every ioctl class the source audit marked as
 * a historic CVE seam (aliasing, grow/commit, tiler heap, CQS/kcpu fences,
 * flags change). If any of these rejections regresses, this battery catches it
 * exactly as loudly as the happy-path probe catches a broken handshake.
 *
 * Scope: EL0-only (research/program-scope.md SS8.2), default module parameters
 * (SS8.4). Nothing here claims exploitation.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <uapi/gpu/arm/midgard/mali_base_kernel.h>
#include <uapi/gpu/arm/midgard/mali_kbase_ioctl.h>
#include <uapi/gpu/arm/midgard/mali_kbase_mem_flags.h>
#include <uapi/gpu/arm/midgard/csf/mali_kbase_csf_ioctl.h>

static unsigned ran, rejected, expected_ok, unexpected;

static int errno_from(int rc) { return rc == -1 ? errno : -rc; }

	int err;

/* t -- test that must FAIL (rc != 0). verdict x=succeeded accidentally. */
static void must_reject(const char *name, int rc)
{
	ran++;
	if (rc == 0) {
		unexpected++;
		printf("NEGARGS %-28s rc=0      verdict=BAD-ACCEPTED\n", name);
	} else {
		rejected++;
		printf("NEGARGS %-28s rc=%-4d verdict=REJECTED\n", name, -errno_from(rc));
	}
	(void)rc;
}

/* t -- test that must SUCCEED (control call). verdict x=failed unexpectedly. */
static void must_accept(const char *name, int rc)
{
	ran++;
	if (rc != 0) {
		unexpected++;
		printf("NEGARGS %-28s rc=%-4d verdict=BAD-REJECTED\n", name, -errno_from(rc));
	} else {
		expected_ok++;
		printf("NEGARGS %-28s rc=0      verdict=ACCEPTED\n", name);
	}
}

int main(void)
{
	int fd = open("/dev/mali0", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("NEGARGS FATAL: open /dev/mali0");
		return 168;
	}

	/* Lectio 1: version handshake then SET_FLAGS -- F-19: every other ioctl
	 * is EPERM before this. Honor it.
	 */
	{
		struct kbase_ioctl_version_check ver = { 0 };
		ver.major = BASE_UK_VERSION_MAJOR;
		ver.minor = BASE_UK_VERSION_MINOR;
		if (ioctl(fd, KBASE_IOCTL_VERSION_CHECK, &ver) != 0) {
			perror("NEGARGS FATAL: VERSION_CHECK");
			close(fd);
			return 169;
		}
	}
	{
		struct kbase_ioctl_set_flags set = { 0 };
		set.create_flags = BASE_CONTEXT_CREATE_FLAG_NONE;
		if (ioctl(fd, KBASE_IOCTL_SET_FLAGS, &set) != 0) {
			perror("NEGARGS FATAL: SET_FLAGS");
			close(fd);
			return 170;
		}
		printf("NEGARGS context created (SET_FLAGS handshake)\n");
	}

	/* ---- MEM_ALLOC family -------------------------------------------------- */
	{
		/* grossly oversized VA request */
		union kbase_ioctl_mem_alloc a = { 0 };
		a.in.va_pages = 1ULL << 40;
		a.in.commit_pages = 1ULL << 40;
		a.in.flags = BASE_MEM_PROT_CPU_RD | BASE_MEM_PROT_CPU_WR |
			     BASE_MEM_PROT_GPU_RD | BASE_MEM_PROT_GPU_WR;
		must_reject("MEM_ALLOC va_pages=2^40",
			    ioctl(fd, KBASE_IOCTL_MEM_ALLOC, &a));
	}
	{
		/* padding-present MEM_ALLOC_EX (padding check must fire) */
		union kbase_ioctl_mem_alloc_ex a = { 0 };
		a.in.va_pages = 1;
		a.in.commit_pages = 1;
		a.in.flags = BASE_MEM_PROT_CPU_RD | BASE_MEM_PROT_CPU_WR |
			     BASE_MEM_PROT_GPU_RD | BASE_MEM_PROT_GPU_WR;
		a.in.extra[0] = 0xdeadbeef;
		must_reject("MEM_ALLOC_EX padding!=0",
			    ioctl(fd, KBASE_IOCTL_MEM_ALLOC_EX, &a));
	}
	{
		/* zero caps means "set no flags" -> rejected by flag checker */
		union kbase_ioctl_mem_alloc a = { 0 };
		a.in.va_pages = 4;
		a.in.commit_pages = 4;
		must_reject("MEM_ALLOC zero flags", ioctl(fd, KBASE_IOCTL_MEM_ALLOC, &a));
	}
	{
		struct kbase_ioctl_mem_free f = { .gpu_addr = 0 };
		must_reject("MEM_FREE gpu_addr=0", ioctl(fd, KBASE_IOCTL_MEM_FREE, &f));
	}
	{
		struct kbase_ioctl_mem_free f = { .gpu_addr = 0x1234 }; /* unaligned */
		must_reject("MEM_FREE unaligned va", ioctl(fd, KBASE_IOCTL_MEM_FREE, &f));
	}
	{
		/* query with an invalid op must not succeed */
		union kbase_ioctl_mem_query q = { 0 };
		q.in.gpu_addr = 0x123456000; /* aligned, but nothing is mapped there */
		q.in.query = KBASE_MEM_QUERY_COMMIT_SIZE;
		must_reject("MEM_QUERY unmapped va", ioctl(fd, KBASE_IOCTL_MEM_QUERY, &q));
	}
	{
		/* flags change on an unmapped VA with a prot-update mask must fail */
		struct kbase_ioctl_mem_flags_change fc = { 0 };
		fc.gpu_va = 0x123456000;
		fc.flags = BASE_MEM_PROT_GPU_WR;
		fc.mask = BASE_MEM_PROT_GPU_WR;
		must_reject("MEM_FLAGS_CHANGE ghost va",
			    ioctl(fd, KBASE_IOCTL_MEM_FLAGS_CHANGE, &fc));
	}
	{
		/* aliasing stride 0: rejected before any lookup */
		union kbase_ioctl_mem_alias ual = { 0 };
		ual.in.stride = 0;
		ual.in.nents = 1;
		ual.in.flags = BASE_MEM_PROT_GPU_RD;
		ual.in.aliasing_info = 0;
		must_reject("MEM_ALIAS stride=0", ioctl(fd, KBASE_IOCTL_MEM_ALIAS, &ual));
	}
	{
		/* JIT commit on a VA with no region */
		struct kbase_ioctl_mem_commit c = { 0 };
		c.gpu_addr = 0x123456000;
		c.pages = 1;
		must_reject("MEM_COMMIT unmapped va",
			    ioctl(fd, KBASE_IOCTL_MEM_COMMIT, &c));
	}

	/* ---- CSF family (the CSF pipeline is live even on the dummy model) ----- */
	{
		/* chunk_size 0 must die before any allocation */
		union kbase_ioctl_cs_tiler_heap_init ti = { 0 };
		ti.in.group_id = 0;
		ti.in.chunk_size = 0;
		ti.in.initial_chunks = 1;
		ti.in.max_chunks = 8;
		ti.in.target_in_flight = 1;
		must_reject("TILER_HEAP_INIT chunk_size=0",
			    ioctl(fd, KBASE_IOCTL_CS_TILER_HEAP_INIT, &ti));
	}
	{
		/* initial > max must die before any allocation */
		union kbase_ioctl_cs_tiler_heap_init ti = { 0 };
		ti.in.group_id = 0;
		ti.in.chunk_size = 1 << 21;
		ti.in.initial_chunks = 9;
		ti.in.max_chunks = 8;
		ti.in.target_in_flight = 1;
		must_reject("TILER_HEAP_INIT initial>max",
			    ioctl(fd, KBASE_IOCTL_CS_TILER_HEAP_INIT, &ti));
	}
	{
		/* out-of-range memory group id must die before JIT group mis-set.
		 * group_id is u8; 0xffff truncates to 255, still >= 16 (NR_GROUPS). */
		union kbase_ioctl_cs_tiler_heap_init ti = { 0 };
		ti.in.group_id = 250;
		ti.in.chunk_size = 1 << 21;
		ti.in.initial_chunks = 1;
		ti.in.max_chunks = 1;
		ti.in.target_in_flight = 1;
		must_reject("TILER_HEAP_INIT group_id OOB",
			    ioctl(fd, KBASE_IOCTL_CS_TILER_HEAP_INIT, &ti));
	}
	{
		/* never-created kcpu queue id: in-bounds id, NULL slot */
		struct kbase_ioctl_kcpu_queue_enqueue eq = { 0 };
		eq.id = 255;
		eq.nr_commands = 1;
		must_reject("KCPU_ENQUEUE id=255 unborn queue",
			    ioctl(fd, KBASE_IOCTL_KCPU_QUEUE_ENQUEUE, &eq));
	}
	{
		/* nr_commands != 1 must be rejected before touching the queue */
		struct kbase_ioctl_kcpu_queue_new nq = { 0 };
		int rc = ioctl(fd, KBASE_IOCTL_KCPU_QUEUE_CREATE, &nq);
		must_accept("KCPU_QUEUE_CREATE control", rc);
		if (rc == 0) {
			struct kbase_ioctl_kcpu_queue_enqueue eq = { 0 };
			eq.id = nq.id;
			eq.nr_commands = 2;
			must_reject("KCPU_ENQUEUE nr_commands=2",
				    ioctl(fd, KBASE_IOCTL_KCPU_QUEUE_ENQUEUE, &eq));
			{
				struct kbase_ioctl_kcpu_queue_delete dq = { 0 };
				dq.id = nq.id;
				must_accept("KCPU_QUEUE_DELETE control",
					    ioctl(fd, KBASE_IOCTL_KCPU_QUEUE_DELETE, &dq));
			}
		}
	}
	{
		/* queue group create with an out-of-range priority */
		union kbase_ioctl_cs_queue_group_create gc = { 0 };
		gc.in.tiler_mask = 0;
		gc.in.fragment_mask = 0;
		gc.in.compute_mask = 0;
		gc.in.cs_min = 0;
		gc.in.priority = 0xff;
		must_reject("CS_QUEUE_GROUP_CREATE prio=0xff",
			    ioctl(fd, KBASE_IOCTL_CS_QUEUE_GROUP_CREATE, &gc));
	}
	{
		/* F-19 contract: before SET_FLAGS, a second fd's non-handshake ioctl
		 * must fail with EPERM -- the context does not exist yet. If this
		 * ever returns 0 or oopses, EVERY later gate in the battery is
		 * reachable from an uninitialised context, which is the real
		 * security property under test here.
		 */
		int fd2 = open("/dev/mali0", O_RDWR | O_CLOEXEC);
		if (fd2 < 0) {
			printf("NEGARGS FATAL: second open failed\n");
			unexpected++;
		} else {
			int rc = ioctl(fd2, KBASE_IOCTL_MEM_ALLOC, NULL);
			ran++;
			if (rc == 0 || errno != EPERM) {
				unexpected++;
				printf("NEGARGS %-28s rc=%-4d verdict=BAD-%.16s\n",
				       "pre-SET_FLAGS MEM_ALLOC", -errno_from(rc),
				       rc == 0 ? "ACCEPTED" : "NOT-EPERM");
			} else {
				rejected++;
				printf("NEGARGS %-28s rc=%-4d verdict=REJECTED\n",
				       "pre-SET_FLAGS MEM_ALLOC", -errno);
			}
			close(fd2);
		}
	}
	{
		/* unknown ioctl number must give ENOIOCTLCMD, not a crash */
		must_reject("unknown nr 0x7f", ioctl(fd, _IOC(_IOC_NONE, 'K', 0x7f, 0), 0));
	}

	printf("NEGARGS summary ran=%u rejected=%u expected-ok=%u unexpected=%u\n",
	       ran, rejected, expected_ok, unexpected);
	close(fd);
	return unexpected ? 1 : 0;
}
