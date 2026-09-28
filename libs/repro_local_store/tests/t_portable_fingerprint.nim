## Portable fingerprints (Cache-Scope Phase 3, P3.1) — the validation named in
## the plan: the same action run from two checkouts at different absolute
## paths yields byte-identical portable weak and strong fingerprints; editing
## an input's CONTENT changes the strong fingerprint (touching its mtime does
## not); an input outside every logical root marks the action non-portable;
## untracked roots do not contribute.

import std/[os, strutils, tempfiles, times, unittest]

import repro_local_store/portable_fingerprint

proc checkout(base: string): string =
  ## A tiny "project" with one source file and one data file.
  result = base / "work" / "project"
  createDir(result / "src")
  writeFile(result / "src" / "main.c", "int main(void) { return 0; }\n")
  writeFile(result / "closure.manifest", "a 111 https://x/a.tgz\n")

proc fingerprintOf(project, toolstore, system: string;
                   extraRead = ""): PortableFingerprint =
  let roots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked),
    LogicalRoot(label: "toolstore", path: toolstore, kind: lrkTracked),
    LogicalRoot(label: "system", path: system, kind: lrkUntracked)]
  var reads = @[project / "src" / "main.c", project / "closure.manifest",
    toolstore / "cc" / "bin" / "cc.exe", system / "kernel32.dll"]
  if extraRead.len > 0:
    reads.add(extraRead)
  computePortableFingerprint(roots,
    argv = @[toolstore / "cc" / "bin" / "cc.exe", "-c",
      project / "src" / "main.c", "-o", project / "out" / "main.o"],
    cwd = project,
    env = @[("CFLAGS", "-I" & project / "include"), ("LANG", "C")],
    declaredInputs = @[project / "src" / "main.c"],
    reads = reads,
    probes = @[project / "include" / "missing.h"],
    enumerations = @[project / "src"])

proc toolstore(base: string): string =
  result = base / "store"
  createDir(result / "cc" / "bin")
  writeFile(result / "cc" / "bin" / "cc.exe", "compiler-bytes-v1")

