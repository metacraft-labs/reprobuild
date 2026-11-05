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
 * Then, added by the A9 review round 2 (floor version 3), the writable
 * places a service has, and the two ways to execute written bytes that no
 * mount flag sees:
 *   tmp-exec, vartmp-exec, devshm-exec=<n>   a copy of this binary written
 *                      to /tmp, /var/tmp, /dev/shm and run: 0 when it ran,
 *                      otherwise as exec-outside (13 on a noexec mount); a
 *                      code from 200 is a copy that could not be written;
 *   run-exec, state-exec, cache-exec, logs-exec=<n>   the same in the unit's
 *                      $RUNTIME_DIRECTORY, $STATE_DIRECTORY,
 *                      $CACHE_DIRECTORY, $LOGS_DIRECTORY (-1 when unset);
 *   shm-exec=<n>       0 when code written into a SysV shared-memory segment
 *                      ran through a second, SHM_EXEC attachment (shmat(2));
 *                      otherwise the child's code (1000+/2000+/3000+errno for
 *                      shmget/shmat/the exec attach), or 255 when killed
 *                      (the floor's filter denies the SysV shm calls);
 *   procmem=<n>        0 when a write to /proc/self/mem patched this
 *                      binary's own code and the patch ran (the kernel
 *                      writes through FOLL_FORCE, proc(5)); 1000+errno when
 *                      the open failed (1030: EROFS, a read-only /proc);
 *   exec-mounts=<list> every mount in the namespace without noexec.
 * and then sleeps, so the unit stays active for the switch's confirm step.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/ipc.h>
#include <sys/shm.h>

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


static int copy_exec(const char *self, const char *dst) {
  int in = open(self, O_RDONLY);
  if (in < 0) return 200;
  int out = open(dst, O_WRONLY|O_CREAT|O_TRUNC, 0700);
  if (out < 0) { close(in); return 201; }
  char buf[65536]; ssize_t n;
  while ((n = read(in, buf, sizeof buf)) > 0) if (write(out, buf, (size_t)n) != n) return 202;
  close(in); close(out);
  int r = try_exec(dst, "--child");
  unlink(dst);
  return r;
}
__attribute__((noinline, noipa)) static int answer(void) { return 42; }

/* Run ``f`` in a child: the floor's filter kills a process that makes a
 * denied call, which must not take the probe's report with it. */
static int in_child(int (*f)(void)) {
  pid_t pid = fork();
  if (pid < 0) return 255;
  if (pid == 0) {
    int r = f();
    /* exit codes are a byte: the report keeps the class (1/2/3/4 thousand)
     * and the errno, packed as class*50 + errno when they fit */
    _exit(r == 0 ? 0 : (r >= 1000 ? (r / 1000) * 50 + (r % 1000) % 50 : 254));
  }
  int status = 0;
  if (waitpid(pid, &status, 0) != pid) return 255;
  if (!WIFEXITED(status)) return 255;
  int c = WEXITSTATUS(status);
  if (c == 0 || c == 254) return c;
  return (c / 50) * 1000 + c % 50;
}

static int shm_exec(void) {
#if defined(__x86_64__)
  unsigned char code[] = {0xb8,0x39,0x05,0x00,0x00,0xc3};
#elif defined(__arm__)
  unsigned char code[] = {0x39,0x05,0x00,0xe3, 0x1e,0xff,0x2f,0xe1}; /* movw r0,#1337; bx lr */
#else
  unsigned char code[] = {0};
#endif
  int id = shmget(IPC_PRIVATE, 4096, IPC_CREAT|0700);
  if (id < 0) return 1000 + errno;
  char *w = shmat(id, NULL, 0);
  if (w == (void*)-1) { shmctl(id, IPC_RMID, NULL); return 2000 + errno; }
  memcpy(w, code, sizeof code);
  __builtin___clear_cache(w, w + sizeof code);
  void *x = shmat(id, NULL, SHM_RDONLY|SHM_EXEC);
  shmctl(id, IPC_RMID, NULL);
  if (x == (void*)-1) return 3000 + errno;
  int (*f)(void) = (int(*)(void))x;
  return f() == 1337 ? 0 : 4000;
}
static int procmem_patch(void) {
  int fd = open("/proc/self/mem", O_RDWR);
  if (fd < 0) return 1000 + errno;
#if defined(__x86_64__)
  unsigned char patch[] = {0xb8,0x07,0x00,0x00,0x00,0xc3};
#elif defined(__arm__)
  unsigned char patch[] = {0x07,0x00,0xa0,0xe3, 0x1e,0xff,0x2f,0xe1}; /* mov r0,#7; bx lr */
#else
  unsigned char patch[] = {0};
#endif
  ssize_t n = pwrite(fd, patch, sizeof patch, (off_t)(unsigned long)answer);
  close(fd);
  if (n != (ssize_t)sizeof patch) return 2000 + errno;
  __builtin___clear_cache((char*)answer, (char*)answer + sizeof patch);
  int (*volatile fp)(void) = answer;
  return fp() == 7 ? 0 : 3000 + fp();
}

