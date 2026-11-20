/*
 * A multi-threaded program that replaces the C allocator and reads the clock
 * while it holds its own allocator lock.
 *
 * That is what jemalloc does: `arena_new` initialises the arena's decay state
 * with `clock_gettime` while `arenas_lock` is held, and a thread's first
 * allocation is what creates its arena. rustc links jemalloc statically, so a
 * monitor shim preloaded into rustc that allocates from inside its
 * `clock_gettime` hook asks jemalloc for memory while jemalloc is half way
 * through the call that hook interrupted. jemalloc's lock is not recursive:
 * rustc hung there with every thread in `futex_wait`, and where jemalloc's
 * state was further along it crashed instead.
 *
 * A preloaded library that allocates through the host's allocator inherits
 * every such constraint of every allocator it is ever preloaded beside; the
 * only safe allocator for it is its own. This program makes the hazard
 * deterministic instead of a race: EVERY allocation reads the clock under the
 * lock, from several threads at once, and a re-entry is reported and turned
 * into exit status 3 rather than left to deadlock. The test that runs it
 * still bounds it with a timeout, for a hazard that takes some other form.
 *
 * glibc documents replacing the allocator by defining these functions in the
 * program: https://www.gnu.org/software/libc/manual/html_node/Replacing-malloc.html
 * The allocator is a bump allocator over a static arena. It never returns
 * memory, which a program this short does not need.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define ARENA_BYTES (64u * 1024u * 1024u)
#define ALIGNMENT 16u
#define THREADS 8
#define ALLOCATIONS_PER_THREAD 256

/* Exit status of a run in which the clock read inside the allocator lock
 * re-entered the allocator. Distinct from 1 (any other failure) so the test
 * can name the defect. */
#define EXIT_REENTERED 3

static unsigned char arena[ARENA_BYTES] __attribute__((aligned(ALIGNMENT)));
static size_t arena_used;
/* Allocations served, counted under the lock: main requires at least the
 * workers' own, so a run cannot pass without exercising the allocator. */
static size_t allocations_served;
static pthread_mutex_t arena_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread int inside_allocator;

typedef struct {
  size_t size;
  size_t padding;
} block_header;

static void write_stderr(const char *text) {
  size_t len = strlen(text);
  while (len > 0) {
    ssize_t n = write(2, text, len);
    if (n <= 0) {
      if (n < 0 && errno == EINTR) continue;
      return;
    }
    text += n;
    len -= (size_t)n;
  }
}

static void *allocate(size_t size, size_t alignment) {
  if (inside_allocator) {
    /* The lock below is not recursive. Taking it again would hang this
     * thread forever, which is exactly what rustc did. */
    write_stderr("clock_under_allocator_lock: the allocator was re-entered "
                 "while it held its lock, from inside clock_gettime\n");
    _exit(EXIT_REENTERED);
  }
  if (alignment < ALIGNMENT) alignment = ALIGNMENT;
  if (size > ARENA_BYTES) {
    errno = ENOMEM;
    return NULL;
  }
  inside_allocator = 1;
  pthread_mutex_lock(&arena_lock);
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  uintptr_t base = (uintptr_t)arena + arena_used + sizeof(block_header);
  uintptr_t start = (base + alignment - 1) & ~(uintptr_t)(alignment - 1);
  size_t end = (size_t)(start - (uintptr_t)arena) + size;
  void *result = NULL;
  if (end <= ARENA_BYTES) {
    ((block_header *)start)[-1].size = size;
    arena_used = end;
    allocations_served++;
    result = (void *)start;
  }
  pthread_mutex_unlock(&arena_lock);
  inside_allocator = 0;
  if (result == NULL) errno = ENOMEM;
  return result;
}

static size_t block_size(void *ptr) {
  return ((block_header *)ptr)[-1].size;
}

void *malloc(size_t size) { return allocate(size, ALIGNMENT); }

void free(void *ptr) { (void)ptr; }

void *calloc(size_t count, size_t size) {
  if (size != 0 && count > SIZE_MAX / size) {
    errno = ENOMEM;
    return NULL;
  }
  /* The arena is static and never reused, so its memory is already zero. */
  return allocate(count * size, ALIGNMENT);
}

void *realloc(void *ptr, size_t size) {
  if (ptr == NULL) return allocate(size, ALIGNMENT);
  void *moved = allocate(size, ALIGNMENT);
  if (moved == NULL) return NULL;
  size_t old = block_size(ptr);
  memcpy(moved, ptr, old < size ? old : size);
  return moved;
}

void *memalign(size_t alignment, size_t size) {
  return allocate(size, alignment);
}

void *aligned_alloc(size_t alignment, size_t size) {
  return allocate(size, alignment);
}

int posix_memalign(void **out, size_t alignment, size_t size) {
  void *ptr = allocate(size, alignment);
  if (ptr == NULL) return ENOMEM;
  *out = ptr;
  return 0;
}

void *valloc(size_t size) { return allocate(size, 4096); }

void *pvalloc(size_t size) {
  return allocate((size + 4095) & ~(size_t)4095, 4096);
}

size_t malloc_usable_size(void *ptr) { return ptr ? block_size(ptr) : 0; }

/* Each allocation is published through a volatile object: a compiler may
 * delete a malloc/free pair whose memory is never observed, and the workers
 * would then never enter the allocator at all. */
static char *volatile last_allocation;

static void *worker(void *arg) {
  (void)arg;
  for (int i = 0; i < ALLOCATIONS_PER_THREAD; i++) {
    char *p = malloc(32 + (size_t)i);
    if (p == NULL) return (void *)1;
    p[0] = (char)i;
    last_allocation = p;
    free(p);
  }
  return NULL;
}

int main(void) {
  pthread_t threads[THREADS];
  for (int i = 0; i < THREADS; i++) {
    if (pthread_create(&threads[i], NULL, worker, NULL) != 0) return 1;
  }
  int failed = 0;
  for (int i = 0; i < THREADS; i++) {
    void *status = NULL;
    if (pthread_join(threads[i], &status) != 0 || status != NULL) failed = 1;
  }
  if (failed) return 1;
  pthread_mutex_lock(&arena_lock);
  size_t served = allocations_served;
  pthread_mutex_unlock(&arena_lock);
  if (served < (size_t)THREADS * ALLOCATIONS_PER_THREAD) {
    write_stderr("clock_under_allocator_lock: the workers' allocations did "
                 "not reach the replacement allocator\n");
    return 1;
  }
  write_stderr("clock_under_allocator_lock: ok\n");
  return 0;
}
