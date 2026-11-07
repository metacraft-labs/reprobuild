## A binary Reprobuild compiles for itself — the per-project provider, the
## interface-extraction runner — must not carry a HOST library directory
## (`/usr/lib`, `/lib64`, ...) in its RPATH.
##
## The defect (reprobuild-pm issue
## 2026-10-14-project-provider-rpath-puts-usr-lib-ahead-of-the-nix-glibc).
## On a distribution host with Nix, reprobuild's own `project-provider` was
## linked with
##
##   RPATH [ ...store libs... : /usr/lib : <nix glibc>/lib : ... ]
##
## and `DT_INTERP` naming the Nix glibc's loader, so it loaded the host's
## `libc.so.6` under the Nix loader and died with SIGSEGV in `libtbb`'s static
## constructor before `main`. No build ran at all.
##
## Two things combined, both specific to the ISOLATED launch environment the
## provider-compile edge runs in (`providerCompileLaunchEnv`: `PATH` is only
## the Nim compiler's and the C compiler's directories, and nothing else of
## the caller's shell is inherited):
##
##   1. `config.nims` located a Nix-store SQLite by shelling out to
##      `find /nix/store ... | sort`. Neither tool is on that `PATH`, the
##      pipeline failed, and the lookup fell through to the distribution's
##      directories — `-L/usr/lib` wherever the host ships `libsqlite3.so`.
##   2. Nix's ld-wrapper adds `-rpath <dir>` for every `-L<dir>` that holds a
##      library the link uses, EXCEPT directories outside `$NIX_STORE` — but
##      with `NIX_STORE` unset that exclusion matches nothing, so `/usr/lib`
##      went into RPATH, ahead of the libc directory the wrapper appends.
##      `config.nims` deliberately never writes a host directory into RPATH;
##      the wrapper did it behind its back. Fixing (1) alone does not close
##      this: the clang driver adds `-L/usr/lib` to every link on a host
##      that has the directory, so the wrapper needs `NIX_STORE` regardless.
##
## Each case compiles a small probe module that links `-lsqlite3` the way
## the provider does: from inside this repository (so the real `config.nims`
## applies, exactly as it does to the provider of reprobuild's own
## `repro.nim`), with the real `providerCompileLaunchEnv` plus the host
## essentials the engine adds for an isolated action, and the C compiler
## flags the provider compile uses (`nimCCompilerFlags`).
##
## What is not the real thing, and why. The last two cases need a host whose
## `/usr/lib` carries `libsqlite3.so`. Build hosts differ — NixOS has no
## `/usr/lib` at all — so the case constructs one: in a private user + mount
## namespace it covers `/usr` with a tmpfs, re-binds every original entry of
## `/usr` except `lib`, and places a copy of the Nix store's `libsqlite3.so`
## in the new `/usr/lib`. Everything else (compiler, linker wrapper,
## `config.nims`, the launch environment) is the real one. The namespace is
## set up with raw syscalls from this process rather than with
## `unshare`/`mount` binaries, because on a distribution host those binaries
## are linked against the very `/usr/lib` the case replaces.
##
## Linux-only: the defect is the ELF RPATH written by Nix's GNU-ld wrapper.
## Unprivileged user namespaces are REQUIRED on Linux; a host without them
## fails the last two cases with a message saying so rather than skipping
## them.

import std/[os, osproc, posix, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_interface_artifacts
import repro_build_engine
import repro_core/c_compiler
import repro_core/nix_store_roots
import repro_launch_plan/elf

proc reproRoot(): string =
  ## The repository root that owns `config.nims`, found from this file.
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "config.nims") and
        dirExists(dir / "libs" / "repro_interface_artifacts"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError, "reprobuild root not found above " &
    currentSourcePath())

proc valueIn(env: openArray[string]; name: string): string =
  for entry in env:
    if entry.startsWith(name & "="):
      return entry[name.len + 1 .. ^1]
  ""

proc isHostLibDir(dir: string): bool =
  ## A directory of the host distribution rather than of a store or a
  ## prefix somebody named — the class `config.nims` never puts in RPATH.
  let d = dir.strip()
  d == "/usr" or d.startsWith("/usr/") or d == "/lib" or
    d.startsWith("/lib/") or d == "/lib64" or d.startsWith("/lib64/")

proc storeSqliteLib(): string =
  ## A `libsqlite3.so` in the Nix store, for the fake host `/usr/lib`.
  let store = nixStoreDir()
  for kind, path in walkDir(store):
    if kind == pcDir and "-sqlite-" in extractFilename(path):
      let lib = path / "lib" / "libsqlite3.so"
      if fileExists(lib):
        return lib
  ""

type Probe = object
  root: string        ## temp dir inside the repository
  module: string
  output: string
  nimcache: string
  home: string
  env: seq[string]    ## the provider-compile launch environment
  command: seq[string]

