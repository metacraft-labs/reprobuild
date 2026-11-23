## Workspace bundles (docs/workspace-bundles.md): the parts of `repro bundle`
## that need no Nix build, against real git repositories, GNU tar and zstd on
## a temporary filesystem. No mocks.
##
## The Nix half, publishing and the full restore are exercised end to end by
## the procedure recorded in docs/workspace-bundles.md (they need a Nix
## daemon, flakes and an S3 endpoint).

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_bundle
import repro_bundle/[nix_half, sources_half, select, bootstrap]
import repro_local_store/store_bundle
import repro_test_support/reasoned_skip

proc sh(cmd: string; cwd = ""): string =
  let (output, code) = execCmdEx(cmd, workingDir = cwd)
  doAssert code == 0, cmd & "\n" & output
  output

proc gitRepo(dir, origin: string; files: openArray[(string, string)]) =
  createDir(dir)
  for (name, body) in files:
    createDir((dir / name).parentDir)
    writeFile(dir / name, body)
  discard sh("git init -q -b main " & quoteShell(dir))
  discard sh("git -C " & quoteShell(dir) & " add -A")
  discard sh("git -C " & quoteShell(dir) &
    " -c user.name=t -c user.email=t@example.invalid commit -qm init")
  if origin.len > 0:
    discard sh("git -C " & quoteShell(dir) & " remote add origin " & origin)

