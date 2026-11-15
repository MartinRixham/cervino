/*
 * Spotify Soloist is built for glibc. On musl gcompat runs it, but for a
 * few glibc functions that neither musl nor gcompat has: these. spotatui
 * preloads this library into the Soloist it starts (soloist-musl.patch).
 */
#define _GNU_SOURCE
/* Not musl's checked versions of what this passes on to. */
#undef _FORTIFY_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <wchar.h>

/*
 * glibc 2.38's names for the C23 versions of these, which also read
 * binary numbers ("0b101"): musl's read the rest alike.
 */
long __isoc23_strtol(const char *s, char **end, int base)
{
	return strtol(s, end, base);
}

long long __isoc23_strtoll(const char *s, char **end, int base)
{
	return strtoll(s, end, base);
}

unsigned long __isoc23_strtoul(const char *s, char **end, int base)
{
	return strtoul(s, end, base);
}

unsigned long long __isoc23_strtoull(const char *s, char **end, int base)
{
	return strtoull(s, end, base);
}

/* musl has one locale for numbers: the locale argument makes no difference. */
long long __isoc23_strtoll_l(const char *s, char **end, int base, locale_t l)
{
	(void)l;
	return strtoll(s, end, base);
}

unsigned long long __isoc23_strtoull_l(const char *s, char **end, int base,
	locale_t l)
{
	(void)l;
	return strtoull(s, end, base);
}

long __isoc23_wcstol(const wchar_t *s, wchar_t **end, int base)
{
	return wcstol(s, end, base);
}

long long __isoc23_wcstoll(const wchar_t *s, wchar_t **end, int base)
{
	return wcstoll(s, end, base);
}

unsigned long __isoc23_wcstoul(const wchar_t *s, wchar_t **end, int base)
{
	return wcstoul(s, end, base);
}

unsigned long long __isoc23_wcstoull(const wchar_t *s, wchar_t **end, int base)
{
	return wcstoull(s, end, base);
}

int __isoc23_vsscanf(const char *s, const char *format, va_list ap)
{
	return vsscanf(s, format, ap);
}

int __isoc23_sscanf(const char *s, const char *format, ...)
{
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsscanf(s, format, ap);
	va_end(ap);
	return n;
}

int __isoc23_fscanf(FILE *f, const char *format, ...)
{
	va_list ap;
	int n;

	va_start(ap, format);
	n = vfscanf(f, format, ap);
	va_end(ap);
	return n;
}

/* The checked (_FORTIFY_SOURCE) versions, without their checks. */
size_t __mbsrtowcs_chk(wchar_t *dst, const char **src, size_t len,
	mbstate_t *state, size_t dstlen)
{
	(void)dstlen;
	return mbsrtowcs(dst, src, len, state);
}

int __openat_2(int fd, const char *path, int flags)
{
	return openat(fd, path, flags);
}

/* Files are always large on a 64-bit system: fcntl64 is fcntl. */
int fcntl64(int fd, int cmd, ...)
{
	va_list ap;
	void *arg;

	va_start(ap, cmd);
	arg = va_arg(ap, void *);
	va_end(ap);
	return fcntl(fd, cmd, arg);
}

/*
 * glibc 2.30's wait until a time on a clock of the caller's choice. musl
 * waits on the clock the condition variable was made with, the realtime
 * one unless its attributes said otherwise: wait for as long on that.
 */
int pthread_cond_clockwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
	clockid_t clock, const struct timespec *abstime)
{
	struct timespec now, then;

	if (clock == CLOCK_REALTIME)
		return pthread_cond_timedwait(cond, mutex, abstime);
	if (clock_gettime(clock, &now) || clock_gettime(CLOCK_REALTIME, &then))
		return EINVAL;
	then.tv_sec += abstime->tv_sec - now.tv_sec;
	then.tv_nsec += abstime->tv_nsec - now.tv_nsec;
	if (then.tv_nsec >= 1000000000L) {
		then.tv_sec++;
		then.tv_nsec -= 1000000000L;
	} else if (then.tv_nsec < 0) {
		then.tv_sec--;
		then.tv_nsec += 1000000000L;
	}
	return pthread_cond_timedwait(cond, mutex, &then);
}