proc newProbe(): Probe =
  let repo = reproRoot()
  createDir(repo / "build")
  result.root = createTempDir("provider-rpath-probe-", "", repo / "build")
  result.module = result.root / "probe.nim"
  result.output = result.root / "probe"
  result.nimcache = result.root / "nimcache"
  result.home = result.root / "home"
  # Uses a SQLite symbol so the link really needs `-lsqlite3`, as the
  # provider's lock/cas stores do.
  writeFile(result.module, """
{.passL: "-lsqlite3".}
proc sqlite3_libversion(): cstring {.importc, cdecl.}
echo sqlite3_libversion()
""")
  # The engine composes an isolated action's environment as the host
  # essentials, then the action's declared values (repro_build_engine,
  # `preparedActionEnv`). Nothing else of this process reaches it.
  for name in HostEssentialEnvNames:
    if existsEnv(name):
      result.env.add(name & "=" & getEnv(name))
  result.env.add(providerCompileLaunchEnv(result.home))
  let nim = valueIn(result.env, "REPRO_NIM_COMPILER")
  let cc = valueIn(result.env, bootstrapCCompilerEnv)
  doAssert nim.len > 0, "providerCompileLaunchEnv resolved no Nim compiler"
  doAssert cc.len > 0, "providerCompileLaunchEnv resolved no C compiler"
  result.command = @[nim, "c", "--hints:off", "--warnings:off",
    "--nimcache:" & result.nimcache, "--out:" & result.output]
  result.command.add(nimCCompilerFlags(cc))
  result.command.add(result.module)

