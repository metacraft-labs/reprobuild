when not defined(macosx):
  {.error: "repro_monitor_hooks/macos_interpose_runtime is macOS-only".}

import std/os
import stackable_hooks/propagation as ct_propagation

# Bridge from C-level spawn hooks back into ct_interpose's SIP-rewrite
# helper. On macOS, /bin/, /sbin/, /usr/bin/, /usr/sbin/ are SIP-protected,
# so DYLD_INSERT_LIBRARIES is stripped when those binaries are exec'd. The
# helper consults CT_SANDBOX_TOOLS_DIR (populated by repro-fs-snoop) and, if
# a sandbox copy of the requested binary exists, returns its path instead.
#
# We can't reuse ct_interpose's private static C symbol _ct_rewrite_sip_path
# directly (it depends on private state), so we expose the Nim helper to C
# via an exportc shim. The returned cstring points into a per-thread Nim
# string that lives until the next call from the same thread — the spawn
# hook consumes it immediately, so the lifetime is sufficient.
var sipRewriteBuf {.threadvar.}: string

proc repro_macos_rewrite_sip_path*(path: cstring): cstring
    {.exportc: "repro_macos_rewrite_sip_path", cdecl.} =
  if path == nil:
    return path
  let original = $path
  let rewritten = ct_propagation.rewriteExecPathForSip(original)
  if rewritten == original:
    return path
  sipRewriteBuf = rewritten
  result = cstring(sipRewriteBuf)

var sandboxDirBuf {.threadvar.}: string

proc repro_macos_get_sandbox_tools_dir*(): cstring
    {.exportc: "repro_macos_get_sandbox_tools_dir", cdecl.} =
  ## Returns the active CT_SANDBOX_TOOLS_DIR (or the propagation default)
  ## so the C-level env builder can propagate it to the child env. Returns
  ## nil if the env var is unset and we should not synthesise one.
  let envDir = getEnv("CT_SANDBOX_TOOLS_DIR")
  if envDir.len == 0:
    return nil
  sandboxDirBuf = envDir
  result = cstring(sandboxDirBuf)

