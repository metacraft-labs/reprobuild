/* The C compiler the CodeTracer project-file test puts on PATH as `gcc`
   (and, for the native cases, as `clang`). It reads every translation unit
   and `-include` header itself, so the monitor sees those reads even where
   the real compiler's own reads would be attributed elsewhere, then execs
   the real compiler with the same arguments.

   It is built ONCE by a graph edge (reprobuild.test_fixtures.codetracer_tool_*)
   at a stable path and shared by every case. It therefore names no host path:
   the real compiler is the next `gcc` (Linux) / `clang` (macOS) on PATH AFTER
   this binary's own directory, which is what `findExe` returned when the test
   compiled a private copy per case (the case's PATH is the fixture
   directories followed by the test's own PATH). On macOS the dev-shell clang
   is the real compiler: Apple's signed /usr/bin/gcc shim strips DYLD
   interposition across exec. */
#define _GNU_SOURCE /* memmem on glibc; macOS declares it unconditionally */
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#if defined(__APPLE__)
static const char *real_compiler_name = "clang";
#else
static const char *real_compiler_name = "gcc";
#endif

/* Every compiler STAND-IN among this test's fixtures carries this string:
   each copy of this proxy, whatever name it was linked under (`bin/gcc`,
   `clang-bin/clang`), and the version-answering `clang-stub/clang` script.
   The proxy copies are not byte-identical (macOS ad-hoc signs each with its
   own file name), so the marker is how the proxy tells a stand-in from a real
   compiler on PATH and refuses to forward to one. */
static const char stand_in_marker[] =
  "reprobuild-codetracer-compiler-stand-in-v1";

/* Set in the environment of the compiler this proxy execs. Finding it on
   entry means a "real compiler" resolved back to a proxy, which must fail at
   once instead of re-executing forever (see `main`). */
static const char *reentry_guard = "REPROBUILD_CODETRACER_GCC_PROXY_ACTIVE";

static void read_for_monitor(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return;
  char buffer[4096];
  while (read(fd, buffer, sizeof(buffer)) > 0) {}
  close(fd);
}

static int own_directory(char *out) {
  char exe[PATH_MAX];
#if defined(__APPLE__)
  char raw[PATH_MAX];
  uint32_t size = sizeof(raw);
  if (_NSGetExecutablePath(raw, &size) != 0) return -1;
  if (realpath(raw, exe) == NULL) return -1;
#else
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return -1;
  exe[n] = '\0';
#endif
  char *slash = strrchr(exe, '/');
  if (slash == NULL) return -1;
  *slash = '\0';
  strcpy(out, exe);
  return 0;
}

static int is_executable_file(const char *path) {
  struct stat info;
  return stat(path, &info) == 0 && S_ISREG(info.st_mode) &&
         access(path, X_OK) == 0;
}

/* Whether `path` is one of the fixture stand-ins (it carries
   `stand_in_marker`). */