proc fixtureWorkspace(root: string) =
  ## A workspace with project `demo` = repos `lib` and `tools/nested`.
  gitRepo(root, "https://example.invalid/ws", [
    ("repro-workspace.toml",
      "schema = \"reprobuild.workspace.settings.v1\"\n\n[workspace]\n" &
      "mainline = \"main\"\n"),
    (".gitignore", "/.repro/\n/lib/\n/tools/\n"),
    ("projects/demo.toml", "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "member_repos = [\"lib\", \"nested\"]\n\n[project]\nname = \"demo\"\n"),
    ("url-prefixes/acme.toml",
      "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n[url-prefix]\n" &
      "name = \"acme\"\nurl = \"https://example.invalid\"\n"),
    ("repos/lib.toml", "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
      "[repo]\nname = \"lib\"\npath = \"lib\"\nurl_prefix = \"acme\"\n" &
      "mainline = \"main\"\n"),
    ("repos/nested.toml", "schema = \"reprobuild.workspace.repo.v2\"\n\n" &
      "[repo]\nname = \"nested\"\npath = \"tools/nested\"\n" &
      "url_prefix = \"acme\"\nmainline = \"main\"\n")])
  gitRepo(root / "lib", "https://example.invalid/lib",
    [("src/lib.nim", "echo 1\n")])
  gitRepo(root / "tools" / "nested", "https://example.invalid/nested",
    [("README.md", "nested\n")])
  createDir(root / ".repro")
  writeFile(root / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
    "project = \"demo\"\nprojects = [\"demo\"]\n")

suite "nix half identity":
  test "print-dev-env normalisation drops the hook and the core count":
    let raw = "NIX_BUILD_CORES='4'\nexport FOO='x'\neval \"${shellHook:-}\"\n"
    let norm = normaliseDevEnv(raw)
    check "shellHook" notin norm
    check "NIX_BUILD_CORES=\"$(nproc" in norm
    check "export FOO='x'" in norm
    check normaliseDevEnv(raw.replace("'4'", "'64'")) == norm

  test "the id is a function of the path set, not its order":
    let a = @["/nix/store/bbb-x", "/nix/store/aaa-y"]
    check nixHalfId(a) == nixHalfId(@[a[1], a[0]])
    check nixHalfId(a) != nixHalfId(a & @["/nix/store/ccc-z"])
    check nixHalfId(a).len == 32

  test "store paths are recognised by prefix":
    check storePathOf("/nix/store/abc-repro/bin/repro") == "/nix/store/abc-repro"
    check storePathOf("/usr/bin/repro") == ""

suite "selection and the sources half":
  test "members resolve through the manifests; sources round-trip":
    if findExe("git").len == 0 or findExe("zstd").len == 0:
      skip("git and zstd are needed to build a sources half")
    else:
      let top = createTempDir("repro-bundle-src-", "")
      defer: removeDir(top)
      let ws = top / "ws"
      fixtureWorkspace(ws)
      let members = resolveMembers(ws, "demo")
      check members.len == 3
      check members[0].relPath == "."
      check members[1].relPath == "lib"
      check members[2].relPath == "tools/nested"
      var unknown = ""
      try: discard resolveMembers(ws, "nope")
      except BundleError as e: unknown = e.msg
      check "names no project" in unknown

      let (half, reused) = createSourcesHalf(ws, members, top / "out", 1,
        DefaultPartSize)
      check not reused
      check half.repos.len == 3
      check half.stateFiles.len == 1
      # Same commits, same state: the same id, and nothing rebuilt.
      check createSourcesHalf(ws, members, top / "out", 1,
        DefaultPartSize).reused
      # A changed state file is a changed half.
      writeFile(ws / ".repro" / "workspace-state.toml",
        readFile(ws / ".repro" / "workspace-state.toml") & "# moved\n")
      let (changed, _) = createSourcesHalf(ws, members, top / "out", 1,
        DefaultPartSize)
      check changed.id != half.id

      # Uncommitted work is not bundled.
      writeFile(ws / "lib" / "src" / "lib.nim", "echo 2\n")
      let target = top / "restored" / "ws"
      let dir = top / "out" / SourcesHalfDir / half.id
      restoreSourcesHalf(half, dir, target)
      check readFile(target / "lib" / "src" / "lib.nim") == "echo 1\n"
      check readFile(target / "tools" / "nested" / "README.md") == "nested\n"
      check sh("git -C " & quoteShell(target / "lib") &
        " remote get-url origin").strip() == "https://example.invalid/lib"
      check sh("git -C " & quoteShell(target / "tools/nested") &
        " rev-parse HEAD").strip() == sh("git -C " &
        quoteShell(ws / "tools/nested") & " rev-parse HEAD").strip()
      check fileExists(target / ".repro" / "workspace-state.toml")
      check half.sourcesPresent(target)
      # An existing checkout is never overwritten.
      writeFile(target / "lib" / "src" / "lib.nim", "local edit\n")
      restoreSourcesHalf(half, dir, target)
      check readFile(target / "lib" / "src" / "lib.nim") == "local edit\n"

suite "restore.sh":
  test "the bootstrap carries the Nix half and is valid bash":
    let h = NixHalf(id: "0123456789abcdef0123456789abcdef",
      zstd: "/nix/store/zzz-zstd-bin", repro: "/nix/store/rrr-repro",
      unpackedBytes: 1 shl 30, compressedBytes: 1 shl 28,
      parts: @[BundlePart(file: "part-0000", bytes: 5, sha256: "aa"),
               BundlePart(file: "part-0001", bytes: 5, sha256: "bb")],
      registration: BundlePart(file: "registration", bytes: 3, sha256: "cc"),
      shells: @[BundleShell(name: "lib:default", input: "/nix/store/in",
        env: "/nix/store/env")])
    let latest = %*{"system": "x86_64-linux", "name": "demo"}
    let script = renderRestoreScript(latest, true, h)
    check "aa  part-0000" in script
    check "cc  registration" in script
    check "'/nix/store/rrr-repro'" in script
    check "bundle restore \"$BASE\" --after-bootstrap" in script
    let path = getTempDir() / ("repro-bundle-restore-" &
      $getCurrentProcessId() & ".sh")
    writeFile(path, script)
    defer: removeFile(path)
    check execCmdEx("bash -n " & quoteShell(path)).exitCode == 0
    let bare = renderRestoreScript(latest, false, NixHalf())
    check "install repro first" in bare
