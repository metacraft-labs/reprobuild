## Workspace bundles (docs/workspace-bundles.md): the parts of `repro bundle`
## that need no Nix build, against real git repositories, GNU tar and zstd on
## a temporary filesystem. No mocks.
##
## The Nix half, publishing and the full restore are exercised end to end by
## the procedure recorded in docs/workspace-bundles.md (they need a Nix
## daemon, flakes and an S3 endpoint).

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_bundle
import repro_bundle/[nix_half, sources_half, select, bootstrap, github]
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
      check not restoreSourcesHalf(half, dir, target)
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
      # The root is a checkout now, so this is the members-only path.
      check restoreSourcesHalf(half, dir, target)
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
    check "bundle restore \"$SRC\" --after-bootstrap" in script
    let path = getTempDir() / ("repro-bundle-restore-" &
      $getCurrentProcessId() & ".sh")
    writeFile(path, script)
    defer: removeFile(path)
    check execCmdEx("bash -n " & quoteShell(path)).exitCode == 0
    let bare = renderRestoreScript(latest, false, NixHalf())
    check "install repro first" in bare

suite "github layout":
  test "files map to deterministic branches of at most 20":
    var parts: seq[BundlePart]
    for i in 0 ..< 25:
      parts.add(BundlePart(file: partName(PartPrefix, i)))
    let files = halfFiles(NixManifestName, parts, @["registration"])
    check files.len == 27
    check githubRefOf("demo", "x86_64-linux/nix/abc", files, "part-0000") ==
      "demo/x86_64-linux/nix/abc/b00"
    check githubRefOf("demo", "x86_64-linux/nix/abc", files, "part-0018") ==
      "demo/x86_64-linux/nix/abc/b00"
    # nix.json sorts first, so the 20th part opens the second branch.
    check files[0] == NixManifestName
    check githubRefOf("demo", "x86_64-linux/nix/abc", files, "part-0019") ==
      "demo/x86_64-linux/nix/abc/b01"
    check githubRefOf("demo", "x86_64-linux/nix/abc", files, "part-0020") ==
      "demo/x86_64-linux/nix/abc/b01"
    check githubRefOf("demo", "x86_64-linux/nix/abc", files, "registration") ==
      "demo/x86_64-linux/nix/abc/b01"

  test "an explicit ref is taken as given":
    let src = parseGithubSource("github:acme/bundles@0123abc/demo")
    check src.repo == "acme/bundles"
    check src.gitRef == "0123abc"
    check src.bundle == "demo"

proc snapshotBranches(bare, rawRoot, repo: string) =
  ## A file:// stand-in for raw.githubusercontent.com: every branch, and the
  ## commit `latest` points at, checked out under <raw>/<repo>/<ref>/.
  for line in sh("git -C " & quoteShell(bare) &
      " for-each-ref --format='%(refname:short) %(objectname)' refs/heads").splitLines():
    let f = line.split(' ')
    if f.len != 2: continue
    for name in [f[0], f[1]]:
      let dest = rawRoot / repo / name
      createDir(dest)
      discard sh("git -C " & quoteShell(bare) & " archive " & f[1] &
        " | tar -x -C " & quoteShell(dest))

