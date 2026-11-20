/*
 * The behavioural probe of the add-on units' confinement (ReproOS Add-On
 * Mode spec §10.1, CONF-4; threat model G55). Test-only: built by the VM
 * gate t_e2e_addon_confinement_settings_each_hold with the static
 * toolchain, copied into a guest, and run as the command of a unit that
 * carries an add-on unit's own confinement lines. No add-on unit ever
 * names it (t_addon_confinement_probe_never_ships).
 *
 * Usage: a9_confinement_probe <probe> [argument]
 *
 * Prints exactly one line, "A9PROBE <probe> <rc> <errno>": rc 0 when the
 * attempted operation succeeded, -1 when it failed (errno then says why).
 * A probe the seccomp filter kills prints nothing; the gate reads that from
 * the unit's result. Each operation is harmless when it succeeds: it sets
 * what is already set, or makes and removes a scratch object.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/personality.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/swap.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>

static int report(const char *name, int rc) {
  int e = rc == 0 ? 0 : errno;
  printf("A9PROBE %s %d %d\n", name, rc == 0 ? 0 : -1, e);
  fflush(stdout);
  return 0;
}

/* A connect to addr:port, a closed port of the guest's own address: rc 0
 * when the network let it through (connected, or refused by the kernel's
 * reset), -1 with the errno a confinement layer gives (EAFNOSUPPORT, EPERM,
 * ENETUNREACH) or ETIMEDOUT when nothing came back in 3 s (IPAddressDeny=
 * drops the packets). */
