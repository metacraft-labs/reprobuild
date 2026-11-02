/*
 * The exec-confinement probe of gate e2e_addon_service_cannot_exec_outside_closure
 * (ReproOS add-on mode, milestone A9). Built statically by the gate, published
 * as a store prefix, and run as a service under the add-on's serviceFloor.
 *
 * It reports, on one line of standard output:
 *   exec-outside=<n>   0 when execve("/usr/bin/id") ran id to a clean exit;
 *                      otherwise the errno execve failed with (EACCES = 13
 *                      on a noexec mount, execve(2)), or 255 for any other
 *                      outcome;
 *   exec-own=<n>       the same for execve of this binary itself (argv[0]),
 *                      which lies inside the unit's closure;
 *   mprotect-exec=<n>  0 when mprotect(PROT_READ|PROT_EXEC) succeeded on an
 *                      anonymous mapping created writable, otherwise its
 *                      errno (systemd's MemoryDenyWriteExecute=, systemd.exec(5));
 *   memfd-exec=<n>     0 when a copy of this binary in a memfd ran
 *                      (memfd_create(2), then execveat(2) with AT_EMPTY_PATH:
 *                      code on no mount, which ExecPaths= cannot see);
 *                      otherwise the child's errno, or 255 when it was
 *                      killed (the floor's filter denies memfd_create).
 * and then sleeps, so the unit stays active for the switch's confirm step.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static int try_exec(const char *path, const char *arg) {
  pid_t pid = fork();
  if (pid < 0) return 255;
  if (pid == 0) {
    char *const argv[] = {(char *)path, (char *)arg, NULL};
    execv(path, argv);
    _exit(errno & 0x7f);
  }
  int status = 0;
  if (waitpid(pid, &status, 0) != pid) return 255;
  if (!WIFEXITED(status)) return 255;
  return WEXITSTATUS(status);
}

static int try_memfd_exec(void) {
  pid_t pid = fork();
  if (pid < 0) return 255;
  if (pid == 0) {
    int mfd = (int)syscall(SYS_memfd_create, "a9-probe", 0);
    if (mfd < 0) _exit(errno & 0x7f);
    int self = open("/proc/self/exe", O_RDONLY);
    if (self < 0) _exit(errno & 0x7f);
    char buf[65536];
    ssize_t n;
    while ((n = read(self, buf, sizeof buf)) > 0) {
      if (write(mfd, buf, (size_t)n) != n) _exit(errno & 0x7f);
    }
    char *const args[] = {"a9-probe", "--child", NULL};
    char *const envp[] = {NULL};
    syscall(SYS_execveat, mfd, "", args, envp, AT_EMPTY_PATH);
    _exit(errno & 0x7f);
  }
  int status = 0;
  if (waitpid(pid, &status, 0) != pid) return 255;
  if (!WIFEXITED(status)) return 255;
  return WEXITSTATUS(status);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--child") == 0) return 0;
  int outside = try_exec("/usr/bin/id", "-u");
  int own = try_exec(argv[0], "--child");
  int prot = 0;
  void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (m == MAP_FAILED) {
    prot = 255;
  } else if (mprotect(m, 4096, PROT_READ | PROT_EXEC) != 0) {
    prot = errno;
  }
  int memfd = try_memfd_exec();
  printf("a9-probe exec-outside=%d exec-own=%d mprotect-exec=%d "
         "memfd-exec=%d\n", outside, own, prot, memfd);
  fflush(stdout);
  if (argc > 1 && strcmp(argv[1], "--once") == 0) return 0;
  for (;;) pause();
}
