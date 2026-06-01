when not defined(linux):
  {.error: "repro_monitor_hooks/linux_preload_runtime is Linux-only".}

import std/algorithm

type
  PidT* = int32

  LinuxHookSymbol = enum
    lhsOpen, lhsOpen64, lhsOpenat, lhsOpenat64, lhsClose, lhsRead, lhsWrite,
    lhsStat, lhsLstat, lhsOpendir, lhsReaddir, lhsClosedir, lhsFork,
    lhsExecve, lhsPosixSpawn, lhsPosixSpawnp

  OpenContext* = object
    path*: cstring
    flags*: cint
    mode*: cint
    result*: cint
    symbol: LinuxHookSymbol
    nextIndex: int

  OpenatContext* = object
    dirfd*: cint
    path*: cstring
    flags*: cint
    mode*: cint
    result*: cint
    symbol: LinuxHookSymbol
    nextIndex: int

  CloseContext* = object
    fd*: cint
    result*: cint
    nextIndex: int

  ReadContext* = object
    fd*: cint
    buf*: pointer
    count*: csize_t
    result*: clong
    nextIndex: int

  WriteContext* = object
    fd*: cint
    buf*: pointer
    count*: csize_t
    result*: clong
    nextIndex: int

  StatContext* = object
    path*: cstring
    buf*: pointer
    result*: cint
    symbol: LinuxHookSymbol
    nextIndex: int

  OpendirContext* = object
    path*: cstring
    result*: pointer
    nextIndex: int

  ReaddirContext* = object
    dirp*: pointer
    result*: pointer
    nextIndex: int

  ClosedirContext* = object
    dirp*: pointer
    result*: cint
    nextIndex: int

  ForkContext* = object
    result*: PidT
    nextIndex: int

  ExecveContext* = object
    path*: cstring
    argv*: cstringArray
    envp*: cstringArray
    result*: cint
    nextIndex: int

  PosixSpawnContext* = object
    pid*: ptr PidT
    path*: cstring
    fileActions*: pointer
    attrp*: pointer
    argv*: cstringArray
    envp*: cstringArray
    result*: cint
    symbol: LinuxHookSymbol
    nextIndex: int

  OpenHook* = proc(ctx: var OpenContext) {.raises: [].}
  OpenatHook* = proc(ctx: var OpenatContext) {.raises: [].}
  CloseHook* = proc(ctx: var CloseContext) {.raises: [].}
  ReadHook* = proc(ctx: var ReadContext) {.raises: [].}
  WriteHook* = proc(ctx: var WriteContext) {.raises: [].}
  StatHook* = proc(ctx: var StatContext) {.raises: [].}
  OpendirHook* = proc(ctx: var OpendirContext) {.raises: [].}
  ReaddirHook* = proc(ctx: var ReaddirContext) {.raises: [].}
  ClosedirHook* = proc(ctx: var ClosedirContext) {.raises: [].}
  ForkHook* = proc(ctx: var ForkContext) {.raises: [].}
  ExecveHook* = proc(ctx: var ExecveContext) {.raises: [].}
  PosixSpawnHook* = proc(ctx: var PosixSpawnContext) {.raises: [].}

  OpenHookEntry = object
    priority: int
    callback: OpenHook
  OpenatHookEntry = object
    priority: int
    callback: OpenatHook
  CloseHookEntry = object
    priority: int
    callback: CloseHook
  ReadHookEntry = object
    priority: int
    callback: ReadHook
  WriteHookEntry = object
    priority: int
    callback: WriteHook
  StatHookEntry = object
    priority: int
    callback: StatHook
  OpendirHookEntry = object
    priority: int
    callback: OpendirHook
  ReaddirHookEntry = object
    priority: int
    callback: ReaddirHook
  ClosedirHookEntry = object
    priority: int
    callback: ClosedirHook
  ForkHookEntry = object
    priority: int
    callback: ForkHook
  ExecveHookEntry = object
    priority: int
    callback: ExecveHook
  PosixSpawnHookEntry = object
    priority: int
    callback: PosixSpawnHook