static int net_connect(const char *addr, int port) {
  int s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  if (s < 0) return -1;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  inet_pton(AF_INET, addr, &a.sin_addr);
  int r = connect(s, (struct sockaddr *)&a, sizeof a);
  if (r == 0) { close(s); return 0; }
  if (errno != EINPROGRESS) {
    int e = errno;
    close(s);
    if (e == ECONNREFUSED) return 0;
    errno = e;
    return -1;
  }
  struct pollfd p = { s, POLLOUT, 0 };
  poll(&p, 1, 3000);
  int soerr = 0;
  socklen_t l = sizeof soerr;
  getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &l);
  close(s);
  if (soerr == 0 && !(p.revents & (POLLOUT | POLLERR | POLLHUP))) soerr = ETIMEDOUT;
  if (soerr == 0 || soerr == ECONNREFUSED) return 0;
  errno = soerr;
  return -1;
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  const char *p = argv[1];
  const char *arg = argc > 2 ? argv[2] : "";

  if (!strcmp(p, "nnp-child")) {
    /* Run from a setuid copy owned by nobody: the euid is nobody's only
     * when no_new_privs did not hold. */
    printf("A9PROBE nnp %d %d\n", geteuid() != 0 ? 0 : -1, geteuid() != 0 ? 0 : EPERM);
    return 0;
  }
  if (!strcmp(p, "nnp")) {
    /* A setuid copy of this binary owned by nobody, then exec'd. */
    const char *dst = "/var/lib/a9probe/suid";
    unlink(dst);
    int in = open("/proc/self/exe", O_RDONLY), out = open(dst, O_WRONLY | O_CREAT, 0755);
    if (in < 0 || out < 0) return report("nnp-setup", -1);
    char b[65536]; ssize_t n;
    while ((n = read(in, b, sizeof b)) > 0) if (write(out, b, n) != n) return report("nnp-setup", -1);
    close(in); close(out);
    if (chown(dst, 65534, 65534) != 0 || chmod(dst, 04755) != 0) return report("nnp-setup", -1);
    pid_t c = fork();
    if (c == 0) { execl(dst, dst, "nnp-child", (char *)0); _exit(3); }
    int st; waitpid(c, &st, 0);
    unlink(dst);
    return 0;
  }
  if (!strcmp(p, "caps")) return report(p, chroot("/"));
  if (!strcmp(p, "protect-system")) {
    int fd = open("/usr/a9probe-written", O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) { close(fd); unlink("/usr/a9probe-written"); }
    return report(p, fd >= 0 ? 0 : -1);
  }
  if (!strcmp(p, "exists")) {
    /* ProtectHome, PrivateTmp, PrivateDevices: a path the host has. */
    struct stat s;
    int r = stat(arg, &s);
    if (r == 0 && S_ISBLK(s.st_mode)) {
      int fd = open(arg, O_RDONLY);
      if (fd < 0) r = -1; else close(fd);
    }
    return report(p, r);
  }
  if (!strcmp(p, "kernel-tunables")) {
    int fd = open("/proc/sys/vm/swappiness", O_WRONLY);
    if (fd >= 0) close(fd);
    return report(p, fd >= 0 ? 0 : -1);
  }
  if (!strcmp(p, "kernel-modules")) {
    /* ProtectKernelModules makes the modules tree an empty, inaccessible
     * directory (root reads past its mode with CAP_DAC_OVERRIDE, but there
     * is nothing in it). */
    DIR *d = opendir("/usr/lib/modules");
    int seen = 0;
    if (d) { struct dirent *e; while ((e = readdir(d))) if (e->d_name[0] != '.') seen++; closedir(d); }
    if (!seen) errno = ENOENT;
    return report(p, seen ? 0 : -1);
  }
  if (!strcmp(p, "kernel-logs")) {
    int fd = open("/dev/kmsg", O_WRONLY);
    if (fd >= 0) close(fd);
    return report(p, fd >= 0 ? 0 : -1);
  }
  if (!strcmp(p, "control-groups")) {
    int r = mkdir("/sys/fs/cgroup/a9probe", 0755);
    if (r == 0) rmdir("/sys/fs/cgroup/a9probe");
    return report(p, r);
  }
  if (!strcmp(p, "clock")) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return report(p, clock_settime(CLOCK_REALTIME, &t));
  }
  if (!strcmp(p, "hostname")) {
    char h[256] = {0};
    gethostname(h, sizeof h - 1);
    return report(p, sethostname(h, strlen(h)));
  }
  if (!strcmp(p, "ns-net")) return report(p, unshare(CLONE_NEWNET));
  if (!strcmp(p, "ns-uts")) return report(p, unshare(CLONE_NEWUTS));
  if (!strcmp(p, "ns-user")) return report(p, unshare(CLONE_NEWUSER));
  if (!strcmp(p, "realtime")) {
    /* The raw call: musl's sched_setscheduler() returns ENOSYS by design. */
    struct sched_param sp = { .sched_priority = 1 };
    return report(p, (int)syscall(SYS_sched_setscheduler, 0, SCHED_FIFO, &sp));
  }
  if (!strcmp(p, "suid")) {
    const char *f = "/var/lib/a9probe/suid-mode";
    int fd = open(f, O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) close(fd);
    int r = chmod(f, 04755);
    unlink(f);
    return report(p, r);
  }
  if (!strcmp(p, "personality")) {
    int r = personality(PER_LINUX32);
    return report(p, r == -1 ? -1 : 0);
  }
  if (!strcmp(p, "mdwe")) {
    void *m = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return report("mdwe-setup", -1);
    return report(p, mprotect(m, 4096, PROT_READ | PROT_WRITE | PROT_EXEC));
  }
  if (!strcmp(p, "arch")) {
#if defined(__x86_64__)
    /* getpid through the i386 entry point: a foreign-architecture call. */
    long r;
    __asm__ volatile ("int $0x80" : "=a"(r) : "a"(20) : "memory");
    if (r < 0) { errno = (int)-r; return report(p, -1); }
    return report(p, 0);
#else
    errno = ENOSYS;
    return report("arch-unsupported", -1);
#endif
  }
  if (!strcmp(p, "filter")) {
    /* A call the deny list names (@swap): EPERM when the filter refuses it,
     * the kernel's own error (no such file) when it reaches the kernel. */
    return report(p, swapon("/nonexistent-a9probe", 0));
  }
  if (!strcmp(p, "net")) return report(p, net_connect(arg, 9));
  return 2;
}
