## The provider's private protocol channel (Low-Level-Provider-Protocol.md
## §2.2, "Launch / serve contract").
##
## Provider side of the session transport: take the protocol off fd 0 / fd 1
## before any recipe code runs.
##
## The engine starts a provider with ``--repro-provider-serve`` and talks to it
## over the child's stdin and stdout (Low-Level-Provider-Protocol.md §2.2).
## The provider also runs recipe code -- module top-level statements, the
## ``build:`` bodies of the startup pass, and every process those bodies start
## -- and all of it writes to fd 1 and may read fd 0. A single ``echo`` placed
## in the frame stream is decoded as a frame length.
##
## So, when the serve flag is present, this moves the two pipe ends to new
## descriptors that nothing else knows about, and then points fd 1 at the
## provider's stderr and fd 0 at the null device:
##
##   protocol in  := dup(0)   close-on-exec / not inheritable
##   protocol out := dup(1)   close-on-exec / not inheritable
##   fd 1         := fd 2     (recipe stdout joins the provider's stderr)
##   fd 0         := null device (recipe stdin reads end-of-file)
##
## The new descriptors are not inherited, so a child process a recipe starts
## can neither write into the stream nor hold the pipe open after the
## provider exits (which would hide the provider's exit from the engine).
## Any other descriptor the provider inherited that refers to the same two
## pipes is made close-on-exec too: Nim's ``osproc``, which the engine
## launches providers with, leaves its original pipe descriptors open in the
## child, beside the copies it placed on fd 0, 1 and 2.
##
## It runs from a C constructor, so it precedes every Nim module initializer,
## including those of modules a recipe imports ahead of the DSL. Nim module
## initialization calls it again (the fallback for a toolchain without
## constructors). It is idempotent within a process: when a provider is
## built against the shared DSL runtime library, both the executable and the
## library carry a copy of this code, and the second copy adopts the
## descriptors the first one recorded in REPRO_PROVIDER_PROTOCOL_CHANNEL
## (``<pid>:<in>:<out>``). The pid makes the record meaningless in a child
## process, which inherits the environment but not the descriptors.
##
## The C half is emitted from this module rather than kept in a separate
## ``.c`` file so that it is part of the reprobuild library source set that
## keys every provider build (``reproLibSourceFingerprint`` hashes the
## ``.nim`` sources): an edit to it must rebuild cached providers, which a
## ``{.compile.}``-d file would not do. The emitted C must stay free of
## backticks, which ``emit`` reserves for Nim symbol interpolation.
##
## This module hands the serve loop streams over the private descriptors.
## Only a provider binary (``-d:reproProviderMode``) carries the C half. The
## engine imports this module through ``repro_provider_runtime`` and gets
## nothing: an engine must never rearrange its own stdio.

import std/[os, streams]