suite "portable fingerprints":

  test "two checkouts at different absolute paths agree exactly":
    let a = createTempDir("repro-pfp-a-", "")
    let b = createTempDir("repro-pfp-bbbbbbbb-", "")
    defer:
      removeDir(a)
      removeDir(b)
    let fa = fingerprintOf(checkout(a), toolstore(a), a / "sys")
    let fb = fingerprintOf(checkout(b), toolstore(b), b / "sys")
    check fa.portable
    check fb.portable
    check fa.weakHex == fb.weakHex
    check fa.strongHex == fb.strongHex
    check fa.inputs == fb.inputs
    # And no physical path leaked into the logical inputs.
    for input in fa.inputs:
      check a.replace('\\', '/') notin input.path
      check input.path.startsWith("project:") or
        input.path.startsWith("toolstore:")

  test "editing an input's content changes the strong fingerprint only":
    let a = createTempDir("repro-pfp-edit-", "")
    defer: removeDir(a)
    let project = checkout(a)
    let store = toolstore(a)
    let before = fingerprintOf(project, store, a / "sys")
    writeFile(project / "closure.manifest", "a 222 https://x/a.tgz\n")
    let after = fingerprintOf(project, store, a / "sys")
    check before.weakHex == after.weakHex      # static description unchanged
    check before.strongHex != after.strongHex  # observed content changed

  test "a toolchain change is an input change":
    let a = createTempDir("repro-pfp-tool-", "")
    defer: removeDir(a)
    let project = checkout(a)
    let store = toolstore(a)
    let before = fingerprintOf(project, store, a / "sys")
    writeFile(store / "cc" / "bin" / "cc.exe", "compiler-bytes-v2")
    let after = fingerprintOf(project, store, a / "sys")
    check before.strongHex != after.strongHex

  test "an mtime-only change does not move the portable identity":
    let a = createTempDir("repro-pfp-mtime-", "")
    defer: removeDir(a)
    let project = checkout(a)
    let store = toolstore(a)
    let before = fingerprintOf(project, store, a / "sys")
    setLastModificationTime(project / "src" / "main.c",
      getTime() - initDuration(days = 3))
    let after = fingerprintOf(project, store, a / "sys")
    check before.strongHex == after.strongHex

  test "an input outside every logical root makes the action non-portable":
    let a = createTempDir("repro-pfp-outside-", "")
    let stray = createTempDir("repro-pfp-stray-", "")
    defer:
      removeDir(a)
      removeDir(stray)
    writeFile(stray / "host.cfg", "x")
    let f = fingerprintOf(checkout(a), toolstore(a), a / "sys",
      extraRead = stray / "host.cfg")
    check not f.portable
    check f.strongHex == ""
    check "host.cfg" in f.reason

  test "untracked roots do not contribute":
    let a = createTempDir("repro-pfp-untracked-", "")
    defer: removeDir(a)
    let f = fingerprintOf(checkout(a), toolstore(a), a / "sys")
    for input in f.inputs:
      check not input.path.startsWith("system:")

  test "probe and enumeration are content-free existence and membership":
    let a = createTempDir("repro-pfp-probe-", "")
    defer: removeDir(a)
    let project = checkout(a)
    let store = toolstore(a)
    let before = fingerprintOf(project, store, a / "sys")
    # The probed header now exists: a probe is an input.
    createDir(project / "include")
    writeFile(project / "include" / "missing.h", "")
    let probed = fingerprintOf(project, store, a / "sys")
    check before.strongHex != probed.strongHex
    # A new file in the enumerated directory changes membership.
    writeFile(project / "src" / "extra.c", "")
    let enumerated = fingerprintOf(project, store, a / "sys")
    check probed.strongHex != enumerated.strongHex

  test "nested roots resolve to the longest match":
    let roots = @[
      LogicalRoot(label: "workspace", path: "/w", kind: lrkTracked),
      LogicalRoot(label: "project", path: "/w/pkgs/gemini", kind: lrkTracked)]
    check toLogicalPath(roots, "/w/pkgs/gemini/repro.nim").label == "project"
    check toLogicalPath(roots, "/w/pkgs/gemini/repro.nim").rel == "repro.nim"
    check toLogicalPath(roots, "/w/reprobuild/libs/x.nim").label == "workspace"
    check toLogicalPath(roots, "/elsewhere/x").kind == lpkOutside

  test "P3.2: identical trees at different absolute paths share an identity":
    let a = createTempDir("repro-pfp-tree-a-", "")
    let b = createTempDir("repro-pfp-tree-bbbbbb-", "")
    defer:
      removeDir(a)
      removeDir(b)
    for root in [a, b]:
      createDir(root / "usr" / "bin")
      createDir(root / "usr" / "share" / "empty")
      writeFile(root / "usr" / "bin" / "gemini", "launcher\n")
      writeFile(root / "usr" / "lib.js", "bundle\n")
    check treeContentHex(a / "usr") == treeContentHex(b / "usr")
    # Content, a rename and an empty directory each change the identity.
    let base = treeContentHex(a / "usr")
    writeFile(b / "usr" / "lib.js", "bundle v2\n")
    check treeContentHex(b / "usr") != base
    writeFile(b / "usr" / "lib.js", "bundle\n")
    check treeContentHex(b / "usr") == base
    moveFile(b / "usr" / "lib.js", b / "usr" / "lib2.js")
    check treeContentHex(b / "usr") != base
    moveFile(b / "usr" / "lib2.js", b / "usr" / "lib.js")
    removeDir(b / "usr" / "share" / "empty")
    check treeContentHex(b / "usr") != base

  test "P3.2: outputs are named logically and identified by content":
    let a = createTempDir("repro-pfp-out-", "")
    defer: removeDir(a)
    let project = checkout(a)
    createDir(project / "out" / "usr" / "bin")
    writeFile(project / "out" / "usr" / "bin" / "tool", "bytes\n")
    writeFile(project / "out" / "stamp", "done\n")
    let roots = @[LogicalRoot(label: "project", path: project,
      kind: lrkTracked)]
    let outs = portableOutputs(roots, [project / "out" / "stamp",
      project / "out" / "usr"])
    check outs.portable
    check outs.outputs.len == 2
    check outs.outputs[0].path == "project:out/stamp"      # sorted
    check not outs.outputs[0].directory
    check outs.outputs[0].digest == fileContentHex(project / "out" / "stamp")
    check outs.outputs[1].path == "project:out/usr"
    check outs.outputs[1].directory
    check outs.outputs[1].digest == treeContentHex(project / "out" / "usr")

  test "P3.2: an output outside every root, or missing, is not portable":
    let a = createTempDir("repro-pfp-outbad-", "")
    let stray = createTempDir("repro-pfp-outstray-", "")
    defer:
      removeDir(a)
      removeDir(stray)
    let project = checkout(a)
    writeFile(stray / "x", "x")
    let roots = @[LogicalRoot(label: "project", path: project,
      kind: lrkTracked)]
    let outside = portableOutputs(roots, [stray / "x"])
    check not outside.portable
    check "outside" in outside.reason
    let missing = portableOutputs(roots, [project / "never-written"])
    check not missing.portable
    check "does not exist" in missing.reason

  when defined(windows):
    test "Windows paths compare case- and separator-insensitively":
      let roots = @[LogicalRoot(label: "project", path: r"M:\m\dev\pkg",
        kind: lrkTracked)]
      let p = toLogicalPath(roots, "m:/M/Dev/pkg/Src/Main.c")
      check p.kind == lpkTracked
      check p.rel == "Src/Main.c"
      check logicalizeText(roots, r"-IM:\m\dev\pkg\include") ==
        "-I${project}/include"