static int is_stand_in(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 0;
  struct stat info;
  int found = 0;
  if (fstat(fd, &info) == 0 && info.st_size > 0) {
    void *bytes = mmap(NULL, (size_t)info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (bytes != MAP_FAILED) {
      found = memmem(bytes, (size_t)info.st_size, stand_in_marker,
                     sizeof(stand_in_marker) - 1) != NULL;
      munmap(bytes, (size_t)info.st_size);
    }
  }
  close(fd);
  return found;
}

/* The first `real_compiler_name` on PATH after `self_dir` that is not a
   fixture stand-in; when `self_dir` is not on PATH at all (invoked by
   absolute path), the first such one outside it.

   "After `self_dir`" alone is not enough. The case puts the directory that
   answers `clang` -- `clang-bin` (the clang proxy) or `clang-stub` -- in
   front of this one. The engine then puts an action's own tool directory
   first and drops its later duplicate, so a `gcc` edge runs with
   `bin:clang-bin:...` or `bin:clang-stub:...`. The first `clang` after this
   directory is then a stand-in. The stub exits 0 without writing an object,
   so the compile "succeeded" and left no `build/c/*.o`. The clang proxy, in
   turn, no longer finds its own directory on the reset PATH below, so it falls
   back to `/usr/bin/clang`. The SIP sandbox maps that back to the first
   non-SIP `clang` on the action's PATH, which is the clang proxy again. Each
   round added one `-fno-temp-file` until `execv` failed with E2BIG, after an
   hour of re-execution. */
static int find_real_compiler(const char *self_dir, char *out) {
  const char *path = getenv("PATH");
  if (path == NULL) return -1;
  for (int pass = 0; pass < 2; pass++) {
    char *copy = strdup(path);
    if (copy == NULL) return -1;
    int after_self = pass == 1;
    for (char *dir = strtok(copy, ":"); dir != NULL; dir = strtok(NULL, ":")) {
      char resolved[PATH_MAX];
      if (dir[0] == '\0' || realpath(dir, resolved) == NULL) continue;
      if (strcmp(resolved, self_dir) == 0) {
        after_self = 1;
        continue;
      }
      if (!after_self) continue;
      char candidate[PATH_MAX];
      if (snprintf(candidate, sizeof(candidate), "%s/%s", dir,
                   real_compiler_name) >= (int)sizeof(candidate)) continue;
      if (is_executable_file(candidate) && !is_stand_in(candidate)) {
        strcpy(out, candidate);
        free(copy);
        return 0;
      }
    }
    free(copy);
  }
  return -1;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("gcc proxy 1.0.0");
    return 0;
  }
  if (getenv(reentry_guard) != NULL) {
    fprintf(stderr,
            "gcc proxy: re-entered from the compiler it forwarded to; a "
            "`%s` on PATH (or the SIP sandbox's stand-in for /usr/bin/%s) "
            "resolves back to a proxy\n",
            real_compiler_name, real_compiler_name);
    return 127;
  }
  char self_dir[PATH_MAX];
  char real_compiler[PATH_MAX];
  if (own_directory(self_dir) != 0 ||
      find_real_compiler(self_dir, real_compiler) != 0) {
    fprintf(stderr, "gcc proxy: no %s on PATH after its own directory\n",
            real_compiler_name);
    return 127;
  }
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-include") == 0 && i + 1 < argc) {
      read_for_monitor(argv[i + 1]);
      i++;
    } else if (argv[i][0] != '-' && strstr(argv[i], ".c") != NULL) {
      read_for_monitor(argv[i]);
    }
  }
  char **next_argv = calloc((size_t)argc + 2, sizeof(char *));
  if (next_argv == NULL) return 126;
  int next = 0;
  next_argv[next++] = real_compiler;
#if defined(__APPLE__)
  /* The real compiler here is clang, which writes a `-c` object through a
     temporary whose name libLLVM draws with arc4random. The monitor reports
     that draw (as it does on Linux for a clang), and a gcc edge carries no
     entropy blessing, so the object's cache publication would be withheld
     and the cases that assert the C objects are cache hits would fail for a
     reason unrelated to what they test. `-fno-temp-file` writes the object
     directly; it is what reprobuild's own profile compile passes clang
     (`clangNoTempFileFlag`). Only on a compile, where the flag applies. */
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-c") == 0) {
      next_argv[next++] = "-fno-temp-file";
      break;
    }
  }
#endif
  for (int i = 1; i < argc; i++) next_argv[next++] = argv[i];

#if defined(__APPLE__)
  /* /usr/bin/gcc honours DEVELOPER_DIR and dispatches via xcrun, whose
     SDK bin lacks gcc and falls back to PATH — re-finding this proxy
     and looping until kern.maxprocperuid is exhausted. Strip the SDK
     pointers and proxy directory while retaining monitor injection. */
  unsetenv("DEVELOPER_DIR");
  unsetenv("SDKROOT");
  setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
#endif
  setenv(reentry_guard, "1", 1);
  execv(real_compiler, next_argv);
  perror("execv real gcc");
  return 127;
}