{.emit: """
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

typedef long ssize_like_t;
typedef int (*ct_open_hook_fn)(char *, int, int);
typedef int (*ct_openat_hook_fn)(int, char *, int, int);
typedef int (*ct_close_hook_fn)(int);
typedef ssize_like_t (*ct_read_hook_fn)(int, void *, size_t);
typedef ssize_like_t (*ct_write_hook_fn)(int, void *, size_t);
typedef int (*ct_stat_hook_fn)(char *, void *);
typedef void *(*ct_opendir_hook_fn)(char *);
typedef void *(*ct_readdir_hook_fn)(void *);
typedef int (*ct_closedir_hook_fn)(void *);
typedef pid_t (*ct_fork_hook_fn)(void);
typedef int (*ct_execve_hook_fn)(char *, char **, char **);
typedef int (*ct_posix_spawn_hook_fn)(pid_t *, char *, void *, void *,
                                      char **, char **);

typedef int (*ct_open_real_fn)(const char *, int, ...);
typedef int (*ct_openat_real_fn)(int, const char *, int, ...);
typedef int (*ct_close_real_fn)(int);
typedef ssize_t (*ct_read_real_fn)(int, void *, size_t);
typedef ssize_t (*ct_write_real_fn)(int, const void *, size_t);
typedef int (*ct_stat_real_fn)(const char *, struct stat *);
typedef int (*ct_xstat_real_fn)(int, const char *, struct stat *);
typedef DIR *(*ct_opendir_real_fn)(const char *);
typedef struct dirent *(*ct_readdir_real_fn)(DIR *);
typedef int (*ct_closedir_real_fn)(DIR *);
typedef pid_t (*ct_fork_real_fn)(void);
typedef int (*ct_execve_real_fn)(const char *, char *const [], char *const []);
typedef int (*ct_posix_spawn_real_fn)(pid_t *, const char *,
                                      const posix_spawn_file_actions_t *,
                                      const posix_spawnattr_t *,
                                      char *const [], char *const []);

static __thread int ct_linux_preload_hook_depth = 0;
static const char *ct_linux_preload_shim_env_name = NULL;

static ct_open_hook_fn ct_open_hook = NULL;
static ct_open_hook_fn ct_open64_hook = NULL;
static ct_openat_hook_fn ct_openat_hook = NULL;
static ct_openat_hook_fn ct_openat64_hook = NULL;
static ct_close_hook_fn ct_close_hook = NULL;
static ct_read_hook_fn ct_read_hook = NULL;
static ct_write_hook_fn ct_write_hook = NULL;
static ct_stat_hook_fn ct_stat_hook = NULL;
static ct_stat_hook_fn ct_lstat_hook = NULL;
static ct_opendir_hook_fn ct_opendir_hook = NULL;
static ct_readdir_hook_fn ct_readdir_hook = NULL;
static ct_closedir_hook_fn ct_closedir_hook = NULL;
static ct_fork_hook_fn ct_fork_hook = NULL;
static ct_execve_hook_fn ct_execve_hook = NULL;
static ct_posix_spawn_hook_fn ct_posix_spawn_hook = NULL;
static ct_posix_spawn_hook_fn ct_posix_spawnp_hook = NULL;

static ct_open_real_fn real_open_ptr = NULL;
static ct_open_real_fn real_open64_ptr = NULL;
static ct_openat_real_fn real_openat_ptr = NULL;
static ct_openat_real_fn real_openat64_ptr = NULL;
static ct_close_real_fn real_close_ptr = NULL;
static ct_read_real_fn real_read_ptr = NULL;
static ct_write_real_fn real_write_ptr = NULL;
static ct_stat_real_fn real_stat_ptr = NULL;
static ct_stat_real_fn real_lstat_ptr = NULL;
static ct_xstat_real_fn real_xstat_ptr = NULL;
static ct_xstat_real_fn real_lxstat_ptr = NULL;
static ct_opendir_real_fn real_opendir_ptr = NULL;
static ct_readdir_real_fn real_readdir_ptr = NULL;
static ct_closedir_real_fn real_closedir_ptr = NULL;
static ct_fork_real_fn real_fork_ptr = NULL;
static ct_execve_real_fn real_execve_ptr = NULL;
static ct_posix_spawn_real_fn real_posix_spawn_ptr = NULL;
static ct_posix_spawn_real_fn real_posix_spawnp_ptr = NULL;

static void *ct_resolve(const char *name) {
  ct_linux_preload_hook_depth++;
  void *result = dlsym(RTLD_NEXT, name);
  ct_linux_preload_hook_depth--;
  return result;
}

#define CT_BYPASS() (ct_linux_preload_hook_depth > 0)
#define CT_CALL_HOOK(expr) ({ \
  ct_linux_preload_hook_depth++; \
  __typeof__(expr) _ct_result = (expr); \
  ct_linux_preload_hook_depth--; \
  _ct_result; \
})

static int ct_starts_with(const char *value, const char *prefix) {
  return strncmp(value, prefix, strlen(prefix)) == 0;
}

static int ct_env_contains_shim(const char *entry, const char *shim) {
  const char *value = entry + strlen("LD_PRELOAD=");
  return strstr(value, shim) != NULL;
}

void ct_linux_preload_set_shim_env_name(const char *name) {
  ct_linux_preload_shim_env_name = name;
}

char **ct_linux_preload_env_with_preload(char *const envp[]) {
  if (ct_linux_preload_shim_env_name == NULL ||
      ct_linux_preload_shim_env_name[0] == '\0') {
    return (char **)envp;
  }
  const char *shim = getenv(ct_linux_preload_shim_env_name);
  if (shim == NULL || shim[0] == '\0') {
    return (char **)envp;
  }
  char *const *source = envp != NULL ? envp : environ;
  if (source == NULL) {
    return (char **)envp;
  }

  int count = 0;
  const char *existing = NULL;
  for (char *const *it = source; *it != NULL; it++) {
    if (ct_starts_with(*it, "LD_PRELOAD=")) {
      existing = *it;
      if (ct_env_contains_shim(*it, shim)) {
        return (char **)envp;
      }
    } else {
      count++;
    }
  }

  const char *existingValue =
    existing != NULL ? existing + strlen("LD_PRELOAD=") : "";
  size_t entryLen = strlen("LD_PRELOAD=") + strlen(shim) + 1;
  if (existingValue[0] != '\0') {
    entryLen += 1 + strlen(existingValue);
  }
  char *entry = (char *)malloc(entryLen);
  if (entry == NULL) {
    return (char **)envp;
  }
  if (existingValue[0] != '\0') {
    snprintf(entry, entryLen, "LD_PRELOAD=%s:%s", shim, existingValue);
  } else {
    snprintf(entry, entryLen, "LD_PRELOAD=%s", shim);
  }

  char **result = (char **)calloc((size_t)count + 2, sizeof(char *));
  if (result == NULL) {
    free(entry);
    return (char **)envp;
  }
  int index = 0;
  for (char *const *it = source; *it != NULL; it++) {
    if (!ct_starts_with(*it, "LD_PRELOAD=")) {
      result[index++] = *it;
    }
  }
  result[index++] = entry;
  result[index] = NULL;
  return result;
}

void ct_linux_preload_register_open_hook(ct_open_hook_fn hook) { ct_open_hook = hook; }
void ct_linux_preload_register_open64_hook(ct_open_hook_fn hook) { ct_open64_hook = hook; }
void ct_linux_preload_register_openat_hook(ct_openat_hook_fn hook) { ct_openat_hook = hook; }
void ct_linux_preload_register_openat64_hook(ct_openat_hook_fn hook) { ct_openat64_hook = hook; }
void ct_linux_preload_register_close_hook(ct_close_hook_fn hook) { ct_close_hook = hook; }
void ct_linux_preload_register_read_hook(ct_read_hook_fn hook) { ct_read_hook = hook; }
void ct_linux_preload_register_write_hook(ct_write_hook_fn hook) { ct_write_hook = hook; }
void ct_linux_preload_register_stat_hook(ct_stat_hook_fn hook) { ct_stat_hook = hook; }
void ct_linux_preload_register_lstat_hook(ct_stat_hook_fn hook) { ct_lstat_hook = hook; }
void ct_linux_preload_register_opendir_hook(ct_opendir_hook_fn hook) { ct_opendir_hook = hook; }
void ct_linux_preload_register_readdir_hook(ct_readdir_hook_fn hook) { ct_readdir_hook = hook; }
void ct_linux_preload_register_closedir_hook(ct_closedir_hook_fn hook) { ct_closedir_hook = hook; }
void ct_linux_preload_register_fork_hook(ct_fork_hook_fn hook) { ct_fork_hook = hook; }
void ct_linux_preload_register_execve_hook(ct_execve_hook_fn hook) { ct_execve_hook = hook; }
void ct_linux_preload_register_posix_spawn_hook(ct_posix_spawn_hook_fn hook) { ct_posix_spawn_hook = hook; }
void ct_linux_preload_register_posix_spawnp_hook(ct_posix_spawn_hook_fn hook) { ct_posix_spawnp_hook = hook; }

static int ct_real_open_common(ct_open_real_fn *slot, const char *symbol,
                               char *path, int flags, int mode) {
  if (*slot == NULL) *slot = (ct_open_real_fn)ct_resolve(symbol);
  if (*slot == NULL && strcmp(symbol, "open64") == 0)
    *slot = (ct_open_real_fn)ct_resolve("open");
  if (*slot == NULL) { errno = ENOSYS; return -1; }
  return (flags & O_CREAT) ? (*slot)(path, flags, mode) : (*slot)(path, flags);
}

int ct_linux_preload_real_open(char *path, int flags, int mode) {
  return ct_real_open_common(&real_open_ptr, "open", path, flags, mode);
}

int ct_linux_preload_real_open64(char *path, int flags, int mode) {
  return ct_real_open_common(&real_open64_ptr, "open64", path, flags, mode);
}

static int ct_real_openat_common(ct_openat_real_fn *slot, const char *symbol,
                                 int dirfd, char *path, int flags, int mode) {
  if (*slot == NULL) *slot = (ct_openat_real_fn)ct_resolve(symbol);
  if (*slot == NULL && strcmp(symbol, "openat64") == 0)
    *slot = (ct_openat_real_fn)ct_resolve("openat");
  if (*slot == NULL) { errno = ENOSYS; return -1; }
  return (flags & O_CREAT) ? (*slot)(dirfd, path, flags, mode) :
                             (*slot)(dirfd, path, flags);
}

int ct_linux_preload_real_openat(int dirfd, char *path, int flags, int mode) {
  return ct_real_openat_common(&real_openat_ptr, "openat", dirfd, path, flags, mode);
}

int ct_linux_preload_real_openat64(int dirfd, char *path, int flags, int mode) {
  return ct_real_openat_common(&real_openat64_ptr, "openat64", dirfd, path, flags, mode);
}

#define CT_REAL(name, slot, type) do { \
  if ((slot) == NULL) (slot) = (type)ct_resolve(name); \
  if ((slot) == NULL) { errno = ENOSYS; return -1; } \
} while (0)

ssize_like_t ct_linux_preload_real_read(int fd, void *buf, size_t count) {
  CT_REAL("read", real_read_ptr, ct_read_real_fn);
  return (ssize_like_t)real_read_ptr(fd, buf, count);
}

ssize_like_t ct_linux_preload_real_write(int fd, void *buf, size_t count) {
  CT_REAL("write", real_write_ptr, ct_write_real_fn);
  return (ssize_like_t)real_write_ptr(fd, buf, count);
}

int ct_linux_preload_real_close(int fd) {
  CT_REAL("close", real_close_ptr, ct_close_real_fn);
  return real_close_ptr(fd);
}

int ct_linux_preload_real_stat(char *path, void *buf) {
  CT_REAL("stat", real_stat_ptr, ct_stat_real_fn);
  return real_stat_ptr(path, (struct stat *)buf);
}

int ct_linux_preload_real_lstat(char *path, void *buf) {
  CT_REAL("lstat", real_lstat_ptr, ct_stat_real_fn);
  return real_lstat_ptr(path, (struct stat *)buf);
}

void *ct_linux_preload_real_opendir(char *path) {
  if (real_opendir_ptr == NULL) real_opendir_ptr = (ct_opendir_real_fn)ct_resolve("opendir");
  if (real_opendir_ptr == NULL) { errno = ENOSYS; return NULL; }
  return (void *)real_opendir_ptr(path);
}

void *ct_linux_preload_real_readdir(void *dirp) {
  if (real_readdir_ptr == NULL) real_readdir_ptr = (ct_readdir_real_fn)ct_resolve("readdir");
  if (real_readdir_ptr == NULL) { errno = ENOSYS; return NULL; }
  return (void *)real_readdir_ptr((DIR *)dirp);
}

int ct_linux_preload_real_closedir(void *dirp) {
  CT_REAL("closedir", real_closedir_ptr, ct_closedir_real_fn);
  return real_closedir_ptr((DIR *)dirp);
}

pid_t ct_linux_preload_real_fork(void) {
  CT_REAL("fork", real_fork_ptr, ct_fork_real_fn);
  return real_fork_ptr();
}

int ct_linux_preload_real_execve(char *path, char **argv, char **envp) {
  CT_REAL("execve", real_execve_ptr, ct_execve_real_fn);
  return real_execve_ptr(path, argv, envp);
}

int ct_linux_preload_real_posix_spawn(pid_t *pid, char *path,
                                      void *file_actions, void *attrp,
                                      char **argv, char **envp) {
  CT_REAL("posix_spawn", real_posix_spawn_ptr, ct_posix_spawn_real_fn);
  return real_posix_spawn_ptr(pid, path, file_actions, attrp, argv, envp);
}

int ct_linux_preload_real_posix_spawnp(pid_t *pid, char *file,
                                       void *file_actions, void *attrp,
                                       char **argv, char **envp) {
  CT_REAL("posix_spawnp", real_posix_spawnp_ptr, ct_posix_spawn_real_fn);
  return real_posix_spawnp_ptr(pid, file, file_actions, attrp, argv, envp);
}

ssize_t read(int fd, void *buf, size_t count) __attribute__((visibility("default")));
ssize_t read(int fd, void *buf, size_t count) {
  if (CT_BYPASS() || ct_read_hook == NULL)
    return (ssize_t)ct_linux_preload_real_read(fd, buf, count);
  return (ssize_t)CT_CALL_HOOK(ct_read_hook(fd, buf, count));
}

ssize_t write(int fd, const void *buf, size_t count) __attribute__((visibility("default")));
ssize_t write(int fd, const void *buf, size_t count) {
  if (CT_BYPASS() || ct_write_hook == NULL)
    return (ssize_t)ct_linux_preload_real_write(fd, (void *)buf, count);
  return (ssize_t)CT_CALL_HOOK(ct_write_hook(fd, (void *)buf, count));
}

int open(const char *path, int flags, ...) __attribute__((visibility("default")));
int open(const char *path, int flags, ...) {
  int mode = 0;
  if (flags & O_CREAT) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  if (CT_BYPASS() || ct_open_hook == NULL)
    return ct_linux_preload_real_open((char *)path, flags, mode);
  return CT_CALL_HOOK(ct_open_hook((char *)path, flags, mode));
}

int open64(const char *path, int flags, ...) __attribute__((visibility("default")));
int open64(const char *path, int flags, ...) {
  int mode = 0;
  if (flags & O_CREAT) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  if (CT_BYPASS() || ct_open64_hook == NULL)
    return ct_linux_preload_real_open64((char *)path, flags, mode);
  return CT_CALL_HOOK(ct_open64_hook((char *)path, flags, mode));
}

int openat(int dirfd, const char *path, int flags, ...) __attribute__((visibility("default")));
int openat(int dirfd, const char *path, int flags, ...) {
  int mode = 0;
  if (flags & O_CREAT) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  if (CT_BYPASS() || ct_openat_hook == NULL)
    return ct_linux_preload_real_openat(dirfd, (char *)path, flags, mode);
  return CT_CALL_HOOK(ct_openat_hook(dirfd, (char *)path, flags, mode));
}

int openat64(int dirfd, const char *path, int flags, ...) __attribute__((visibility("default")));
int openat64(int dirfd, const char *path, int flags, ...) {
  int mode = 0;
  if (flags & O_CREAT) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  if (CT_BYPASS() || ct_openat64_hook == NULL)
    return ct_linux_preload_real_openat64(dirfd, (char *)path, flags, mode);
  return CT_CALL_HOOK(ct_openat64_hook(dirfd, (char *)path, flags, mode));
}

int close(int fd) __attribute__((visibility("default")));
int close(int fd) {
  if (CT_BYPASS() || ct_close_hook == NULL)
    return ct_linux_preload_real_close(fd);
  return CT_CALL_HOOK(ct_close_hook(fd));
}

int stat(const char *path, struct stat *buf) __attribute__((visibility("default")));
int stat(const char *path, struct stat *buf) {
  if (CT_BYPASS() || ct_stat_hook == NULL)
    return ct_linux_preload_real_stat((char *)path, buf);
  return CT_CALL_HOOK(ct_stat_hook((char *)path, buf));
}

int lstat(const char *path, struct stat *buf) __attribute__((visibility("default")));
int lstat(const char *path, struct stat *buf) {
  if (CT_BYPASS() || ct_lstat_hook == NULL)
    return ct_linux_preload_real_lstat((char *)path, buf);
  return CT_CALL_HOOK(ct_lstat_hook((char *)path, buf));
}

int __xstat(int ver, const char *path, struct stat *buf) __attribute__((visibility("default")));
int __xstat(int ver, const char *path, struct stat *buf) {
  if (CT_BYPASS() || ct_stat_hook == NULL) {
    if (real_xstat_ptr == NULL) real_xstat_ptr = (ct_xstat_real_fn)ct_resolve("__xstat");
    if (real_xstat_ptr == NULL) return ct_linux_preload_real_stat((char *)path, buf);
    return real_xstat_ptr(ver, path, buf);
  }
  return CT_CALL_HOOK(ct_stat_hook((char *)path, buf));
}

int __lxstat(int ver, const char *path, struct stat *buf) __attribute__((visibility("default")));
int __lxstat(int ver, const char *path, struct stat *buf) {
  if (CT_BYPASS() || ct_lstat_hook == NULL) {
    if (real_lxstat_ptr == NULL) real_lxstat_ptr = (ct_xstat_real_fn)ct_resolve("__lxstat");
    if (real_lxstat_ptr == NULL) return ct_linux_preload_real_lstat((char *)path, buf);
    return real_lxstat_ptr(ver, path, buf);
  }
  return CT_CALL_HOOK(ct_lstat_hook((char *)path, buf));
}

DIR *opendir(const char *path) __attribute__((visibility("default")));
DIR *opendir(const char *path) {
  if (CT_BYPASS() || ct_opendir_hook == NULL)
    return (DIR *)ct_linux_preload_real_opendir((char *)path);
  return (DIR *)CT_CALL_HOOK(ct_opendir_hook((char *)path));
}

struct dirent *readdir(DIR *dirp) __attribute__((visibility("default")));
struct dirent *readdir(DIR *dirp) {
  if (CT_BYPASS() || ct_readdir_hook == NULL)
    return (struct dirent *)ct_linux_preload_real_readdir((void *)dirp);
  return (struct dirent *)CT_CALL_HOOK(ct_readdir_hook((void *)dirp));
}

int closedir(DIR *dirp) __attribute__((visibility("default")));
int closedir(DIR *dirp) {
  if (CT_BYPASS() || ct_closedir_hook == NULL)
    return ct_linux_preload_real_closedir((void *)dirp);
  return CT_CALL_HOOK(ct_closedir_hook((void *)dirp));
}

pid_t fork(void) __attribute__((visibility("default")));
pid_t fork(void) {
  if (CT_BYPASS() || ct_fork_hook == NULL)
    return ct_linux_preload_real_fork();
  return CT_CALL_HOOK(ct_fork_hook());
}

int execve(const char *path, char *const argv[], char *const envp[])
    __attribute__((visibility("default")));
int execve(const char *path, char *const argv[], char *const envp[]) {
  if (CT_BYPASS() || ct_execve_hook == NULL)
    return ct_linux_preload_real_execve((char *)path, (char **)argv, (char **)envp);
  return CT_CALL_HOOK(ct_execve_hook((char *)path, (char **)argv, (char **)envp));
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
    __attribute__((visibility("default")));
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions,
                const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
  if (CT_BYPASS() || ct_posix_spawn_hook == NULL)
    return ct_linux_preload_real_posix_spawn(pid, (char *)path, (void *)file_actions,
                                             (void *)attrp, (char **)argv, (char **)envp);
  return CT_CALL_HOOK(ct_posix_spawn_hook(pid, (char *)path, (void *)file_actions,
                                          (void *)attrp, (char **)argv, (char **)envp));
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *file_actions,
                 const posix_spawnattr_t *attrp, char *const argv[], char *const envp[])
    __attribute__((visibility("default")));
int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *file_actions,
                 const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
  if (CT_BYPASS() || ct_posix_spawnp_hook == NULL)
    return ct_linux_preload_real_posix_spawnp(pid, (char *)file, (void *)file_actions,
                                              (void *)attrp, (char **)argv, (char **)envp);
  return CT_CALL_HOOK(ct_posix_spawnp_hook(pid, (char *)file, (void *)file_actions,
                                           (void *)attrp, (char **)argv, (char **)envp));
}

/* glibc's <fcntl.h> and <unistd.h> expand to the __*_2 / __*_chk
 * fortify entry points whenever the compiler can prove the safety
 * invariants at compile time (e.g. _FORTIFY_SOURCE >= 1, a constant
 * `flags` argument without O_CREAT). Nix's cc-wrapper enables
 * _FORTIFY_SOURCE=2 by default, so a fixture like
 *   int fd = open(argv[1], O_RDONLY);
 *   read(fd, buf, sizeof(buf));
 * resolves to __open_2 / __read_chk rather than open / read, and an
 * LD_PRELOAD shim that only exports open / read silently sees zero
 * calls. Forward each fortify entry point to its public sibling so
 * the registered hook chain fires regardless of how aggressively
 * the host glibc fortifies. */
int __open_2(const char *path, int flags) __attribute__((visibility("default")));
int __open_2(const char *path, int flags) { return open(path, flags); }

int __open64_2(const char *path, int flags) __attribute__((visibility("default")));
int __open64_2(const char *path, int flags) { return open64(path, flags); }

int __openat_2(int dirfd, const char *path, int flags) __attribute__((visibility("default")));
int __openat_2(int dirfd, const char *path, int flags) { return openat(dirfd, path, flags); }

int __openat64_2(int dirfd, const char *path, int flags) __attribute__((visibility("default")));
int __openat64_2(int dirfd, const char *path, int flags) { return openat64(dirfd, path, flags); }

ssize_t __read_chk(int fd, void *buf, size_t nbytes, size_t buflen)
    __attribute__((visibility("default")));
ssize_t __read_chk(int fd, void *buf, size_t nbytes, size_t buflen) {
  /* The buflen >= nbytes contract is the caller's; the fortify check
   * collapses at compile time when the bound is provable. Delegating
   * to read() preserves the hook chain and matches what every other
   * LD_PRELOAD shim ships. */
  (void)buflen;
  return read(fd, buf, nbytes);
}
""".}

