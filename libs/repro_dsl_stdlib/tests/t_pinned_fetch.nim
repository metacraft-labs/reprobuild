## `operations/pinned_fetch`: an archive beside a recipe's `fetch:` block is
## taken only when it hashes to its pin, and unpacked into place whole.
##
## Distribution-And-Packaging.md §5.3 needs these: the Nim fork's `dist/`
## trees and the `.deb` runtime libraries an installed prefix bundles
## (decision C).
##
## NO MOCKS. The archives are real files built in a temp dir -- a gzipped
## tarball with one leading directory, and a `.deb` assembled with `ar`
## from a `debian-binary`, a `control.tar.xz` and a `data.tar.xz` -- served
## through curl's `file://` scheme, so the edge's own script runs end to end
## with no network. Without curl, sha256sum, tar, xz or ar on PATH the
## script cases skip with the reason, and fail in a gate run.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_project_dsl
import repro_dsl_stdlib/operations/pinned_fetch

proc missingTool(): string =
  for tool in ["curl", "sha256sum", "tar", "gzip", "xz", "ar"]:
    if findExe(tool).len == 0:
      return tool & " is not on PATH"
  ""

template requireTools(body: untyped) =
  let missing = missingTool()
  if missing.len > 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(missing & " in a gate run")
      check false
    else:
      skip(missing)
  else:
    body

proc sh(cmd, dir: string): tuple[output: string, code: int] =
  let r = execCmdEx("sh -c " & quoteShell(cmd), workingDir = dir)
  (r.output, r.exitCode)

proc sha256Of(path: string): string =
  let r = execCmdEx("sha256sum " & quoteShell(path))
  doAssert r.exitCode == 0, r.output
  r.output.splitWhitespace()[0]

proc makeTarball(root: string): string =
  ## `pkg-1.0/hello.txt` in a gzipped tarball, as a GitHub archive lays out.
  createDir(root / "src" / "pkg-1.0")
  writeFile(root / "src" / "pkg-1.0" / "hello.txt", "hello\n")
  result = root / "pkg-1.0.tar.gz"
  doAssert sh("tar -czf " & quoteShell(result) & " pkg-1.0",
    root / "src").code == 0

proc makeDeb(root: string): string =
  ## A `.deb` whose data member holds `usr/lib/libprobe.so.1`, and whose
  ## control member holds a `postinst` that must never appear unpacked.
  let d = root / "deb"
  createDir(d / "data" / "usr" / "lib")
  writeFile(d / "data" / "usr" / "lib" / "libprobe.so.1", "\x7fELF")
  createDir(d / "control")
  writeFile(d / "control" / "control", "Package: probe\n")
  writeFile(d / "control" / "postinst", "#!/bin/sh\nexit 0\n")
  writeFile(d / "debian-binary", "2.0\n")
  doAssert sh("tar -cJf ../data.tar.xz .", d / "data").code == 0
  doAssert sh("tar -cJf ../control.tar.xz .", d / "control").code == 0
  result = root / "probe_1.0_armhf.deb"
  doAssert sh("ar rc " & quoteShell(result) &
    " debian-binary control.tar.xz data.tar.xz", d).code == 0

proc runEdge(act: BuildActionDef; dir: string): tuple[output: string, code: int] =
  for arg in act.call.arguments:
    if arg.name == "argv":
      let argv = arg.encodedValue.split('\x1f')
      return sh(argv[argv.find("-c") + 1], dir)
  ("no argv", 1)

suite "pinned archives: verified, then unpacked whole":

  test "the edge is a non-cacheable fetch that writes the stamp":
    resetBuildActionRegistry()
    let a = PinnedArchive(name: "stew", url: "https://example.org/s.tar.gz",
      sha256: repeat('a', 64), kind: pakTarball, stripComponents: 1)
    let act = emitPinnedFetchAction("/proj", "nim-fork", a, "/proj/dist/stew")
    check act.id == "pinned-fetch-nim-fork-stew"
    check act.outputs == @[pinnedFetchStamp("/proj", a)]
    check not act.cacheable
    check "sha256sum" in act.toolIdentityRefs
    check "gzip" in act.toolIdentityRefs
    # A second call returns the registered edge.
    check emitPinnedFetchAction("/proj", "nim-fork", a, "/x").id == act.id

  test "a malformed pin is refused before any edge exists":
    resetBuildActionRegistry()
    expect ValueError:
      discard emitPinnedFetchAction("/proj", "p", PinnedArchive(name: "x",
        url: "https://e/x.tar", sha256: "ABC"), "/proj/x")

  test "a tarball that hashes to its pin is unpacked, its top directory dropped":
    requireTools:
      let root = createTempDir("pinned-tar-", "")
      defer: removeDir(root)
      let tarball = makeTarball(root)
      resetBuildActionRegistry()
      let a = PinnedArchive(name: "pkg", url: "file://" & tarball,
        sha256: sha256Of(tarball), kind: pakTarball, stripComponents: 1)
      let act = emitPinnedFetchAction(root / "proj", "probe", a,
        root / "proj" / "dist" / "pkg")
      let r = runEdge(act, root)
      checkpoint(r.output)
      require r.code == 0
      check readFile(root / "proj" / "dist" / "pkg" / "hello.txt") == "hello\n"
      check fileExists(pinnedFetchStamp(root / "proj", a))

  test "bytes that do not hash to the pin are refused and nothing is unpacked":
    requireTools:
      let root = createTempDir("pinned-bad-", "")
      defer: removeDir(root)
      let tarball = makeTarball(root)
      resetBuildActionRegistry()
      let a = PinnedArchive(name: "pkg", url: "file://" & tarball,
        sha256: repeat('0', 64), kind: pakTarball, stripComponents: 1)
      let act = emitPinnedFetchAction(root / "proj", "probe", a,
        root / "proj" / "dist" / "pkg")
      let r = runEdge(act, root)
      checkpoint(r.output)
      check r.code != 0
      check not dirExists(root / "proj" / "dist" / "pkg")
      check not fileExists(pinnedFetchStamp(root / "proj", a))

  test "a .deb yields its data tree and nothing of its control member":
    requireTools:
      let root = createTempDir("pinned-deb-", "")
      defer: removeDir(root)
      let deb = makeDeb(root)
      resetBuildActionRegistry()
      let a = PinnedArchive(name: "libprobe", url: "file://" & deb,
        sha256: sha256Of(deb), kind: pakDeb)
      let act = emitPinnedFetchAction(root / "proj", "prefix", a,
        root / "proj" / "deb" / "libprobe")
      check "ar" in act.toolIdentityRefs
      let r = runEdge(act, root)
      checkpoint(r.output)
      require r.code == 0
      let dest = root / "proj" / "deb" / "libprobe"
      check readFile(dest / "usr" / "lib" / "libprobe.so.1") == "\x7fELF"
      for name in ["postinst", "control", "debian-binary", "data.tar.xz",
                   "control.tar.xz"]:
        check not fileExists(dest / name)
