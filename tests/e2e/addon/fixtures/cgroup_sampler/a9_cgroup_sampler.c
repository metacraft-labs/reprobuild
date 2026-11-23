/*
 * The process-lifetime sampler of gate
 * e2e_addon_unit_syscall_filters_cover_their_traces (ReproOS add-on mode,
 * milestone A9). Built statically by the gate for the guest's architecture
 * and run in the guest while the add-on's units work.
 *
 *   a9-cgroup-sampler <out> <period-us> <unit>...
 *
 * Every <period-us> microseconds it reads the cgroup.procs of each
 * /sys/fs/cgroup/system.slice/<unit> (cgroup v2, cgroups(7)) and, for each
 * pid there, the process's start time: field 22 of /proc/<pid>/stat, in
 * clock ticks since boot (proc(5)). A process is identified by (pid, start
 * time): a pid the kernel reuses later is another process. For each one it
 * keeps the unit's control group it was seen in and the last time it was
 * seen. On SIGTERM it writes one line per process to <out>:
 *
 *   <unit> <pid> <start> <last-seen>
 *
 * both times in seconds since the epoch (start = boot time from
 * /proc/stat's btime + ticks / sysconf(_SC_CLK_TCK); last-seen from
 * CLOCK_REALTIME). The process lived from <start> to some time after
 * <last-seen> and before <last-seen> + <period>.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_PROCS 262144

struct proc_seen {
  int unit;
  int pid;
  unsigned long long start_ticks;
  double last;
};

static struct proc_seen procs[MAX_PROCS];
static int nprocs = 0;
static volatile sig_atomic_t stop = 0;

static void on_term(int sig) { (void)sig; stop = 1; }

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Field 22 of /proc/<pid>/stat; the comm field (2) may hold spaces and
 * parentheses, so the fields are counted from the last ')'. */
static int start_ticks(int pid, unsigned long long *out) {
  char path[64], buf[4096];
  snprintf(path, sizeof path, "/proc/%d/stat", pid);
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[n] = 0;
  char *p = strrchr(buf, ')');
  if (!p) return -1;
  p++;  /* now at " <state> ..." = field 3 */
  int field = 2;
  char *save = NULL;
  for (char *t = strtok_r(p, " ", &save); t; t = strtok_r(NULL, " ", &save)) {
    field++;
    if (field == 22) { *out = strtoull(t, NULL, 10); return 0; }
  }
  return -1;
}

static void seen(int unit, int pid, unsigned long long st, double t) {
  for (int i = nprocs - 1; i >= 0; i--) {
    if (procs[i].pid == pid && procs[i].start_ticks == st &&
        procs[i].unit == unit) {
      procs[i].last = t;
      return;
    }
  }
  if (nprocs < MAX_PROCS) {
    procs[nprocs].unit = unit;
    procs[nprocs].pid = pid;
    procs[nprocs].start_ticks = st;
    procs[nprocs].last = t;
    nprocs++;
  }
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: a9-cgroup-sampler <out> <period-us> <unit>...\n");
    return 2;
  }
  const char *out = argv[1];
  long period = strtol(argv[2], NULL, 10);
  int nunits = argc - 3;
  char **units = argv + 3;
  long tck = sysconf(_SC_CLK_TCK);
  double btime = 0;
  FILE *st = fopen("/proc/stat", "r");
  if (st) {
    char line[256];
    while (fgets(line, sizeof line, st))
      if (strncmp(line, "btime ", 6) == 0) btime = strtod(line + 6, NULL);
    fclose(st);
  }
  signal(SIGTERM, on_term);
  signal(SIGINT, on_term);
  struct timespec pause = {period / 1000000, (period % 1000000) * 1000};
  while (!stop) {
    double t = now();
    for (int u = 0; u < nunits; u++) {
      char path[512];
      snprintf(path, sizeof path, "/sys/fs/cgroup/system.slice/%s/cgroup.procs",
               units[u]);
      FILE *f = fopen(path, "r");
      if (!f) continue;
      int pid;
      while (fscanf(f, "%d", &pid) == 1) {
        unsigned long long s;
        if (start_ticks(pid, &s) == 0) seen(u, pid, s, t);
      }
      fclose(f);
    }
    nanosleep(&pause, NULL);
  }
  FILE *o = fopen(out, "w");
  if (!o) return 1;
  for (int i = 0; i < nprocs; i++)
    fprintf(o, "%s %d %.6f %.6f\n", units[procs[i].unit], procs[i].pid,
            btime + (double)procs[i].start_ticks / (double)tck, procs[i].last);
  fclose(o);
  return 0;
}