proc setPreloadShimEnvVar*(name: cstring) {.importc: "ct_linux_preload_set_shim_env_name",
    raises: [].}
proc envWithPreload*(envp: cstringArray): cstringArray
  {.importc: "ct_linux_preload_env_with_preload", raises: [].}

proc realOpen*(path: cstring; flags, mode: cint): cint
  {.importc: "ct_linux_preload_real_open", raises: [].}
proc realOpen64*(path: cstring; flags, mode: cint): cint
  {.importc: "ct_linux_preload_real_open64", raises: [].}
proc realOpenat*(dirfd: cint; path: cstring; flags, mode: cint): cint
  {.importc: "ct_linux_preload_real_openat", raises: [].}
proc realOpenat64*(dirfd: cint; path: cstring; flags, mode: cint): cint
  {.importc: "ct_linux_preload_real_openat64", raises: [].}
proc realClose*(fd: cint): cint {.importc: "ct_linux_preload_real_close",
    raises: [].}
proc realRead*(fd: cint; buf: pointer; count: csize_t): clong
  {.importc: "ct_linux_preload_real_read", raises: [].}
proc realWrite*(fd: cint; buf: pointer; count: csize_t): clong
  {.importc: "ct_linux_preload_real_write", raises: [].}
proc realStat*(path: cstring; buf: pointer): cint
  {.importc: "ct_linux_preload_real_stat", raises: [].}