when defined(reproProviderMode):
  {.emit: """/*INCLUDESECTION*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <windows.h>
#  include <fcntl.h>
#  include <io.h>
#  include <process.h>
#else
#  include <fcntl.h>
#  include <unistd.h>
#  include <dirent.h>
#  include <sys/stat.h>
#  include <sys/resource.h>
#endif
""".}

  {.emit: """
#define REPRO_SERVE_FLAG "--repro-provider-serve"
#define REPRO_CHANNEL_ENV "REPRO_PROVIDER_PROTOCOL_CHANNEL"

/* 0: not attempted (or not serving), 1: established, -1: failed. */
static int repro_channel_state = 0;
static int repro_channel_in = -1;
static int repro_channel_out = -1;
static char repro_channel_error[256];

static long repro_channel_pid(void) {
#if defined(_WIN32)
  return (long)_getpid();
#else
  return (long)getpid();
#endif
}

static void repro_channel_fail(const char *what) {
  snprintf(repro_channel_error, sizeof(repro_channel_error),
           "cannot move the provider protocol off stdio: %s", what);
  repro_channel_state = -1;
}

/* A copy of fd above the standard descriptors that no child inherits. */
static int repro_channel_move(int fd) {
#if defined(_WIN32)
  int copy = _dup(fd);
  if (copy < 0) return -1;
  HANDLE handle = (HANDLE)_get_osfhandle(copy);
  if (handle == INVALID_HANDLE_VALUE ||
      !SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0)) {
    _close(copy);
    return -1;
  }
  _setmode(copy, _O_BINARY);
  return copy;
#else
  return fcntl(fd, F_DUPFD_CLOEXEC, 3);
#endif
}

static int repro_channel_redirect(int from, int to) {
#if defined(_WIN32)
  if (_dup2(from, to) != 0) return -1;
  /* Processes started through CreateProcess take their standard handles
     from GetStdHandle, not from the C runtime's descriptor table. */
  DWORD which = to == 0 ? STD_INPUT_HANDLE : STD_OUTPUT_HANDLE;
  SetStdHandle(which, (HANDLE)_get_osfhandle(to));
  return 0;
#else
  return dup2(from, to) < 0 ? -1 : 0;
#endif
}

static int repro_channel_open_null(void) {
#if defined(_WIN32)
  return _open("NUL", _O_RDWR | _O_BINARY);
#else
  return open("/dev/null", O_RDWR | O_CLOEXEC);
#endif
}

static int repro_channel_adopt(void) {
  const char *record = getenv(REPRO_CHANNEL_ENV);
  long pid = 0;
  int in = -1, out = -1;
  if (record != NULL && sscanf(record, "%ld:%d:%d", &pid, &in, &out) == 3 &&
      pid == repro_channel_pid() && in >= 0 && out >= 0) {
    repro_channel_in = in;
    repro_channel_out = out;
    repro_channel_state = 1;
    return 1;
  }
  return 0;
}

#if !defined(_WIN32)
/* Mark close-on-exec every descriptor other than keep_in and keep_out that
   refers to the same pipe as one of them. A launcher may leave extra copies
   of the pipe ends it attached as fd 0 and fd 1: Nim's osproc, for one,
   dup2()s its pipe ends onto 0, 1 and 2 in the child and never closes the
   originals, which are not close-on-exec either. Every process a recipe
   starts would inherit those copies, so a child that outlives the provider
   would hold the engine's end of the stream open and hide the provider's
   exit. Called after the private copies exist and before fd 0 / fd 1 are
   redirected, so the originals are still there to compare with. */
static void repro_channel_seal_copies(int keep_in, int keep_out) {
  struct stat in_st, out_st;
  if (fstat(keep_in, &in_st) != 0 || fstat(keep_out, &out_st) != 0) return;
  int lo = 3;
  int dir_fd = -1;
  DIR *dir = opendir("/proc/self/fd");
  if (dir == NULL) dir = opendir("/dev/fd");
  if (dir != NULL) dir_fd = dirfd(dir);
  struct rlimit lim;
  long hi = 1024;
  if (dir == NULL && getrlimit(RLIMIT_NOFILE, &lim) == 0 &&
      lim.rlim_cur != RLIM_INFINITY && (long)lim.rlim_cur < 65536)
    hi = (long)lim.rlim_cur;
  for (long next = lo;;) {
    int fd;
    if (dir != NULL) {
      struct dirent *entry = readdir(dir);
      if (entry == NULL) break;
      char *end = NULL;
      long value = strtol(entry->d_name, &end, 10);
      if (end == entry->d_name || *end != 0) continue;
      fd = (int)value;
    } else {
      if (next >= hi) break;
      fd = (int)next++;
    }
    if (fd < lo || fd == keep_in || fd == keep_out || fd == dir_fd) continue;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISFIFO(st.st_mode)) continue;
    if ((st.st_dev == in_st.st_dev && st.st_ino == in_st.st_ino) ||
        (st.st_dev == out_st.st_dev && st.st_ino == out_st.st_ino)) {
      int flags = fcntl(fd, F_GETFD);
      if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    }
  }
  if (dir != NULL) closedir(dir);
}
#endif

int reproProviderProtocolChannelEstablish(int argc, char **argv) {
  if (repro_channel_state != 0) return repro_channel_state;
  if (repro_channel_adopt()) return 1;
  int serving = 0;
  for (int i = 1; argv != NULL && i < argc; ++i) {
    if (argv[i] != NULL && strcmp(argv[i], REPRO_SERVE_FLAG) == 0) {
      serving = 1;
      break;
    }
  }
  if (!serving) return 0;

  fflush(stdout);
  int in = repro_channel_move(0);
  if (in < 0) { repro_channel_fail("dup of fd 0 failed"); return -1; }
  int out = repro_channel_move(1);
  if (out < 0) { repro_channel_fail("dup of fd 1 failed"); return -1; }
#if !defined(_WIN32)
  repro_channel_seal_copies(in, out);
#endif

  int nul = repro_channel_open_null();
  if (nul < 0) { repro_channel_fail("cannot open the null device"); return -1; }
  if (repro_channel_redirect(nul, 0) != 0) {
    repro_channel_fail("cannot point fd 0 at the null device");
    return -1;
  }
  /* Recipe stdout joins stderr; with no usable stderr it is discarded, which
     is still better than corrupting the stream. */
  if (repro_channel_redirect(2, 1) != 0 &&
      repro_channel_redirect(nul, 1) != 0) {
    repro_channel_fail("cannot point fd 1 away from the protocol pipe");
    return -1;
  }
  if (nul > 2) {
#if defined(_WIN32)
    _close(nul);
#else
    close(nul);
#endif
  }

  char record[64];
  snprintf(record, sizeof(record), "%ld:%d:%d", repro_channel_pid(), in, out);
#if defined(_WIN32)
  _putenv_s(REPRO_CHANNEL_ENV, record);
#else
  setenv(REPRO_CHANNEL_ENV, record, 1);
#endif
  repro_channel_in = in;
  repro_channel_out = out;
  repro_channel_state = 1;
  return 1;
}

int reproProviderProtocolChannelIn(void) { return repro_channel_in; }
int reproProviderProtocolChannelOut(void) { return repro_channel_out; }
char *reproProviderProtocolChannelError(void) {
  return repro_channel_error;
}

/* glibc and dyld pass (argc, argv, envp) to constructors; other C runtimes
   (musl among them) do not, and rely on the Nim module-init fallback. */
#if defined(__GNUC__) && (defined(__GLIBC__) || defined(__APPLE__))
__attribute__((constructor)) static void
repro_channel_constructor(int argc, char **argv, char **envp) {
  (void)envp;
  reproProviderProtocolChannelEstablish(argc, argv);
}
#elif defined(__GNUC__) && defined(_WIN32)
__attribute__((constructor)) static void repro_channel_constructor(void) {
  reproProviderProtocolChannelEstablish(__argc, __argv);
}
#endif
""".}

  proc cEstablish(argc: cint; argv: cstringArray): cint
    {.importc: "reproProviderProtocolChannelEstablish", cdecl.}
  proc cChannelIn(): cint {.importc: "reproProviderProtocolChannelIn", cdecl.}
  proc cChannelOut(): cint {.importc: "reproProviderProtocolChannelOut", cdecl.}
  proc cChannelError(): cstring
    {.importc: "reproProviderProtocolChannelError", cdecl.}

  proc establishProviderProtocolChannel*(): int =
    ## Make sure the channel is set up; returns 1 when it is, 0 when this
    ## process was not started in serve mode, -1 on failure. Idempotent. The
    ## C constructor normally did the work already; this is the fallback for
    ## a C runtime that runs no constructors.
    var args = @[getAppFilename()]
    for i in 1 .. paramCount():
      args.add(paramStr(i))
    let argv = allocCStringArray(args)
    defer: deallocCStringArray(argv)
    int(cEstablish(cint(args.len), argv))

  # Module initialization: the fallback call. Imported (through the DSL) by
  # every recipe module, so it runs before the recipe's own top level.
  discard establishProviderProtocolChannel()

  proc openProviderProtocolStreams*():
      tuple[fromEngine, toEngine: Stream] =
    ## Streams over the private protocol descriptors. Raises ``IOError``
    ## when the channel could not be established; the serve loop must then
    ## refuse to serve rather than fall back to the shared stdio.
    let state = establishProviderProtocolChannel()
    if state != 1:
      let why =
        if state == 0: "the process was not started with the serve flag"
        else: $cChannelError()
      raise newException(IOError,
        "provider protocol channel unavailable: " & why)
    var inFile, outFile: File
    if not open(inFile, FileHandle(cChannelIn()), fmRead):
      raise newException(IOError,
        "provider protocol channel: cannot open the input descriptor")
    if not open(outFile, FileHandle(cChannelOut()), fmWrite):
      raise newException(IOError,
        "provider protocol channel: cannot open the output descriptor")
    (fromEngine: Stream(newFileStream(inFile)),
     toEngine: Stream(newFileStream(outFile)))
