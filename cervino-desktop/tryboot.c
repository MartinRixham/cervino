/*
 * Restarts a Raspberry Pi with the tryboot flag, so that its firmware starts
 * from the boot partition autoboot.txt names for it, which holds the version
 * of an atomic install that is on trial (see /usr/libexec/cervino/boot-trial).
 *
 * The kernel's firmware driver sets the flag only for a restart with the
 * argument "0 tryboot" (reboot(2)'s LINUX_REBOOT_CMD_RESTART2), and clears it
 * on any other, which is all busybox's init and reboot can do.
 *
 * Built for aarch64 by clang in a container of the build host's
 * architecture, which has no aarch64 C library: so no libc, only system
 * calls, and _start in place of main.
 */

#define SYS_write 64
#define SYS_exit 93
#define SYS_reboot 142

#define LINUX_REBOOT_MAGIC1 0xfee1dead
#define LINUX_REBOOT_MAGIC2 0x28121969
#define LINUX_REBOOT_CMD_RESTART2 0xa1b2c3d4

static long syscall4(long n, long a, long b, long c, long d)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;

	__asm__ volatile ("svc #0"
		: "+r"(x0)
		: "r"(x8), "r"(x1), "r"(x2), "r"(x3)
		: "memory");
	return x0;
}

__attribute__((noreturn)) void _start(void)
{
	static const char failed[] = "tryboot: could not restart\n";

	syscall4(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, (long)"0 tryboot");
	syscall4(SYS_write, 2, (long)failed, sizeof(failed) - 1, 0);
	syscall4(SYS_exit, 1, 0, 0, 0);
	for (;;)
		;
}