proc realLstat*(path: cstring; buf: pointer): cint
  {.importc: "ct_linux_preload_real_lstat", raises: [].}
proc realOpendir*(path: cstring): pointer
  {.importc: "ct_linux_preload_real_opendir", raises: [].}
proc realReaddir*(dirp: pointer): pointer
  {.importc: "ct_linux_preload_real_readdir", raises: [].}
proc realClosedir*(dirp: pointer): cint
  {.importc: "ct_linux_preload_real_closedir", raises: [].}
proc realFork*(): PidT {.importc: "ct_linux_preload_real_fork", raises: [].}
proc realExecve*(path: cstring; argv, envp: cstringArray): cint
  {.importc: "ct_linux_preload_real_execve", raises: [].}
proc realPosixSpawn*(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
                     argv, envp: cstringArray): cint
  {.importc: "ct_linux_preload_real_posix_spawn", raises: [].}
proc realPosixSpawnp*(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
                      argv, envp: cstringArray): cint
  {.importc: "ct_linux_preload_real_posix_spawnp", raises: [].}

type
  OpenDispatch = proc(path: cstring; flags, mode: cint): cint
    {.cdecl, raises: [].}
  OpenatDispatch = proc(dirfd: cint; path: cstring; flags, mode: cint): cint
    {.cdecl, raises: [].}
  CloseDispatch = proc(fd: cint): cint {.cdecl, raises: [].}
  ReadDispatch = proc(fd: cint; buf: pointer; count: csize_t): clong
    {.cdecl, raises: [].}
  WriteDispatch = proc(fd: cint; buf: pointer; count: csize_t): clong
    {.cdecl, raises: [].}
  StatDispatch = proc(path: cstring; buf: pointer): cint {.cdecl, raises: [].}
  OpendirDispatch = proc(path: cstring): pointer {.cdecl, raises: [].}
  ReaddirDispatch = proc(dirp: pointer): pointer {.cdecl, raises: [].}
  ClosedirDispatch = proc(dirp: pointer): cint {.cdecl, raises: [].}
  ForkDispatch = proc(): PidT {.cdecl, raises: [].}
  ExecveDispatch = proc(path: cstring; argv, envp: cstringArray): cint
    {.cdecl, raises: [].}
  PosixSpawnDispatch = proc(pid: ptr PidT; path: cstring; fileActions,
                           attrp: pointer; argv, envp: cstringArray): cint
    {.cdecl, raises: [].}