{.emit: """
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

extern char **environ;
extern char *repro_macos_rewrite_sip_path(char *path);
extern char *repro_macos_get_sandbox_tools_dir(void);

int repro_macos_real_open_syscall(char *path, int flags, int mode) {
  return (int)syscall(SYS_open, path, flags, mode);
}

int repro_macos_real_openat_syscall(int dirfd, char *path, int flags, int mode) {
  return (int)syscall(SYS_openat, dirfd, path, flags, mode);
}

ssize_t repro_macos_real_read_syscall(int fd, void *buf, size_t count) {
  return (ssize_t)syscall(SYS_read, fd, buf, count);
}

ssize_t repro_macos_real_write_syscall(int fd, void *buf, size_t count) {
  return (ssize_t)syscall(SYS_write, fd, buf, count);
}

int repro_macos_real_close_syscall(int fd) {
  return (int)syscall(SYS_close, fd);
}

int repro_macos_path_is_dir(char *path) {
  struct stat st;
#ifdef SYS_stat64
  if (syscall(SYS_stat64, path, &st) != 0) return 0;
#else
  if (syscall(SYS_stat, path, &st) != 0) return 0;
#endif
  return S_ISDIR(st.st_mode) ? 1 : 0;
}

static int repro_macos_env_has(char **envp, const char *name) {
  if (!envp) envp = environ;
  size_t name_len = strlen(name);
  for (char **env = envp; env && *env; env++) {
    if (strncmp(*env, name, name_len) == 0 && (*env)[name_len] == '=') {
      return 1;
    }
  }
  return 0;
}

static char **repro_macos_env_with_preload(char **envp) {
  const char *shim = getenv("REPRO_MONITOR_SHIM_LIB");
  char *sandbox_dir = repro_macos_get_sandbox_tools_dir();
  int need_dyld = shim && shim[0] != '\0' &&
    !repro_macos_env_has(envp, "DYLD_INSERT_LIBRARIES");
  int need_sandbox = sandbox_dir && sandbox_dir[0] != '\0' &&
    !repro_macos_env_has(envp, "CT_SANDBOX_TOOLS_DIR");
  if (!need_dyld && !need_sandbox) return envp;

  char **source = envp ? envp : environ;
  size_t count = 0;
  while (source && source[count]) count++;

  size_t extras = (need_dyld ? 1u : 0u) + (need_sandbox ? 1u : 0u);
  char **result = (char **)calloc(count + extras + 1, sizeof(char *));
  if (!result) return envp;
  for (size_t i = 0; i < count; i++) result[i] = source[i];

  size_t slot = count;
  if (need_dyld) {
    const char *prefix = "DYLD_INSERT_LIBRARIES=";
    size_t value_len = strlen(prefix) + strlen(shim) + 1;
    char *value = (char *)malloc(value_len);
    if (!value) { free(result); return envp; }
    snprintf(value, value_len, "%s%s", prefix, shim);
    result[slot++] = value;
  }
  if (need_sandbox) {
    const char *prefix = "CT_SANDBOX_TOOLS_DIR=";
    size_t value_len = strlen(prefix) + strlen(sandbox_dir) + 1;
    char *value = (char *)malloc(value_len);
    if (!value) { free(result); return envp; }
    snprintf(value, value_len, "%s%s", prefix, sandbox_dir);
    result[slot++] = value;
  }
  result[slot] = NULL;
  return result;
}

int repro_macos_real_execve_syscall(char *path, char **argv, char **envp) {
  char **effective_envp = repro_macos_env_with_preload(envp);
  char *effective_path = repro_macos_rewrite_sip_path(path);
  return (int)syscall(SYS_execve, effective_path, argv, effective_envp);
}

typedef int (*repro_macos_posix_spawn_fn)(pid_t *, const char *,
  const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
  char *const [], char *const []);
typedef DIR *(*repro_macos_opendir_fn)(const char *);
typedef struct dirent *(*repro_macos_readdir_fn)(DIR *);
typedef int (*repro_macos_closedir_fn)(DIR *);
typedef int (*repro_macos_stat_fn)(const char *, struct stat *);
typedef pid_t (*repro_macos_fork_fn)(void);

static repro_macos_posix_spawn_fn repro_macos_real_posix_spawn_ptr = NULL;
static repro_macos_posix_spawn_fn repro_macos_real_posix_spawnp_ptr = NULL;
static repro_macos_opendir_fn repro_macos_real_opendir_ptr = NULL;
static repro_macos_readdir_fn repro_macos_real_readdir_ptr = NULL;
static repro_macos_closedir_fn repro_macos_real_closedir_ptr = NULL;
static repro_macos_stat_fn repro_macos_real_stat_ptr = NULL;
static repro_macos_stat_fn repro_macos_real_lstat_ptr = NULL;
static repro_macos_fork_fn repro_macos_real_fork_ptr = NULL;

static void *repro_macos_lookup_image_symbol(const char *symbol) {
  uint32_t count = _dyld_image_count();
  for (uint32_t i = 0; i < count; i++) {
    const struct mach_header *header = _dyld_get_image_header(i);
    if (header == NULL) continue;
    NSSymbol sym = NSLookupSymbolInImage(header, symbol,
      NSLOOKUPSYMBOLINIMAGE_OPTION_BIND |
      NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR);
    if (sym) {
      void *ptr = NSAddressOfSymbol(sym);
      if (ptr) return ptr;
    }
  }
  return NULL;
}

static void repro_macos_resolve_spawn(void) {
  if (repro_macos_real_posix_spawn_ptr && repro_macos_real_posix_spawnp_ptr) return;
  repro_macos_real_posix_spawn_ptr =
    (repro_macos_posix_spawn_fn)repro_macos_lookup_image_symbol("_posix_spawn");
  repro_macos_real_posix_spawnp_ptr =
    (repro_macos_posix_spawn_fn)repro_macos_lookup_image_symbol("_posix_spawnp");
  if (!repro_macos_real_posix_spawn_ptr) {
    repro_macos_real_posix_spawn_ptr =
      (repro_macos_posix_spawn_fn)dlsym(RTLD_DEFAULT, "posix_spawn");
  }
  if (!repro_macos_real_posix_spawnp_ptr) {
    repro_macos_real_posix_spawnp_ptr =
      (repro_macos_posix_spawn_fn)dlsym(RTLD_DEFAULT, "posix_spawnp");
  }
}

static void repro_macos_resolve_dir(void) {
  if (!repro_macos_real_opendir_ptr) {
    repro_macos_real_opendir_ptr =
      (repro_macos_opendir_fn)repro_macos_lookup_image_symbol("_opendir");
  }
  if (!repro_macos_real_readdir_ptr) {
    repro_macos_real_readdir_ptr =
      (repro_macos_readdir_fn)repro_macos_lookup_image_symbol("_readdir");
  }
  if (!repro_macos_real_closedir_ptr) {
    repro_macos_real_closedir_ptr =
      (repro_macos_closedir_fn)repro_macos_lookup_image_symbol("_closedir");
  }
}

static void repro_macos_resolve_stat(void) {
  if (!repro_macos_real_stat_ptr) {
    repro_macos_real_stat_ptr =
      (repro_macos_stat_fn)repro_macos_lookup_image_symbol("_stat");
  }
  if (!repro_macos_real_lstat_ptr) {
    repro_macos_real_lstat_ptr =
      (repro_macos_stat_fn)repro_macos_lookup_image_symbol("_lstat");
  }
  if (!repro_macos_real_stat_ptr) {
    repro_macos_real_stat_ptr = (repro_macos_stat_fn)dlsym(RTLD_DEFAULT, "stat");
  }
  if (!repro_macos_real_lstat_ptr) {
    repro_macos_real_lstat_ptr = (repro_macos_stat_fn)dlsym(RTLD_DEFAULT, "lstat");
  }
}

static void repro_macos_resolve_fork(void) {
  if (!repro_macos_real_fork_ptr) {
    repro_macos_real_fork_ptr =
      (repro_macos_fork_fn)repro_macos_lookup_image_symbol("_fork");
  }
  if (!repro_macos_real_fork_ptr) {
    repro_macos_real_fork_ptr = (repro_macos_fork_fn)dlsym(RTLD_DEFAULT, "fork");
  }
}

void *repro_macos_real_opendir(char *path) {
  repro_macos_resolve_dir();
  if (!repro_macos_real_opendir_ptr) return NULL;
  return repro_macos_real_opendir_ptr(path);
}

void *repro_macos_real_readdir(void *dirp) {
  repro_macos_resolve_dir();
  if (!repro_macos_real_readdir_ptr) return NULL;
  return repro_macos_real_readdir_ptr((DIR *)dirp);
}

int repro_macos_real_closedir(void *dirp) {
  repro_macos_resolve_dir();
  if (!repro_macos_real_closedir_ptr) return -1;
  return repro_macos_real_closedir_ptr((DIR *)dirp);
}

int repro_macos_real_stat(char *path, void *buf) {
  repro_macos_resolve_stat();
  if (!repro_macos_real_stat_ptr) {
    errno = ENOSYS;
    return -1;
  }
  return repro_macos_real_stat_ptr(path, (struct stat *)buf);
}

int repro_macos_real_lstat(char *path, void *buf) {
  repro_macos_resolve_stat();
  if (!repro_macos_real_lstat_ptr) {
    errno = ENOSYS;
    return -1;
  }
  return repro_macos_real_lstat_ptr(path, (struct stat *)buf);
}

pid_t repro_macos_real_fork(void) {
  repro_macos_resolve_fork();
  if (!repro_macos_real_fork_ptr) {
    errno = ENOSYS;
    return -1;
  }
  return repro_macos_real_fork_ptr();
}

int repro_macos_real_posix_spawn(pid_t *pid, char *path, void *file_actions,
                                 void *attrp, char **argv, char **envp) {
  repro_macos_resolve_spawn();
  if (!repro_macos_real_posix_spawn_ptr) return -1;
  char **effective_envp = repro_macos_env_with_preload(envp);
  char *effective_path = repro_macos_rewrite_sip_path(path);
  return repro_macos_real_posix_spawn_ptr(pid, effective_path,
    (const posix_spawn_file_actions_t *)file_actions,
    (const posix_spawnattr_t *)attrp, argv, effective_envp);
}

int repro_macos_real_posix_spawnp(pid_t *pid, char *path, void *file_actions,
                                  void *attrp, char **argv, char **envp) {
  repro_macos_resolve_spawn();
  if (!repro_macos_real_posix_spawnp_ptr) return -1;
  char **effective_envp = repro_macos_env_with_preload(envp);
  char *effective_path = repro_macos_rewrite_sip_path(path);
  return repro_macos_real_posix_spawnp_ptr(pid, effective_path,
    (const posix_spawn_file_actions_t *)file_actions,
    (const posix_spawnattr_t *)attrp, argv, effective_envp);
}
""".}