proc envTable(env: openArray[string]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for entry in env:
    let eq = entry.find('=')
    if eq > 0:
      result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

proc compile(p: Probe): tuple[output: string, exitCode: int] =
  let process = startProcess(p.command[0], workingDir = p.root,
    args = p.command[1 .. ^1], env = envTable(p.env),
    options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  (output, exitCode)

proc runpathEntries(binary: string): seq[string] =
  let view = parseElf(cast[seq[byte]](readFile(binary)))
  for entry in view.readRunpath().split(':'):
    if entry.len > 0:
      result.add(entry)

proc linkCommand(p: Probe): string =
  ## The link line Nim ran, from its build manifest.
  let manifest = p.nimcache / "probe.json"
  if fileExists(manifest): readFile(manifest) else: ""

# --- the fake-host namespace --------------------------------------------

const
  CLONE_NEWNS = 0x00020000.cint
  CLONE_NEWUSER = 0x10000000.cint
  MS_BIND = 4096.culong
  MS_REC = 16384.culong
  MS_PRIVATE = (1 shl 18).culong

proc c_unshare(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
proc c_mount(source, target, fstype: cstring; flags: culong;
             data: pointer): cint {.importc: "mount",
                                    header: "<sys/mount.h>".}

proc childFail(log: cint; what: string) =
  let msg = "namespace setup failed: " & what & ": " &
    $strerror(errno) & "\n"
  discard posix.write(log, msg.cstring, msg.len)
  exitnow(97)

proc compileUnderFakeHostUsrLib(p: Probe; sqliteLib: string):
    tuple[output: string, exitCode: int] =
  ## Run the probe compile in a private user + mount namespace whose `/usr`
  ## is the host's, except that `/usr/lib` holds only `libsqlite3.so`.
  ## Exit code 97 means the namespace could not be built.
  let logPath = p.root / "compile.log"
  let stage = p.root / "orig-usr"
  createDir(stage)
  # Everything the child needs is prepared before `fork`, so the child only
  # makes syscalls.
  var origEntries: seq[tuple[name, symlinkTo: string, isDir: bool]] = @[]
  for kind, path in walkDir("/usr"):
    let name = extractFilename(path)
    if name == "lib":
      continue
    if kind in {pcLinkToDir, pcLinkToFile}:
      # Recreated as the same link (`lib64 -> lib` must reach the fake lib).
      origEntries.add((name, expandSymlink(path), false))
    else:
      origEntries.add((name, "", kind == pcDir))
  let uidMap = "0 " & $getuid() & " 1"
  let gidMap = "0 " & $getgid() & " 1"
  var argv = allocCStringArray(p.command)
  var envp = allocCStringArray(p.env)
  let pid = fork()
  if pid == 0:
    let log = posix.open(logPath.cstring, O_WRONLY or O_CREAT or O_TRUNC,
      0o644.Mode)
    if c_unshare(CLONE_NEWUSER or CLONE_NEWNS) != 0:
      childFail(log, "unshare(CLONE_NEWUSER|CLONE_NEWNS) — unprivileged " &
        "user namespaces are required by this test")
    try:
      writeFile("/proc/self/setgroups", "deny")
      writeFile("/proc/self/uid_map", uidMap)
      writeFile("/proc/self/gid_map", gidMap)
    except IOError:
      childFail(log, "writing the id maps")
    if c_mount(nil, "/", nil, MS_REC or MS_PRIVATE, nil) != 0:
      childFail(log, "making / private")
    if c_mount("/usr", stage.cstring, nil, MS_BIND or MS_REC, nil) != 0:
      childFail(log, "binding the original /usr aside")
    if c_mount("tmpfs", "/usr", "tmpfs", 0, nil) != 0:
      childFail(log, "covering /usr with a tmpfs")
    try:
      for entry in origEntries:
        let target = "/usr" / entry.name
        if entry.symlinkTo.len > 0:
          createSymlink(entry.symlinkTo, target)
          continue
        if entry.isDir: createDir(target)
        else: writeFile(target, "")
        if c_mount(cstring(stage / entry.name), target.cstring, nil,
            MS_BIND or MS_REC, nil) != 0:
          childFail(log, "re-binding /usr/" & entry.name)
      createDir("/usr/lib")
      copyFile(sqliteLib, "/usr/lib/libsqlite3.so")
    except OSError, IOError:
      childFail(log, "building the fake /usr/lib")
    discard dup2(log, 1)
    discard dup2(log, 2)
    if chdir(p.root.cstring) != 0:
      childFail(log, "chdir")
    discard execve(argv[0], argv, envp)
    childFail(log, "execve " & p.command[0])
  deallocCStringArray(argv)
  deallocCStringArray(envp)
  doAssert pid > 0, "fork failed"
  var status: cint
  discard waitpid(pid, status, 0)
  let exitCode = if WIFEXITED(status): int(WEXITSTATUS(status)) else: -1
  let log = if fileExists(logPath): readFile(logPath) else: ""
  (log, exitCode)

suite "a provider link never puts a host library directory in RPATH":

  test "the launch environment names the Nix store for a Nix C compiler":
    when not defined(linux):
      skip("the RPATH contract is the ELF one of Nix's GNU-ld wrapper")
    else:
      let p = newProbe()
      defer: removeDir(p.root)
      let cc = valueIn(p.env, bootstrapCCompilerEnv)
      let store = nixStoreDir()
      if cc.startsWith(store & "/") or
          expandFilename(cc).startsWith(store & "/"):
        # Without it the wrapper's "outside the store" test matches nothing
        # and every `-L` directory with a used library becomes RPATH.
        check valueIn(p.env, "NIX_STORE") == store
      else:
        check valueIn(p.env, "NIX_STORE") == ""

  test "config.nims finds the store SQLite with only the launch PATH":
    when not defined(linux):
      skip("the RPATH contract is the ELF one of Nix's GNU-ld wrapper")
    else:
      let p = newProbe()
      defer: removeDir(p.root)
      require storeSqliteLib().len > 0
      let (output, exitCode) = p.compile()
      checkpoint "compile output:\n" & output
      check exitCode == 0
      # The `-L` config.nims emitted must name a store SQLite: a lookup that
      # fails under the launch PATH falls through to the host's directories.
      let link = p.linkCommand()
      checkpoint "link command:\n" & link
      var storeSqliteDir = false
      for token in link.splitWhitespace():
        let t = token.strip(chars = {'"', ','})
        if t.startsWith("-L" & nixStoreDir() & "/") and
            fileExists(t[2 .. ^1] / "libsqlite3.so"):
          storeSqliteDir = true
      check storeSqliteDir
      if exitCode == 0:
        for entry in runpathEntries(p.output):
          checkpoint "RPATH entry: " & entry
          check not isHostLibDir(entry)

  test "a host /usr/lib holding libsqlite3 stays out of RPATH":
    when not defined(linux):
      skip("the RPATH contract is the ELF one of Nix's GNU-ld wrapper")
    else:
      let p = newProbe()
      defer: removeDir(p.root)
      let sqliteLib = storeSqliteLib()
      require sqliteLib.len > 0
      let (output, exitCode) = p.compileUnderFakeHostUsrLib(sqliteLib)
      checkpoint "compile output:\n" & output
      require exitCode != 97   # the namespace itself could not be built
      check exitCode == 0
      if exitCode == 0:
        let entries = runpathEntries(p.output)
        checkpoint "RPATH: " & entries.join(":")
        for entry in entries:
          check not isHostLibDir(entry)

  test "an explicit -L of the host /usr/lib still stays out of RPATH":
    # In the previous case `/usr/lib` reaches the link line only if the C
    # driver adds it, which clang does and a GCC wrapper need not. This one
    # puts it there explicitly, the way any host fallback would, so it holds
    # with any driver only while the launch environment tells the ld-wrapper
    # where the store is (`NIX_STORE`): the wrapper writes an RPATH entry for every `-L`
    # directory holding a library the link names, even one an earlier
    # directory already supplied, unless that directory is outside the store.
    when not defined(linux):
      skip("the RPATH contract is the ELF one of Nix's GNU-ld wrapper")
    else:
      var p = newProbe()
      defer: removeDir(p.root)
      let sqliteLib = storeSqliteLib()
      require sqliteLib.len > 0
      p.command.insert("--passL:-L/usr/lib", p.command.len - 1)
      let (output, exitCode) = p.compileUnderFakeHostUsrLib(sqliteLib)
      checkpoint "compile output:\n" & output
      require exitCode != 97   # the namespace itself could not be built
      check exitCode == 0
      if exitCode == 0:
        let entries = runpathEntries(p.output)
        checkpoint "RPATH: " & entries.join(":")
        for entry in entries:
          check not isHostLibDir(entry)