proc installOpenDispatcher(dispatch: OpenDispatch)
  {.importc: "ct_linux_preload_register_open_hook", raises: [].}
proc installOpen64Dispatcher(dispatch: OpenDispatch)
  {.importc: "ct_linux_preload_register_open64_hook", raises: [].}
proc installOpenatDispatcher(dispatch: OpenatDispatch)
  {.importc: "ct_linux_preload_register_openat_hook", raises: [].}
proc installOpenat64Dispatcher(dispatch: OpenatDispatch)
  {.importc: "ct_linux_preload_register_openat64_hook", raises: [].}
proc installCloseDispatcher(dispatch: CloseDispatch)
  {.importc: "ct_linux_preload_register_close_hook", raises: [].}
proc installReadDispatcher(dispatch: ReadDispatch)
  {.importc: "ct_linux_preload_register_read_hook", raises: [].}
proc installWriteDispatcher(dispatch: WriteDispatch)
  {.importc: "ct_linux_preload_register_write_hook", raises: [].}
proc installStatDispatcher(dispatch: StatDispatch)
  {.importc: "ct_linux_preload_register_stat_hook", raises: [].}
proc installLstatDispatcher(dispatch: StatDispatch)
  {.importc: "ct_linux_preload_register_lstat_hook", raises: [].}