type
  PidT* = cint

proc ct_macos_interpose_real_open*(path: cstring; flags, mode: cint): cint =
  proc realOpenSyscall(path: cstring; flags, mode: cint): cint
    {.importc: "repro_macos_real_open_syscall", cdecl.}
  realOpenSyscall(path, flags, mode)

proc ct_macos_interpose_real_openat*(dirfd: cint; path: cstring; flags, mode: cint): cint =
  proc realOpenatSyscall(dirfd: cint; path: cstring; flags, mode: cint): cint
    {.importc: "repro_macos_real_openat_syscall", cdecl.}
  realOpenatSyscall(dirfd, path, flags, mode)

proc ct_macos_interpose_real_read*(fd: cint; buf: pointer; count: csize_t): int =
  proc realReadSyscall(fd: cint; buf: pointer; count: csize_t): clong
    {.importc: "repro_macos_real_read_syscall", cdecl.}
  int(realReadSyscall(fd, buf, count))

proc ct_macos_interpose_real_write*(fd: cint; buf: pointer; count: csize_t): int =
  proc realWriteSyscall(fd: cint; buf: pointer; count: csize_t): clong
    {.importc: "repro_macos_real_write_syscall", cdecl.}
  int(realWriteSyscall(fd, buf, count))

proc ct_macos_interpose_real_close*(fd: cint): cint =
  proc realCloseSyscall(fd: cint): cint
    {.importc: "repro_macos_real_close_syscall", cdecl.}
  realCloseSyscall(fd)

