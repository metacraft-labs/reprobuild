/*
 * The negative control for clock_under_allocator_lock.c: a preloaded library
 * whose clock_gettime allocates through the host's allocator, which is what
 * the monitor shim did when it was built without its private heap. Preloaded
 * into that program, it must be caught re-entering the allocator. If it is
 * not, the program cannot tell a shim that keeps out of the host allocator
 * from one that does not, and its passing run proves nothing.
 *
 * The clock itself is read with the raw system call, so the control depends
 * on nothing but the one allocation it exists to make.
 */
#define _GNU_SOURCE
#include <stdlib.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

/* Published through a volatile object: a compiler may delete a malloc/free
 * pair whose memory is never observed, and then the control allocates
 * nothing (measured: gcc 15 did exactly that to an unpublished pair). */
void *volatile allocating_clock_hook_last;

int clock_gettime(clockid_t clock, struct timespec *tp) {
  allocating_clock_hook_last = malloc(16);
  free(allocating_clock_hook_last);
  return (int)syscall(SYS_clock_gettime, clock, tp);
}