proc installOpendirDispatcher(dispatch: OpendirDispatch)
  {.importc: "ct_linux_preload_register_opendir_hook", raises: [].}
proc installReaddirDispatcher(dispatch: ReaddirDispatch)
  {.importc: "ct_linux_preload_register_readdir_hook", raises: [].}
proc installClosedirDispatcher(dispatch: ClosedirDispatch)
  {.importc: "ct_linux_preload_register_closedir_hook", raises: [].}
proc installForkDispatcher(dispatch: ForkDispatch)
  {.importc: "ct_linux_preload_register_fork_hook", raises: [].}
proc installExecveDispatcher(dispatch: ExecveDispatch)
  {.importc: "ct_linux_preload_register_execve_hook", raises: [].}
proc installPosixSpawnDispatcher(dispatch: PosixSpawnDispatch)
  {.importc: "ct_linux_preload_register_posix_spawn_hook", raises: [].}
proc installPosixSpawnpDispatcher(dispatch: PosixSpawnDispatch)
  {.importc: "ct_linux_preload_register_posix_spawnp_hook", raises: [].}

var
  openHooks: seq[OpenHookEntry] = @[]
  open64Hooks: seq[OpenHookEntry] = @[]
  openatHooks: seq[OpenatHookEntry] = @[]
  openat64Hooks: seq[OpenatHookEntry] = @[]
  closeHooks: seq[CloseHookEntry] = @[]
  readHooks: seq[ReadHookEntry] = @[]
  writeHooks: seq[WriteHookEntry] = @[]
  statHooks: seq[StatHookEntry] = @[]
  lstatHooks: seq[StatHookEntry] = @[]
  opendirHooks: seq[OpendirHookEntry] = @[]
  readdirHooks: seq[ReaddirHookEntry] = @[]
  closedirHooks: seq[ClosedirHookEntry] = @[]
  forkHooks: seq[ForkHookEntry] = @[]
  execveHooks: seq[ExecveHookEntry] = @[]
  posixSpawnHooks: seq[PosixSpawnHookEntry] = @[]
  posixSpawnpHooks: seq[PosixSpawnHookEntry] = @[]