proc ct_macos_interpose_real_opendir*(path: cstring): pointer =
  proc realOpendir(path: cstring): pointer
    {.importc: "repro_macos_real_opendir", cdecl.}
  realOpendir(path)

proc ct_macos_interpose_real_readdir*(dirp: pointer): pointer =
  proc realReaddir(dirp: pointer): pointer
    {.importc: "repro_macos_real_readdir", cdecl.}
  realReaddir(dirp)

proc ct_macos_interpose_real_closedir*(dirp: pointer): cint =
  proc realClosedir(dirp: pointer): cint
    {.importc: "repro_macos_real_closedir", cdecl.}
  realClosedir(dirp)

proc ct_macos_interpose_real_stat*(path: cstring; buf: pointer): cint =
  proc realStat(path: cstring; buf: pointer): cint
    {.importc: "repro_macos_real_stat", cdecl.}
  realStat(path, buf)

proc ct_macos_interpose_real_lstat*(path: cstring; buf: pointer): cint =
  proc realLstat(path: cstring; buf: pointer): cint
    {.importc: "repro_macos_real_lstat", cdecl.}
  realLstat(path, buf)

proc ct_macos_interpose_real_fork*(): PidT =
  proc realFork(): PidT {.importc: "repro_macos_real_fork", cdecl.}
  realFork()

proc ct_macos_interpose_real_execve*(path: cstring; argv, envp: cstringArray): cint =
  proc realExecveSyscall(path: cstring; argv, envp: cstringArray): cint
    {.importc: "repro_macos_real_execve_syscall", cdecl.}
  realExecveSyscall(path, argv, envp)

proc ct_macos_interpose_path_is_dir*(path: cstring): bool =
  proc pathIsDir(path: cstring): cint
    {.importc: "repro_macos_path_is_dir", cdecl.}
  path != nil and pathIsDir(path) != 0

proc ct_macos_interpose_real_posix_spawn*(pid: ptr PidT; path: cstring;
    fileActions, attrp: pointer; argv, envp: cstringArray): cint =
  proc realPosixSpawn(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
                      argv, envp: cstringArray): cint
    {.importc: "repro_macos_real_posix_spawn", cdecl.}
  realPosixSpawn(pid, path, fileActions, attrp, argv, envp)

proc ct_macos_interpose_real_posix_spawnp*(pid: ptr PidT; path: cstring;
    fileActions, attrp: pointer; argv, envp: cstringArray): cint =
  proc realPosixSpawnp(pid: ptr PidT; path: cstring; fileActions, attrp: pointer;
                       argv, envp: cstringArray): cint
    {.importc: "repro_macos_real_posix_spawnp", cdecl.}
  realPosixSpawnp(pid, path, fileActions, attrp, argv, envp)