suite "sources into an existing root, activation, GitHub round trip":
  test "members only, excluded from the root; activation once; via GitHub":
    if findExe("git").len == 0 or findExe("zstd").len == 0 or
        findExe("curl").len == 0:
      skip("git, zstd and curl are needed for this round trip")
    else:
      let top = createTempDir("repro-bundle-gh-", "")
      defer: removeDir(top)
      let ws = top / "ws"
      fixtureWorkspace(ws)
      let outDir = top / "out"
      let created = createBundle(CreateOptions(workspaceRoot: ws,
        selector: "demo", outDir: outDir, sources: true, level: 1))
      check created.halves.len == 1
      check fileExists(created.restoreScript)

      # The environment has already cloned the workspace root itself.
      let target = top / "session" / "ws"
      discard sh("git clone -q " & quoteShell(ws) & " " & quoteShell(target))
      writeFile(target / "README.session", "mine\n")
      let profile = top / "etc" / "profile.d" / "zz-repro-bundle.sh"
      let bashrc = top / "etc" / "bash.bashrc"
      createDir(top / "etc")
      writeFile(bashrc, "# system bashrc")
      let r = restoreBundle(RestoreOptions(source: outDir / "demo",
        workspaceDir: target, activate: true, activationFile: profile,
        bashrcFile: bashrc))
      check r.restored == @["sources"]
      check r.notes.len == 1
      check readFile(target / "lib" / "src" / "lib.nim") == "echo 1\n"
      check fileExists(target / "tools" / "nested" / "README.md")
      check readFile(target / "README.session") == "mine\n"
      let exclude = readFile(target / ".git" / "info" / "exclude")
      check "/lib/" in exclude
      check "/tools/nested/" in exclude
      check sh("git -C " & quoteShell(target) &
        " status --porcelain").strip() == "?? README.session"
      check "__REPRO_BUNDLE_ACTIVE" in readFile(profile)
      check readFile(bashrc).count("# repro bundle activation: " & profile) == 1
      # Restoring again changes nothing, and adds no second bashrc line.
      let again = restoreBundle(RestoreOptions(source: outDir / "demo",
        workspaceDir: target, activate: true, activationFile: profile,
        bashrcFile: bashrc))
      check again.alreadyPresent == @["sources"]
      check readFile(bashrc).count("# repro bundle activation: " & profile) == 1
      check readFile(target / ".git" / "info" / "exclude").count("/lib/") == 1

      # Publish to a local bare repository standing in for GitHub, then
      # restore from it through the raw-file route.
      let remotes = top / "remotes"
      createDir(remotes / "acme")
      discard sh("git init -q --bare " & quoteShell(remotes / "acme" / "bundles"))
      putEnv("REPRO_BUNDLE_GITHUB_REMOTE", "file://" & remotes)
      putEnv("REPRO_BUNDLE_GITHUB_RAW", "file://" & top / "raw")
      putEnv("REPRO_BUNDLE_GITHUB_API", "file://" & top / "no-api")
      defer:
        delEnv("REPRO_BUNDLE_GITHUB_REMOTE")
        delEnv("REPRO_BUNDLE_GITHUB_RAW")
        delEnv("REPRO_BUNDLE_GITHUB_API")
      let pub = publishBundle(PublishOptions(bundleDir: outDir / "demo",
        target: "github:acme/bundles"))
      check pub.uploaded.len == 1
      check publishBundle(PublishOptions(bundleDir: outDir / "demo",
        target: "github:acme/bundles")).skipped.len == 1
      let heads = sh("git -C " & quoteShell(remotes / "acme" / "bundles") &
        " for-each-ref --format='%(refname:short)' refs/heads")
      check "latest" in heads
      check "demo/sources/" in heads
      snapshotBranches(remotes / "acme" / "bundles", top / "raw", "acme/bundles")
      let fresh = top / "fresh" / "ws"
      let viaGh = restoreBundle(RestoreOptions(source: "github:acme/bundles/demo",
        workspaceDir: fresh))
      check viaGh.restored == @["sources"]
      check readFile(fresh / "lib" / "src" / "lib.nim") == "echo 1\n"

suite "restore.sh as a setup script":
  test "a failure is logged and does not fail the session unless strict":
    let top = createTempDir("repro-bundle-sh-", "")
    defer: removeDir(top)
    let script = top / "restore.sh"
    writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
      "name": "demo"}, false, NixHalf()))
    let log = top / "log" / "restore.log"
    let env = "env -i PATH=/usr/bin:/bin REPRO_BUNDLE_LOG=" & quoteShell(log)
    check execCmdEx(env & " bash " & quoteShell(script) & " /nowhere").exitCode == 0
    check "install repro first" in readFile(log)
    check execCmdEx(env & " REPRO_BUNDLE_STRICT=1 bash " & quoteShell(script) &
      " /nowhere").exitCode == 1