proc registerOpenHook*(hook: OpenHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  openHooks.add(OpenHookEntry(priority: priority, callback: hook))
  openHooks.sort(proc(a, b: OpenHookEntry): int = cmp(a.priority, b.priority))

proc registerOpen64Hook*(hook: OpenHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  open64Hooks.add(OpenHookEntry(priority: priority, callback: hook))
  open64Hooks.sort(proc(a, b: OpenHookEntry): int = cmp(a.priority, b.priority))

proc registerOpenatHook*(hook: OpenatHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  openatHooks.add(OpenatHookEntry(priority: priority, callback: hook))
  openatHooks.sort(proc(a, b: OpenatHookEntry): int = cmp(a.priority, b.priority))

proc registerOpenat64Hook*(hook: OpenatHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  openat64Hooks.add(OpenatHookEntry(priority: priority, callback: hook))
  openat64Hooks.sort(proc(a, b: OpenatHookEntry): int = cmp(a.priority, b.priority))

proc registerCloseHook*(hook: CloseHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  closeHooks.add(CloseHookEntry(priority: priority, callback: hook))
  closeHooks.sort(proc(a, b: CloseHookEntry): int = cmp(a.priority, b.priority))

proc registerReadHook*(hook: ReadHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  readHooks.add(ReadHookEntry(priority: priority, callback: hook))
  readHooks.sort(proc(a, b: ReadHookEntry): int = cmp(a.priority, b.priority))

proc registerWriteHook*(hook: WriteHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  writeHooks.add(WriteHookEntry(priority: priority, callback: hook))
  writeHooks.sort(proc(a, b: WriteHookEntry): int = cmp(a.priority, b.priority))

proc registerStatHook*(hook: StatHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  statHooks.add(StatHookEntry(priority: priority, callback: hook))
  statHooks.sort(proc(a, b: StatHookEntry): int = cmp(a.priority, b.priority))

proc registerLstatHook*(hook: StatHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  lstatHooks.add(StatHookEntry(priority: priority, callback: hook))
  lstatHooks.sort(proc(a, b: StatHookEntry): int = cmp(a.priority, b.priority))

proc registerOpendirHook*(hook: OpendirHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  opendirHooks.add(OpendirHookEntry(priority: priority, callback: hook))
  opendirHooks.sort(proc(a, b: OpendirHookEntry): int = cmp(a.priority, b.priority))

proc registerReaddirHook*(hook: ReaddirHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  readdirHooks.add(ReaddirHookEntry(priority: priority, callback: hook))
  readdirHooks.sort(proc(a, b: ReaddirHookEntry): int = cmp(a.priority, b.priority))

proc registerClosedirHook*(hook: ClosedirHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  closedirHooks.add(ClosedirHookEntry(priority: priority, callback: hook))
  closedirHooks.sort(proc(a, b: ClosedirHookEntry): int = cmp(a.priority, b.priority))

proc registerForkHook*(hook: ForkHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  forkHooks.add(ForkHookEntry(priority: priority, callback: hook))
  forkHooks.sort(proc(a, b: ForkHookEntry): int = cmp(a.priority, b.priority))

proc registerExecveHook*(hook: ExecveHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  execveHooks.add(ExecveHookEntry(priority: priority, callback: hook))
  execveHooks.sort(proc(a, b: ExecveHookEntry): int = cmp(a.priority, b.priority))

proc registerPosixSpawnHook*(hook: PosixSpawnHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  posixSpawnHooks.add(PosixSpawnHookEntry(priority: priority, callback: hook))
  posixSpawnHooks.sort(proc(a, b: PosixSpawnHookEntry): int =
    cmp(a.priority, b.priority))

proc registerPosixSpawnpHook*(hook: PosixSpawnHook; priority = 100) {.raises: [].} =
  if hook == nil:
    return
  posixSpawnpHooks.add(PosixSpawnHookEntry(priority: priority, callback: hook))
  posixSpawnpHooks.sort(proc(a, b: PosixSpawnHookEntry): int =
    cmp(a.priority, b.priority))

proc callReal*(ctx: var OpenContext) {.raises: [].} =
  case ctx.symbol
  of lhsOpen64:
    ctx.result = realOpen64(ctx.path, ctx.flags, ctx.mode)
  else:
    ctx.result = realOpen(ctx.path, ctx.flags, ctx.mode)

proc callReal*(ctx: var OpenatContext) {.raises: [].} =
  case ctx.symbol
  of lhsOpenat64:
    ctx.result = realOpenat64(ctx.dirfd, ctx.path, ctx.flags, ctx.mode)
  else:
    ctx.result = realOpenat(ctx.dirfd, ctx.path, ctx.flags, ctx.mode)

proc callReal*(ctx: var CloseContext) {.raises: [].} =
  ctx.result = realClose(ctx.fd)

proc callReal*(ctx: var ReadContext) {.raises: [].} =
  ctx.result = realRead(ctx.fd, ctx.buf, ctx.count)

proc callReal*(ctx: var WriteContext) {.raises: [].} =
  ctx.result = realWrite(ctx.fd, ctx.buf, ctx.count)

proc callReal*(ctx: var StatContext) {.raises: [].} =
  case ctx.symbol
  of lhsLstat:
    ctx.result = realLstat(ctx.path, ctx.buf)
  else:
    ctx.result = realStat(ctx.path, ctx.buf)

proc callReal*(ctx: var OpendirContext) {.raises: [].} =
  ctx.result = realOpendir(ctx.path)

proc callReal*(ctx: var ReaddirContext) {.raises: [].} =
  ctx.result = realReaddir(ctx.dirp)

proc callReal*(ctx: var ClosedirContext) {.raises: [].} =
  ctx.result = realClosedir(ctx.dirp)

proc callReal*(ctx: var ForkContext) {.raises: [].} =
  ctx.result = realFork()

proc callReal*(ctx: var ExecveContext) {.raises: [].} =
  ctx.result = realExecve(ctx.path, ctx.argv, ctx.envp)

proc callReal*(ctx: var PosixSpawnContext) {.raises: [].} =
  case ctx.symbol
  of lhsPosixSpawnp:
    ctx.result = realPosixSpawnp(ctx.pid, ctx.path, ctx.fileActions,
                                 ctx.attrp, ctx.argv, ctx.envp)
  else:
    ctx.result = realPosixSpawn(ctx.pid, ctx.path, ctx.fileActions,
                                ctx.attrp, ctx.argv, ctx.envp)

proc callNext*(ctx: var OpenContext) {.raises: [].} =
  case ctx.symbol
  of lhsOpen64:
    if ctx.nextIndex < open64Hooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      open64Hooks[index].callback(ctx)
    else:
      callReal(ctx)
  else:
    if ctx.nextIndex < openHooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      openHooks[index].callback(ctx)
    else:
      callReal(ctx)

proc callNext*(ctx: var OpenatContext) {.raises: [].} =
  case ctx.symbol
  of lhsOpenat64:
    if ctx.nextIndex < openat64Hooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      openat64Hooks[index].callback(ctx)
    else:
      callReal(ctx)
  else:
    if ctx.nextIndex < openatHooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      openatHooks[index].callback(ctx)
    else:
      callReal(ctx)

proc callNext*(ctx: var CloseContext) {.raises: [].} =
  if ctx.nextIndex < closeHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    closeHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var ReadContext) {.raises: [].} =
  if ctx.nextIndex < readHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    readHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var WriteContext) {.raises: [].} =
  if ctx.nextIndex < writeHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    writeHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var StatContext) {.raises: [].} =
  case ctx.symbol
  of lhsLstat:
    if ctx.nextIndex < lstatHooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      lstatHooks[index].callback(ctx)
    else:
      callReal(ctx)
  else:
    if ctx.nextIndex < statHooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      statHooks[index].callback(ctx)
    else:
      callReal(ctx)

proc callNext*(ctx: var OpendirContext) {.raises: [].} =
  if ctx.nextIndex < opendirHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    opendirHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var ReaddirContext) {.raises: [].} =
  if ctx.nextIndex < readdirHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    readdirHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var ClosedirContext) {.raises: [].} =
  if ctx.nextIndex < closedirHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    closedirHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var ForkContext) {.raises: [].} =
  if ctx.nextIndex < forkHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    forkHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var ExecveContext) {.raises: [].} =
  if ctx.nextIndex < execveHooks.len:
    let index = ctx.nextIndex
    inc ctx.nextIndex
    execveHooks[index].callback(ctx)
  else:
    callReal(ctx)

proc callNext*(ctx: var PosixSpawnContext) {.raises: [].} =
  case ctx.symbol
  of lhsPosixSpawnp:
    if ctx.nextIndex < posixSpawnpHooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      posixSpawnpHooks[index].callback(ctx)
    else:
      callReal(ctx)
  else:
    if ctx.nextIndex < posixSpawnHooks.len:
      let index = ctx.nextIndex
      inc ctx.nextIndex
      posixSpawnHooks[index].callback(ctx)
    else:
      callReal(ctx)

proc dispatchOpen(path: cstring; flags, mode: cint): cint {.cdecl, raises: [].} =
  var ctx = OpenContext(path: path, flags: flags, mode: mode, result: -1,
                        symbol: lhsOpen)
  callNext(ctx)
  result = ctx.result

proc dispatchOpen64(path: cstring; flags, mode: cint): cint {.cdecl, raises: [].} =
  var ctx = OpenContext(path: path, flags: flags, mode: mode, result: -1,
                        symbol: lhsOpen64)
  callNext(ctx)
  result = ctx.result

proc dispatchOpenat(dirfd: cint; path: cstring; flags, mode: cint): cint
    {.cdecl, raises: [].} =
  var ctx = OpenatContext(dirfd: dirfd, path: path, flags: flags, mode: mode,
                          result: -1, symbol: lhsOpenat)
  callNext(ctx)
  result = ctx.result

proc dispatchOpenat64(dirfd: cint; path: cstring; flags, mode: cint): cint
    {.cdecl, raises: [].} =
  var ctx = OpenatContext(dirfd: dirfd, path: path, flags: flags, mode: mode,
                          result: -1, symbol: lhsOpenat64)
  callNext(ctx)
  result = ctx.result

proc dispatchClose(fd: cint): cint {.cdecl, raises: [].} =
  var ctx = CloseContext(fd: fd, result: -1)
  callNext(ctx)
  result = ctx.result

proc dispatchRead(fd: cint; buf: pointer; count: csize_t): clong
    {.cdecl, raises: [].} =
  var ctx = ReadContext(fd: fd, buf: buf, count: count, result: -1)
  callNext(ctx)
  result = ctx.result

proc dispatchWrite(fd: cint; buf: pointer; count: csize_t): clong
    {.cdecl, raises: [].} =
  var ctx = WriteContext(fd: fd, buf: buf, count: count, result: -1)
  callNext(ctx)
  result = ctx.result

proc dispatchStat(path: cstring; buf: pointer): cint {.cdecl, raises: [].} =
  var ctx = StatContext(path: path, buf: buf, result: -1, symbol: lhsStat)
  callNext(ctx)
  result = ctx.result

proc dispatchLstat(path: cstring; buf: pointer): cint {.cdecl, raises: [].} =
  var ctx = StatContext(path: path, buf: buf, result: -1, symbol: lhsLstat)
  callNext(ctx)
  result = ctx.result

proc dispatchOpendir(path: cstring): pointer {.cdecl, raises: [].} =
  var ctx = OpendirContext(path: path, result: nil)
  callNext(ctx)
  result = ctx.result

proc dispatchReaddir(dirp: pointer): pointer {.cdecl, raises: [].} =
  var ctx = ReaddirContext(dirp: dirp, result: nil)
  callNext(ctx)
  result = ctx.result

proc dispatchClosedir(dirp: pointer): cint {.cdecl, raises: [].} =
  var ctx = ClosedirContext(dirp: dirp, result: -1)
  callNext(ctx)
  result = ctx.result

proc dispatchFork(): PidT {.cdecl, raises: [].} =
  var ctx = ForkContext(result: -1)
  callNext(ctx)
  result = ctx.result

proc dispatchExecve(path: cstring; argv, envp: cstringArray): cint
    {.cdecl, raises: [].} =
  var ctx = ExecveContext(path: path, argv: argv, envp: envp, result: -1)
  callNext(ctx)
  result = ctx.result

proc dispatchPosixSpawn(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
                        argv, envp: cstringArray): cint {.cdecl, raises: [].} =
  var ctx = PosixSpawnContext(pid: pid, path: path, fileActions: fileActions,
                              attrp: attrp, argv: argv, envp: envp, result: -1,
                              symbol: lhsPosixSpawn)
  callNext(ctx)
  result = ctx.result

proc dispatchPosixSpawnp(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
                         argv, envp: cstringArray): cint {.cdecl, raises: [].} =
  var ctx = PosixSpawnContext(pid: pid, path: path, fileActions: fileActions,
                              attrp: attrp, argv: argv, envp: envp, result: -1,
                              symbol: lhsPosixSpawnp)
  callNext(ctx)
  result = ctx.result

installOpenDispatcher(dispatchOpen)
installOpen64Dispatcher(dispatchOpen64)
installOpenatDispatcher(dispatchOpenat)
installOpenat64Dispatcher(dispatchOpenat64)
installCloseDispatcher(dispatchClose)
installReadDispatcher(dispatchRead)
installWriteDispatcher(dispatchWrite)
installStatDispatcher(dispatchStat)
installLstatDispatcher(dispatchLstat)
installOpendirDispatcher(dispatchOpendir)
installReaddirDispatcher(dispatchReaddir)
installClosedirDispatcher(dispatchClosedir)
installForkDispatcher(dispatchFork)
installExecveDispatcher(dispatchExecve)
installPosixSpawnDispatcher(dispatchPosixSpawn)
installPosixSpawnpDispatcher(dispatchPosixSpawnp)
