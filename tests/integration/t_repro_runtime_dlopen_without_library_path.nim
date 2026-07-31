## Regression guard: the bootstrapped ``build/bin/repro`` must resolve every
## library it ``dlopen``s by bare soname *without* inheriting the dev shell's
## ``LD_LIBRARY_PATH``.
##
## Why this gate exists
## --------------------
## ``libs/repro_solver/src/repro_solver/clingo_bindings.nim`` binds clingo
## through ``{.dynlib: "libclingo.so".}``, and Nim executes a ``dynlib`` block
## in the module's ``DatInit`` — i.e. before ``main``. ``scripts/build_apps.sh``
## deliberately clears ``NIX_LDFLAGS`` and ``LD_LIBRARY_PATH`` around every
## ``nim c`` (the ``.rodata``-bake guard: an absolute ``/nix/store/...`` path
## baked into the binary's ``.rodata`` survives the stage-time store relocation
## and breaks the installed system), so the binary carries a *bare soname*
## ``dlopen``. Something else therefore has to make that soname resolvable, and
## the dev shell's ``LD_LIBRARY_PATH`` must not be that something: it is not
## inherited by
##
##   * a ``repro`` invoked on the far side of an SSH transport — ``sshd`` does
##     not propagate ``LD_LIBRARY_PATH`` into a non-interactive session, which
##     is exactly how the M71 remote-apply phases run ``repro home
##     __receive-bundle`` on the target host;
##   * a ``repro`` started by a CI step that is not wrapped in ``nix develop``;
##   * an installed ``repro`` — ``flake.nix`` refuses to inject
##     ``LD_LIBRARY_PATH`` into the installed wrapper on purpose (arbitrary user
##     build actions inherit the wrapper environment) and instead patches the
##     runtime library path into the packaged binaries' RPATH.
##
## ``scripts/build_apps.sh`` closes the gap for the bootstrapped binary by
## threading ``--passL:-Wl,-rpath,<dir>`` into the ``repro`` link for each
## dlopen'd library (clingo, zstd). That threading is invisible in the source
## tree and silently degrades to "no rpath" when a directory cannot be located.
## Nothing failed when that happened: the dev shell's ``LD_LIBRARY_PATH``
## papered over it locally and only the SSH phases broke, with a
## ``could not load: libclingo.so`` surfacing several layers away from its
## cause. This test is the missing feedback: it runs the real, already-built
## binary with the loader search-path variables removed from the child
## environment and fails the moment a bare-soname ``dlopen`` stops resolving on
## its own. The packaged ``packages.reprobuild`` derivation solves the same
## problem for *installed* binaries in ``flake.nix``'s ``postFixup`` (patchelf /
## install_name_tool over the full runtime library family) and its ``checks``
## already gate that; the bootstrapped binary this test covers is the one
## installed-side gates never see.
##
## No mocks: the binary under test is the real ``build/bin/repro`` produced by
## ``just build``, invoked as a real subprocess against a real filesystem
## store root. There is no in-process stand-in for the dynamic loader, and
## substituting one would test nothing that matters here.
##
## Platform note: scrubbing ``LD_LIBRARY_PATH`` / ``DYLD_LIBRARY_PATH`` /
## ``DYLD_FALLBACK_LIBRARY_PATH`` is a no-op on hosts that never set them
## (Windows resolves ``clingo.dll`` from the executable's own directory, which
## ``build_apps.sh`` stages), so the same assertions run unconditionally
## everywhere — the test has no platform opt-out and no skip.

import std/[os, osproc, streams, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

const LoaderSearchPathVars = [
  "LD_LIBRARY_PATH",
  "DYLD_LIBRARY_PATH",
  "DYLD_FALLBACK_LIBRARY_PATH",
]

## An all-zero digest: a well-formed 32-byte blake3 hex that is guaranteed to
## be absent from a freshly created store, so the query answers "not present"
## instead of touching any real content.
const AbsentDigestHex =
  "0000000000000000000000000000000000000000000000000000000000000000"

type CmdResult = tuple[exitCode: int; output: string]

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc reproBinary(repoRoot: string): string =
  result = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build it with `just build` first"

proc scrubbedEnvironment(): StringTableRef =
  ## The inherited environment minus every loader search-path variable —
  ## the shape a non-interactive ``sshd`` session hands to a remote command.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  for name in LoaderSearchPathVars:
    if result.hasKey(name):
      result.del(name)

const RemoteSessionVars = [
  # POSIX: what a non-interactive `ssh host cmd` session actually gets.
  "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG",
  # Windows: the loader itself needs these to find the system DLLs, so a
  # "minimal" environment that dropped them would test the harness, not the
  # binary. None of them is a library search path the dev shell exports.
  "SystemRoot", "SYSTEMROOT", "windir", "COMSPEC", "TEMP", "TMP",
  "USERPROFILE", "SystemDrive", "PATHEXT", "NUMBER_OF_PROCESSORS",
]

proc minimalEnvironment(): StringTableRef =
  ## Even stricter than ``scrubbedEnvironment``: an allowlist holding only the
  ## variables a remote command can count on. Nothing the dev shell exports
  ## survives — in particular no loader search path — so this is the closest
  ## in-process approximation of the far side of an SSH transport.
  result = newStringTable(modeCaseSensitive)
  for name in RemoteSessionVars:
    let value = getEnv(name)
    if value.len > 0:
      result[name] = value

proc runRepro(binary: string; args: openArray[string];
              env: StringTableRef): CmdResult =
  let p = startProcess(binary, args = @args, env = env,
    options = {poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc assertLoaded(res: CmdResult; what: string) =
  ## ``could not load:`` is the verbatim Nim ``dynlib`` failure text; assert on
  ## it explicitly so a loader regression reports itself instead of hiding
  ## inside a generic non-zero exit.
  checkpoint(what & " (exit " & $res.exitCode & "):\n" & res.output)
  check "could not load:" notin res.output
  check res.exitCode == 0

suite "repro resolves its dlopen'd libraries without LD_LIBRARY_PATH":

  test "repro starts with the loader search-path variables scrubbed":
    let repoRoot = findRepoRoot()
    let binary = reproBinary(repoRoot)
    let env = scrubbedEnvironment()
    for name in LoaderSearchPathVars:
      check not env.hasKey(name)

    let res = runRepro(binary, ["--version"], env)
    assertLoaded(res, "repro --version with scrubbed loader search path")
    check res.output.strip().startsWith("repro ")

  test "repro starts from a minimal non-login environment":
    let repoRoot = findRepoRoot()
    let binary = reproBinary(repoRoot)

    let res = runRepro(binary, ["--version"], minimalEnvironment())
    assertLoaded(res, "repro --version in a minimal environment")
    check res.output.strip().startsWith("repro ")

  test "the M71 remote-side bundle query runs without LD_LIBRARY_PATH":
    # `repro home __receive-bundle --query` is literally the command the
    # M71 transfer driver runs over SSH on the target host, so exercising it
    # here ties the guard to the invocation that first exposed the gap.
    let repoRoot = findRepoRoot()
    let binary = reproBinary(repoRoot)
    let storeRoot = getTempDir() /
      ("repro-dlopen-guard-" & $getCurrentProcessId())
    removeDir(storeRoot)
    createDir(storeRoot)
    defer: removeDir(storeRoot)

    let res = runRepro(binary,
      ["home", "__receive-bundle", "--store-root", storeRoot,
       "--query", AbsentDigestHex],
      scrubbedEnvironment())
    assertLoaded(res, "repro home __receive-bundle --query over a clean env")
    check "bundlePresent: false" in res.output
