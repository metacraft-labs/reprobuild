import std/[os, sequtils, strutils, tempfiles, unittest]
import repro_interface_artifacts
import repro_tool_profiles

proc use(name: string): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: name, packageSelector: name, executableName: name)

proc executable(dir, name: string): string =
  createDir(dir)
  result = dir / (name & ExeExt)
  writeFile(result, "fixture bytes\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc sidecar(dir, name, binary: string): string =
  createDir(dir)
  result = dir / (name & ".repro-tool-profile")
  writeFile(result, "reprobuild-tool-profile-v1\nresolvedExecutablePath=" & binary & "\n")

proc checkBatch(uses: seq[InterfaceToolUse]; path: string): seq[string] =
  result = pathOnlyResolutionSignatures(uses, path)
  check result == uses.mapIt(pathOnlyResolutionSignature(it, path))

suite "operation-scoped PATH sidecar discovery":
  var scratch: string
  setup:
    scratch = createTempDir("repro-sidecar-batch-", "")
  teardown:
    removeDir(scratch)

  test "batch results retain order and agree with individual resolution":
    let a = executable(scratch / "bin", "a")
    let b = executable(scratch / "bin", "b")
    let path = scratch / "missing" & $PathSep & scratch / "bin"
    let signatures = checkBatch(@[use("b"), use("a"), use("missing")], path)
    check signatures == @["executable\x1f" & b, "executable\x1f" & a, "executable\x1f"]

  test "freestanding sidecars take precedence over an earlier bare executable":
    discard executable(scratch / "bin", "a")
    let chosen = executable(scratch / "real", "chosen")
    let profile = sidecar(scratch / "profiles", "a", chosen)
    let path = scratch / "bin" & $PathSep & scratch / "profiles"
    check checkBatch(@[use("a")], path) == @["sidecar\x1f" & profile & "\x1f" & chosen]

  test "the first sidecar wins in PATH order":
    let a = executable(scratch / "real", "a")
    let b = executable(scratch / "real", "b")
    let first = sidecar(scratch / "first", "tool", a)
    let second = sidecar(scratch / "second", "tool", b)
    check checkBatch(@[use("tool")], scratch / "first" & $PathSep & scratch / "second") ==
      @["sidecar\x1f" & first & "\x1f" & a]
    check checkBatch(@[use("tool")], scratch / "second" & $PathSep & scratch / "first") ==
      @["sidecar\x1f" & second & "\x1f" & b]

  test "an invalid first sidecar keeps the existing executable fallback":
    let binary = executable(scratch / "bin", "tool")
    discard sidecar(scratch / "first", "tool", scratch / "absent")
    discard sidecar(scratch / "second", "tool", binary)
    let path = scratch / "first" & $PathSep & scratch / "second" & $PathSep & scratch / "bin"
    check checkBatch(@[use("tool")], path) == @["executable\x1f" & binary]

  test "a later batch sees profile creation retargeting and removal":
    let a = executable(scratch / "bin", "a")
    let b = executable(scratch / "bin", "b")
    let dir = scratch / "profiles"
    createDir(dir)
    let path = dir & $PathSep & scratch / "bin"
    check checkBatch(@[use("a")], path) == @["executable\x1f" & a]
    let profile = sidecar(dir, "a", b)
    check checkBatch(@[use("a")], path) == @["sidecar\x1f" & profile & "\x1f" & b]
    discard sidecar(dir, "a", a)
    check checkBatch(@[use("a")], path) == @["sidecar\x1f" & profile & "\x1f" & a]
    removeFile(profile)
    check checkBatch(@[use("a")], path) == @["executable\x1f" & a]

  test "a missing PATH directory can acquire profiles before the next batch":
    let binary = executable(scratch / "real", "a")
    let dir = scratch / "new"
    check checkBatch(@[use("tool")], dir) == @["executable\x1f"]
    let profile = sidecar(dir, "tool", binary)
    check checkBatch(@[use("tool")], dir) == @["sidecar\x1f" & profile & "\x1f" & binary]

  test "case candidates use filesystem matching rather than assuming its rules":
    let binary = executable(scratch / "real", "a")
    discard sidecar(scratch / "profiles", "TOOL", binary)
    discard checkBatch(@[use("tool"), use("TOOL")], scratch / "profiles")

  test "non-ASCII names preserve the uncached lookup":
    let binary = executable(scratch / "real", "a")
    let name = "tool-\xC4\xB0"
    let profile = sidecar(scratch / "profiles", name, binary)
    check checkBatch(@[use(name)], scratch / "profiles") ==
      @["sidecar\x1f" & profile & "\x1f" & binary]

  test "path components in a tool name are not treated as directory entries":
    let binary = executable(scratch / "real", "a")
    discard sidecar(scratch / "profiles" / "nested", "tool", binary)
    let result = checkBatch(@[use("nested/tool")], scratch / "profiles")
    check result[0].startsWith("sidecar\x1f")

  test "directories named like sidecars are not selected":
    createDir(scratch / "tool.repro-tool-profile")
    check checkBatch(@[use("tool")], scratch) == @["executable\x1f"]

  test "distinct missing tools and duplicate directories do not hide a later profile":
    createDir(scratch / "empty")
    let binary = executable(scratch / "real", "b")
    let profile = sidecar(scratch / "profiles", "b", binary)
    let path = scratch / "empty" & $PathSep & scratch / "empty" & $PathSep & scratch / "profiles"
    check checkBatch(@[use("a"), use("b"), use("c")], path) ==
      @["executable\x1f", "sidecar\x1f" & profile & "\x1f" & binary, "executable\x1f"]

  test "unreadable directory enumeration falls back to individual probes":
    when defined(posix):
      let binary = executable(scratch / "real", "a")
      let dir = scratch / "profiles"
      let profile = sidecar(dir, "tool", binary)
      setFilePermissions(dir, {fpUserExec})
      defer: setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      var enumerable = false
      try:
        for _, _ in walkDir(dir, checkDir = true):
          discard
        enumerable = true
      except OSError:
        discard
      check checkBatch(@[use("tool"), use("missing")], dir) ==
        @["sidecar\x1f" & profile & "\x1f" & binary, "executable\x1f"]
      if enumerable:
        checkpoint "This process can enumerate the execute-only directory; fallback not exercised."
        skip()
    else:
      checkpoint "POSIX directory permission fixture is not available on this platform."
      skip()