/* Every mount point in the namespace that is not noexec and that no later
 * mount at the same point covers (a mount stacked over another hides it:
 * the private /tmp over the host's, proc(5) "mountinfo" lists both). */
static void exec_mounts(char *out, size_t cap) {
  FILE *f = fopen("/proc/self/mountinfo", "r");
  out[0] = 0;
  if (!f) { snprintf(out, cap, "unreadable"); return; }
  static char points[1024][256];
  static int execable[1024];
  int n = 0;
  char line[4096];
  while (n < 1024 && fgets(line, sizeof line, f)) {
    char *tok[7]; int k = 0; char *save = NULL;
    for (char *t = strtok_r(line, " ", &save); t && k < 7; t = strtok_r(NULL, " ", &save)) tok[k++] = t;
    if (k < 6) continue;
    snprintf(points[n], sizeof points[n], "%s", tok[4]);
    execable[n] = strstr(tok[5], "noexec") == NULL;
    n++;
  }
  fclose(f);
  for (int i = 0; i < n; i++) {
    if (!execable[i]) continue;
    int covered = 0;
    for (int j = i + 1; j < n; j++)
      if (strcmp(points[i], points[j]) == 0) { covered = 1; break; }
    if (covered) continue;
    if (strlen(out) + strlen(points[i]) + 2 < cap) { strcat(out, points[i]); strcat(out, ","); }
  }
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
  char self[4096]; ssize_t sl = readlink("/proc/self/exe", self, sizeof self - 1);
  if (sl > 0) self[sl] = 0; else strcpy(self, argv[0]);
  int t1 = copy_exec(self, "/tmp/a9x"), t2 = copy_exec(self, "/var/tmp/a9x"),
      t3 = copy_exec(self, "/dev/shm/a9x");
  const char *dirs[4] = {"RUNTIME_DIRECTORY", "STATE_DIRECTORY",
                         "CACHE_DIRECTORY", "LOGS_DIRECTORY"};
  int td[4];
  for (int i = 0; i < 4; i++) {
    const char *d = getenv(dirs[i]);
    char dst[4096];
    if (!d) { td[i] = -1; continue; }
    /* the variable may list several directories, ':' separated */
    snprintf(dst, sizeof dst, "%s", d);
    char *colon = strchr(dst, ':');
    if (colon) *colon = 0;
    strncat(dst, "/a9x", sizeof dst - strlen(dst) - 1);
    td[i] = copy_exec(self, dst);
  }
  int t5 = in_child(shm_exec), t6 = in_child(procmem_patch);
  static char mnts[3000]; exec_mounts(mnts, sizeof mnts);
  printf("a9-probe exec-outside=%d exec-own=%d mprotect-exec=%d "
         "memfd-exec=%d tmp-exec=%d vartmp-exec=%d devshm-exec=%d "
         "run-exec=%d state-exec=%d cache-exec=%d logs-exec=%d "
         "shm-exec=%d procmem=%d exec-mounts=%s\n", outside, own, prot,
         memfd, t1, t2, t3, td[0], td[1], td[2], td[3], t5, t6, mnts);
  fflush(stdout);
  if (argc > 1 && strcmp(argv[1], "--once") == 0) return 0;
  for (;;) pause();
}
