## Workspace bundles (docs/workspace-bundles.md): the parts of `repro bundle`
## that need no Nix build, against real git repositories, GNU tar and zstd on
## a temporary filesystem. No mocks.
##
## Building a Nix half from dev shells, publishing and the full restore are
## exercised end to end by the procedure recorded in docs/workspace-bundles.md
## (they need flakes and an S3 endpoint). Restoring a Nix half is tested here
## against the real `nix-store`, `nix-hash`, tar and zstd, into a store under
## another root, with store paths this test adds to the host's store.
##
## The hostile-half suite at the end protects the confinement of a Nix half
## restore: the part hashes come from the same unsigned manifest as the
## parts, so a bundle host can serve any stream it likes, and only the
## restorer's own check of the archive's members keeps that stream inside
## the half's registered store paths. Each case builds a half's stream with
## GNU tar the way a hostile host would and restores it by both entry points
## (`restoreNixHalf` and restore.sh). The https-only cases check that a plain
## `http://` source, which anyone on the path could rewrite, is refused. See
## reprobuild-pm issues/2026-11-12-bundle-extraction-writes-every-tar-member-
## under-before-checking-it-against-the-declared.md.

import std/[algorithm, json, os, osproc, strutils, tempfiles, unittest]
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
      registration: BundlePart(file: "registration", bytes: 3, sha256: "ab"),
      shells: @[BundleShell(name: "lib:default", input: "/nix/store/in",
        env: "/nix/store/env")])
    let latest = %*{"system": "x86_64-linux", "name": "demo"}
    let script = renderRestoreScript(latest, true, h)
    check "aa  part-0000" in script
    check "ab  registration" in script
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

const RestoreScriptTools = ["bash", "sh", "curl", "nix-store", "nix-hash", "tar",
  "flock", "comm", "wc", "stat",
  "zstd", "sha256sum", "df", "awk", "xargs", "mktemp", "sort", "join", "cmp",
  "diff", "cut", "sed", "tr", "cat", "chmod", "rm", "mkdir", "touch", "tee",
  "date", "dirname", "tail", "head"]

proc restoreScriptPath(top: string): string =
  ## A PATH holding the tools restore.sh may use and no `repro`, as on a
  ## machine whose setup script runs it. Built from links into this host's
  ## own PATH, because neither /usr/bin nor /bin holds them on NixOS.
  result = top / "tools"
  createDir(result)
  for tool in RestoreScriptTools:
    let exe = findExe(tool, followSymlinks = false)
    if exe.len > 0 and not symlinkExists(result / tool):
      createSymlink(exe, result / tool)

suite "restore.sh as a setup script":
  test "a failure is logged and does not fail the session unless strict":
    let top = createTempDir("repro-bundle-sh-", "")
    defer: removeDir(top)
    let script = top / "restore.sh"
    writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
      "name": "demo"}, false, NixHalf()))
    let log = top / "log" / "restore.log"
    let env = "env -i PATH=" & quoteShell(restoreScriptPath(top)) &
      " REPRO_BUNDLE_LOG=" & quoteShell(log)
    check execCmdEx(env & " bash " & quoteShell(script) & " /nowhere").exitCode == 0
    check "install repro first" in readFile(log)
    check execCmdEx(env & " REPRO_BUNDLE_STRICT=1 bash " & quoteShell(script) &
      " /nowhere").exitCode == 1

proc makeWritable(path: string) =
  setFilePermissions(path, getFilePermissions(path) + {fpUserWrite})

proc storeLocationIn(root, storePath: string): string =
  root & storePath

proc outsideOf(root: string): string =
  root & ".outside"

proc interruptedUnpack(partsDir: string; h: NixHalf; root: string) =
  ## The state a restore killed mid-unpack leaves: the stream unpacked as
  ## far as one file of the first path, cut short there, and nothing
  ## registered. Truncating after a full unpack is the same on-disk state
  ## (GNU tar writes each file in place), and is exact, where killing tar
  ## at the right byte is a race.
  createDir(root)
  var cat = "cat"
  for p in h.parts: cat.add(" " & quoteShell(partsDir / p.file))
  discard sh(cat & " | zstd -q -dc --long=27 | tar -C " & quoteShell(root) &
    " -xf -")
  let big = storeLocationIn(root, h.shells[0].input) / "lib" / "big.so"
  makeWritable(big)
  discard sh("truncate -s 4096 " & quoteShell(big))
  setFilePermissions(big, {fpUserRead, fpGroupRead, fpOthersRead})
  # The second path never started.
  let second = storeLocationIn(root, h.shells[0].env)
  removeFile(second)
  # The third, a symlink store path, holds a symlink to a read-only
  # directory outside the store: removing the leftover must not follow it.
  let outside = outsideOf(root)
  createDir(outside)
  writeFile(outside / "keep", "keep\n")
  setFilePermissions(outside, {fpUserRead, fpUserExec})
  let third = storeLocationIn(root, h.paths[2])
  removeFile(third)
  createSymlink(outside, third)

proc outsideUntouched(root: string): bool =
  ## Whether the directory the third path's leftover pointed to is still
  ## there, still read-only and still holds its file.
  let outside = outsideOf(root)
  result = dirExists(outside) and
    getFilePermissions(outside) == {fpUserRead, fpUserExec} and
    fileExists(outside / "keep")

proc intactFile(path, expected: string): bool =
  ## Whether `path` holds exactly `expected`; reports the size, not the
  ## bytes, when it does not.
  let got = readFile(path)
  result = got == expected
  if not result:
    echo "    ", path, " is ", got.len, " bytes, not the ", expected.len,
      " bytes the bundle carries"

proc storeVerifies(root: string): tuple[ok: bool; output: string] =
  let (output, code) = execCmdEx("nix-store --store " & quoteShell(root) &
    " --verify --check-contents 2>&1")
  (code == 0 and "modified" notin output, output)

proc pathValid(root, storePath: string): bool =
  execCmdEx("nix-store --store " & quoteShell(root) & " --check-validity " &
    quoteShell(storePath) & " 2>&1").exitCode == 0

proc corruptRegistration(partsDir: string; h: var NixHalf; storePath: string) =
  ## The publisher's registration names a NAR hash the content does not
  ## have, as when its own copy of the path was damaged.
  let db = sh("zstd -q -dc " & quoteShell(partsDir / "registration"))
  let at = db.find(storePath & "\n")
  doAssert at >= 0
  let hashAt = at + storePath.len + 1
  var bad = db
  for i in hashAt ..< hashAt + 64: bad[i] = '0'
  writeFile(partsDir / "registration.raw", bad)
  discard sh("zstd -q -f -19 " & quoteShell(partsDir / "registration.raw") &
    " -o " & quoteShell(partsDir / "registration"))
  removeFile(partsDir / "registration.raw")
  let bytes = readFile(partsDir / "registration")
  h.registration = BundlePart(file: "registration", bytes: bytes.len,
    sha256: sha256Hex(bytes))

proc addPayloadPaths(top: string): tuple[a, b, c, big: string] =
  ## Three store paths of our own, added to the host's store: a tree with a
  ## 1 MiB file, a file, and a symlink.
  let tree = top / "payload"
  createDir(tree / "lib")
  var big = newString(1 shl 20)
  # xorshift: incompressible, so the stream spans several parts, and the
  # same on every run, so the store path is too.
  var x = 0x9E3779B97F4A7C15'u64
  for i in 0 ..< big.len:
    x = x xor (x shl 13)
    x = x xor (x shr 7)
    x = x xor (x shl 17)
    big[i] = chr(int(x and 0xff))
  writeFile(tree / "lib" / "big.so", big)
  writeFile(tree / "env.sh", "export T_REPRO_BUNDLE=1\n")
  result.a = sh("nix-store --add " & quoteShell(tree)).strip()
  result.b = sh("nix-store --add " & quoteShell(tree / "env.sh")).strip()
  createSymlink("env.sh", top / "link")
  result.c = sh("nix-store --add " & quoteShell(top / "link")).strip()
  result.big = big

proc packedHalf(paths: seq[string]; partsDir, id, input, env: string): NixHalf =
  ## A Nix half of `paths`, packed by the production packer into `partsDir`.
  let packed = packNixHalf(paths, partsDir, 3, 128 * 1024)
  NixHalf(id: id, system: "x86_64-linux",
    zstd: storePathOf(expandFilename(findExe("zstd"))), paths: paths,
    unpackedBytes: packed.unpackedBytes,
    compressedBytes: packed.compressedBytes, parts: packed.parts,
    registration: packed.registration,
    shells: @[BundleShell(name: "t:default", input: input, env: env)])

suite "nix half restore after an interrupted unpack":
  test "a truncated leftover is replaced, and content is checked before registration":
    if findExe("nix-store").len == 0 or findExe("nix-hash").len == 0 or
        findExe("zstd").len == 0:
      skip("nix-store, nix-hash and zstd are needed to restore a Nix half")
    else:
      let top = createTempDir("repro-bundle-nix-", "")
      defer:
        discard execCmdEx("chmod -R u+w " & quoteShell(top))
        removeDir(top)
      let (a, b, c, big) = addPayloadPaths(top)
      let partsDir = top / "bundle" / "x86_64-linux" / NixHalfDir / "h"
      var h = packedHalf(@[a, b, c], partsDir, "h", a, b)
      check h.parts.len > 1

      # The library path: `repro bundle restore`.
      let root = top / "root"
      interruptedUnpack(partsDir, h, root)
      check not pathValid(root, a)
      restoreNixHalf(h, partsDir, root)
      check pathValid(root, a)
      check intactFile(storeLocationIn(root, a) / "lib" / "big.so", big)
      check pathValid(root, c)
      check expandSymlink(storeLocationIn(root, c)) == "env.sh"
      check outsideUntouched(root)
      let verified = storeVerifies(root)
      check verified.ok
      if not verified.ok: echo verified.output
      # Run again over the complete store: valid paths are left alone.
      restoreNixHalf(h, partsDir, root)
      check storeVerifies(root).ok
      # And into an empty root, with nothing left over to remove.
      let fresh = top / "fresh-root"
      restoreNixHalf(h, partsDir, fresh)
      check intactFile(storeLocationIn(fresh, a) / "lib" / "big.so", big)
      check storeVerifies(fresh).ok

      # The bootstrap path: restore.sh, from a local bundle directory.
      let script = top / "restore.sh"
      writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
        "name": "bundle"}, true, h))
      let shRoot = top / "sh-root"
      interruptedUnpack(partsDir, h, shRoot)
      let log = top / "restore.log"
      let env = "env -i PATH=" & quoteShell(restoreScriptPath(top)) &
        " TMPDIR=" & quoteShell(top) &
        " REPRO_BUNDLE_LOG=" & quoteShell(log) &
        " REPRO_BUNDLE_NIX_ROOT=" & quoteShell(shRoot)
      discard execCmdEx(env & " bash " & quoteShell(script) & " " &
        quoteShell(top / "bundle"))
      check "nix half restored" in readFile(log)
      check pathValid(shRoot, a)
      check intactFile(storeLocationIn(shRoot, a) / "lib" / "big.so", big)
      check pathValid(shRoot, c)
      check expandSymlink(storeLocationIn(shRoot, c)) == "env.sh"
      check outsideUntouched(shRoot)
      let shVerified = storeVerifies(shRoot)
      check shVerified.ok
      if not shVerified.ok: echo readFile(log) & "\n" & shVerified.output

      # A registration whose hash the content does not have is refused,
      # and nothing is registered, by both paths.
      corruptRegistration(partsDir, h, a)
      let badRoot = top / "bad-root"
      interruptedUnpack(partsDir, h, badRoot)
      var refused = ""
      try: restoreNixHalf(h, partsDir, badRoot)
      except BundleError as e: refused = e.msg
      check "does not match its registration" in refused
      check a in refused
      check not pathValid(badRoot, a)
      check not pathValid(badRoot, b)
      check outsideUntouched(badRoot)
      writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
        "name": "bundle"}, true, h))
      let badShRoot = top / "bad-sh-root"
      interruptedUnpack(partsDir, h, badShRoot)
      removeFile(log)
      let badEnv = env.replace(quoteShell(shRoot), quoteShell(badShRoot))
      discard execCmdEx(badEnv & " bash " & quoteShell(script) & " " &
        quoteShell(top / "bundle"))
      check "does not match its registration" in readFile(log)
      check "nix half restored" notin readFile(log)
      check not pathValid(badShRoot, a)
      check outsideUntouched(badShRoot)

proc holdNixLock(root, storePath, scratch: string;
                 register = true): Process =
  ## A stand-in for a Nix writer (a `nix-daemon` substituting `storePath`):
  ## it takes `<path>.lock` as Nix's `PathLocks` does (an exclusive `flock`),
  ## writes the path's content, waits, records whether the directory it
  ## wrote is still the one it wrote, then registers it and exits, which
  ## releases the lock. `scratch/ready` appears once it holds the lock and
  ## the content is in place. With `register = false` it is a writer that
  ## fails part-way: it leaves a truncated file and registers nothing.
  let location = storeLocationIn(root, storePath)
  createDir(location.parentDir)
  let entry = scratch / "entry"
  writeFile(entry, sh("nix-store --dump-db " & quoteShell(storePath)))
  let script = "set -e\n" &
    "exec 9>>" & quoteShell(location & ".lock") & "\n" &
    "flock 9\n" &
    "cp -a " & quoteShell(storePath) & " " & quoteShell(location) & "\n" &
    (if register: "" else:
      "chmod -R u+w " & quoteShell(location) & "\n" &
      "truncate -s 3 " & quoteShell(location / "lib" / "data") & "\n") &
    "stat -c '%i %z' " & quoteShell(location) & " > " &
      quoteShell(scratch / "before") & "\n" &
    "touch " & quoteShell(scratch / "ready") & "\n" &
    "sleep 3\n" &
    "{ stat -c '%i %z' " & quoteShell(location) & " || echo gone; } > " &
      quoteShell(scratch / "after") & " 2>/dev/null\n" &
    (if register: "nix-store --store " & quoteShell(root) & " --load-db < " &
      quoteShell(entry) & "\n" else: "")
  writeFile(scratch / "holder.sh", script)
  result = startProcess("bash", args = [scratch / "holder.sh"],
    options = {poUsePath, poParentStreams})
  for _ in 0 ..< 200:
    if fileExists(scratch / "ready"): break
    sleep(25)
  doAssert fileExists(scratch / "ready"), "the lock holder did not start"

proc holdCollectorLock(root, storePath, scratch: string): Process =
  ## A stand-in for Nix's garbage collector: it holds `gc.lock` exclusively
  ## for 3 s, as `collectGarbage` does for a whole collection, and records
  ## whether `storePath` became valid in the store at `root` meanwhile.
  let state = root / "nix" / "var" / "nix"
  createDir(state)
  let script = "exec 9>>" & quoteShell(state / "gc.lock") & "\n" &
    "flock 9\n" &
    "touch " & quoteShell(scratch / "ready") & "\n" &
    "sleep 3\n" &
    "if nix-store --store " & quoteShell(root) & " --check-validity " &
      quoteShell(storePath) & " >/dev/null 2>&1; then echo registered; " &
      "else echo waited; fi > " & quoteShell(scratch / "during-gc") & "\n"
  writeFile(scratch / "collector.sh", script)
  result = startProcess("bash", args = [scratch / "collector.sh"],
    options = {poUsePath, poParentStreams})
  for _ in 0 ..< 200:
    if fileExists(scratch / "ready"): break
    sleep(25)
  doAssert fileExists(scratch / "ready"), "the GC lock holder did not start"

proc holdLockThenCollect(root, storePath, scratch: string): Process =
  ## A stand-in for a `nix-daemon` whose `addToStore` holds `storePath`'s
  ## lock and then waits for a garbage collection (`autoGC`), which takes
  ## `gc.lock` exclusively and deletes the lock files of the other invalid
  ## paths, none of which is its temporary root. It gives up after 10 s and
  ## records "deadlocked"; otherwise "collected". Either way it then writes
  ## and registers its path and exits.
  let location = storeLocationIn(root, storePath)
  let state = root / "nix" / "var" / "nix"
  createDir(location.parentDir)
  createDir(state)
  let entry = scratch / "entry"
  writeFile(entry, sh("nix-store --dump-db " & quoteShell(storePath)))
  let own = location & ".lock"
  let script = "exec 9>>" & quoteShell(own) & "\n" &
    "flock 9\n" &
    "touch " & quoteShell(scratch / "ready") & "\n" &
    "sleep 1\n" &
    "exec 8>>" & quoteShell(state / "gc.lock") & "\n" &
    "if flock -w 10 8; then\n" &
    "  for f in " & quoteShell(location.parentDir) & "/*.lock; do\n" &
    "    [ \"$f\" = " & quoteShell(own) & " ] || rm -f \"$f\"\n" &
    "  done\n" &
    "  echo collected\n" &
    "else echo deadlocked; fi > " & quoteShell(scratch / "collection") & "\n" &
    "exec 8>&-\n" &
    "cp -a " & quoteShell(storePath) & " " & quoteShell(location) & "\n" &
    "nix-store --store " & quoteShell(root) & " --load-db < " &
      quoteShell(entry) & "\n"
  writeFile(scratch / "daemon.sh", script)
  result = startProcess("bash", args = [scratch / "daemon.sh"],
    options = {poUsePath, poParentStreams})
  for _ in 0 ..< 200:
    if fileExists(scratch / "ready"): break
    sleep(25)
  doAssert fileExists(scratch / "ready"), "the daemon stand-in did not start"

proc collectionRan(scratch: string): bool =
  let got = readFile(scratch / "collection").strip()
  result = got == "collected"
  if not result:
    echo "    the restore held gc.lock while it waited for a path lock, so a ",
      "Nix writer waiting for a collection under that lock deadlocked (",
      got, ")"

proc waitedForCollector(scratch: string): bool =
  result = readFile(scratch / "during-gc").strip() == "waited"
  if not result:
    echo "    the restore registered a path while the garbage collector ",
      "held gc.lock"

proc untouchedWhileLocked(scratch: string): bool =
  ## Whether the path the holder wrote under its lock was still the same,
  ## unchanged directory (inode and change time, to the nanosecond) when the
  ## holder looked again, before it registered it. The change time catches
  ## a deletion and re-creation that happens to reuse the inode number.
  let before = readFile(scratch / "before").strip()
  let after = readFile(scratch / "after").strip()
  result = before.len > 0 and before == after
  if not result:
    echo "    the restore replaced or deleted the locked path while its ",
      "lock was held (inode and ctime before: ", before, "; after: ", after,
      ")"

suite "nix half restore beside a Nix writer":
  # Issue reprobuild-pm/issues/2026-11-15-bundle-restore-deletes-and-unpacks-
  # invalid-store-paths-without-nix-per-path-lock.md. Workspace-Bundles.md
  # §7 step 3.3: the restore takes Nix's per-path lock on every path it
  # restores and re-checks validity under it, so it never deletes or writes
  # a path that a Nix writer holding `<path>.lock` is restoring.
  test "a path whose Nix lock is held is waited for, then left to Nix":
    if findExe("nix-store").len == 0 or findExe("nix-hash").len == 0 or
        findExe("zstd").len == 0 or findExe("flock").len == 0:
      skip("nix-store, nix-hash, zstd and flock are needed")
    else:
      let top = createTempDir("repro-bundle-lock-", "")
      defer:
        discard execCmdEx("chmod -R u+w " & quoteShell(top))
        removeDir(top)
      let tree = top / "payload"
      createDir(tree / "lib")
      writeFile(tree / "lib" / "data", "locked path\n")
      writeFile(tree / "env.sh", "export T_REPRO_BUNDLE_LOCK=1\n")
      let a = sh("nix-store --add " & quoteShell(tree)).strip()
      let b = sh("nix-store --add " & quoteShell(tree / "env.sh")).strip()
      let partsDir = top / "bundle" / "x86_64-linux" / NixHalfDir / "h"
      let packed = packNixHalf(@[a, b], partsDir, 3, 1 shl 20)
      let h = NixHalf(id: "h", system: "x86_64-linux",
        zstd: storePathOf(expandFilename(findExe("zstd"))), paths: @[a, b],
        unpackedBytes: packed.unpackedBytes,
        compressedBytes: packed.compressedBytes, parts: packed.parts,
        registration: packed.registration,
        shells: @[BundleShell(name: "t:default", input: a, env: b)])

      # The library path: `repro bundle restore`.
      let root = top / "root"
      let scratch = top / "lib-holder"
      createDir(scratch)
      let holder = holdNixLock(root, a, scratch)
      restoreNixHalf(h, partsDir, root)
      discard holder.waitForExit()
      holder.close()
      check untouchedWhileLocked(scratch)
      check pathValid(root, a)
      check pathValid(root, b)
      let verified = storeVerifies(root)
      check verified.ok
      if not verified.ok: echo verified.output
      check not fileExists(storeLocationIn(root, b) & ".lock")

      # The bootstrap path: restore.sh.
      let script = top / "restore.sh"
      writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
        "name": "bundle"}, true, h))
      let shRoot = top / "sh-root"
      let shScratch = top / "sh-holder"
      createDir(shScratch)
      let log = top / "restore.log"
      let shHolder = holdNixLock(shRoot, a, shScratch)
      discard execCmdEx("env -i PATH=" & quoteShell(restoreScriptPath(top)) &
        " TMPDIR=" & quoteShell(top) &
        " REPRO_BUNDLE_LOG=" & quoteShell(log) &
        " REPRO_BUNDLE_NIX_ROOT=" & quoteShell(shRoot) &
        " bash " & quoteShell(script) & " " & quoteShell(top / "bundle"))
      discard shHolder.waitForExit()
      shHolder.close()
      check untouchedWhileLocked(shScratch)
      check "nix half restored" in readFile(log)
      check pathValid(shRoot, a)
      check pathValid(shRoot, b)
      let shVerified = storeVerifies(shRoot)
      check shVerified.ok
      if not shVerified.ok: echo readFile(log) & "\n" & shVerified.output
      check not fileExists(storeLocationIn(shRoot, b) & ".lock")

  test "a writer that fails under its lock is restored over; a valid path is not written":
    if findExe("nix-store").len == 0 or findExe("nix-hash").len == 0 or
        findExe("zstd").len == 0 or findExe("flock").len == 0:
      skip("nix-store, nix-hash, zstd and flock are needed")
    else:
      let top = createTempDir("repro-bundle-lock2-", "")
      defer:
        discard execCmdEx("chmod -R u+w " & quoteShell(top))
        removeDir(top)
      let tree = top / "payload"
      createDir(tree / "lib")
      writeFile(tree / "lib" / "data", "failed writer\n")
      writeFile(tree / "lib" / "extra", "kept out of a valid path\n")
      writeFile(tree / "env.sh", "export T_REPRO_BUNDLE_LOCK2=1\n")
      let a = sh("nix-store --add " & quoteShell(tree)).strip()
      let b = sh("nix-store --add " & quoteShell(tree / "env.sh")).strip()
      let partsDir = top / "bundle" / "x86_64-linux" / NixHalfDir / "h"
      let packed = packNixHalf(@[a, b], partsDir, 3, 1 shl 20)
      let h = NixHalf(id: "h", system: "x86_64-linux",
        zstd: storePathOf(expandFilename(findExe("zstd"))), paths: @[a, b],
        unpackedBytes: packed.unpackedBytes,
        compressedBytes: packed.compressedBytes, parts: packed.parts,
        registration: packed.registration,
        shells: @[BundleShell(name: "t:default", input: a, env: b)])
      let script = top / "restore.sh"
      writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
        "name": "bundle"}, true, h))
      let log = top / "restore.log"
      proc runScript(root: string) =
        discard execCmdEx("env -i PATH=" & quoteShell(restoreScriptPath(top)) &
          " TMPDIR=" & quoteShell(top) &
          " REPRO_BUNDLE_LOG=" & quoteShell(log) &
          " REPRO_BUNDLE_NIX_ROOT=" & quoteShell(root) &
          " bash " & quoteShell(script) & " " & quoteShell(top / "bundle"))

      # A Nix writer that fails under its lock leaves a truncated file and
      # registers nothing: once it lets go, the restore replaces it.
      let root = top / "root"
      let scratch = top / "failed-holder"
      createDir(scratch)
      let holder = holdNixLock(root, a, scratch, register = false)
      restoreNixHalf(h, partsDir, root)
      discard holder.waitForExit()
      holder.close()
      check untouchedWhileLocked(scratch)
      check pathValid(root, a)
      check storeVerifies(root).ok

      # A path that is valid is Nix's even when it is damaged: neither
      # path of the restore adds the file it lacks.
      for viaScript in [false, true]:
        let r = top / (if viaScript: "valid-sh-root" else: "valid-root")
        restoreNixHalf(h, partsDir, r)
        let extra = storeLocationIn(r, a) / "lib" / "extra"
        makeWritable(extra.parentDir)
        removeFile(extra)
        discard sh("nix-store --store " & quoteShell(r) & " --delete " &
          quoteShell(b))
        check not pathValid(r, b)
        if viaScript: runScript(r)
        else: restoreNixHalf(h, partsDir, r)
        check pathValid(r, b)
        check not fileExists(extra)
        if fileExists(extra): echo "    via restore.sh: ", viaScript

      # The garbage collector ignores path locks and holds gc.lock while it
      # collects: the restore waits for it before it registers anything.
      for viaScript in [false, true]:
        let r = top / (if viaScript: "gc-sh-root" else: "gc-root")
        let gcScratch = top / (if viaScript: "gc-sh" else: "gc-lib")
        createDir(gcScratch)
        let collector = holdCollectorLock(r, a, gcScratch)
        if viaScript: runScript(r)
        else: restoreNixHalf(h, partsDir, r)
        discard collector.waitForExit()
        collector.close()
        check waitedForCollector(gcScratch)
        check pathValid(r, a)

      # A Nix writer holds a path's lock while it waits for a collection;
      # the restore must not hold gc.lock while it waits for that path. The
      # collection deletes the lock files the restore already holds, so it
      # must notice and take them again. The writer locks the path the
      # restore locks last, so the restore holds every other lock then.
      let last = max(a, b)
      for viaScript in [false, true]:
        let r = top / (if viaScript: "daemon-sh-root" else: "daemon-root")
        let dScratch = top / (if viaScript: "daemon-sh" else: "daemon-lib")
        createDir(dScratch)
        let daemon = holdLockThenCollect(r, last, dScratch)
        if viaScript: runScript(r)
        else: restoreNixHalf(h, partsDir, r)
        discard daemon.waitForExit()
        daemon.close()
        check collectionRan(dScratch)
        check pathValid(r, a)
        check pathValid(r, b)
        let v = storeVerifies(r)
        check v.ok
        if not v.ok: echo v.output

suite "restore.sh from a local bundle directory":
  test "the bytes unpacked are the bytes verified, though the source changes":
    if findExe("nix-store").len == 0 or findExe("nix-hash").len == 0 or
        findExe("zstd").len == 0:
      skip("nix-store, nix-hash and zstd are needed to restore a Nix half")
    else:
      let top = createTempDir("repro-bundle-swap-", "")
      defer:
        discard execCmdEx("chmod -R u+w " & quoteShell(top))
        removeDir(top)
      let tree = top / "payload"
      createDir(tree)
      var big = newString(1 shl 19)
      var x = 0x9E3779B97F4A7C15'u64
      for i in 0 ..< big.len:
        x = x xor (x shl 13)
        x = x xor (x shr 7)
        x = x xor (x shl 17)
        big[i] = chr(int(x and 0xff))
      writeFile(tree / "big.so", big)
      writeFile(tree / "env.sh", "export T_REPRO_BUNDLE_SWAP=1\n")
      let a = sh("nix-store --add " & quoteShell(tree)).strip()
      let b = sh("nix-store --add " & quoteShell(tree / "env.sh")).strip()
      let bundle = top / "bundle"
      let partsDir = bundle / "x86_64-linux" / NixHalfDir / "h"
      let packed = packNixHalf(@[a, b], partsDir, 3, 128 * 1024)
      check packed.parts.len > 1
      let h = NixHalf(id: "h", system: "x86_64-linux",
        zstd: storePathOf(expandFilename(findExe("zstd"))), paths: @[a, b],
        unpackedBytes: packed.unpackedBytes,
        compressedBytes: packed.compressedBytes, parts: packed.parts,
        registration: packed.registration,
        shells: @[BundleShell(name: "t:default", input: a, env: b)])
      let script = top / "restore.sh"
      writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
        "name": "bundle"}, true, h))
      # A zstd that, at restore.sh's first call (the registration decompress,
      # after `sha256sum -c`), empties every part of the source directory:
      # what a writer of that directory could do between check and read.
      let tools = restoreScriptPath(top)
      let realZstd = findExe("zstd")
      removeFile(tools / "zstd")
      let marker = top / "swapped"
      writeFile(tools / "zstd", "#!/bin/sh\n" &
        "if [ ! -e " & quoteShell(marker) & " ]; then\n" &
        "  : > " & quoteShell(marker) & "\n" &
        "  for f in " & quoteShell(partsDir) & "/*; do case \"$f\" in */registration) ;; *) : > \"$f\" ;; esac; done\n" &
        "fi\nexec " & quoteShell(realZstd) & " \"$@\"\n")
      setFilePermissions(tools / "zstd",
        {fpUserRead, fpUserWrite, fpUserExec})
      let shRoot = top / "sh-root"
      let log = top / "restore.log"
      let env = "env -i PATH=" & quoteShell(tools) &
        " TMPDIR=" & quoteShell(top) &
        " REPRO_BUNDLE_LOG=" & quoteShell(log) &
        " REPRO_BUNDLE_NIX_ROOT=" & quoteShell(shRoot)
      discard execCmdEx(env & " bash " & quoteShell(script) & " " &
        quoteShell(bundle))
      check fileExists(marker)  # the swap really happened
      check "nix half restored" in readFile(log)
      check pathValid(shRoot, a)
      check intactFile(storeLocationIn(shRoot, a) / "big.so", big)

# ---------------------------------------------------------------------------
# A hostile bundle host
# ---------------------------------------------------------------------------

proc hostileHalf(honest: NixHalf; honestDir, bundleDir, id: string;
                 extras: openArray[tuple[base, member: string]]): NixHalf =
  ## The honest half's registration, with a stream that carries the honest
  ## store paths followed by `extras` (each `member` taken relative to its
  ## `base`), compressed, split and hashed the way the half's host could.
  ## It lives at `<bundleDir>/x86_64-linux/nix/<id>`, where restore.sh looks.
  let dir = bundleDir / "x86_64-linux" / NixHalfDir / id
  createDir(dir)
  let tarPath = dir.parentDir / (id & ".tar")
  var create = "tar --format=posix -C / -cf " & quoteShell(tarPath)
  for p in honest.paths: create.add(" " & quoteShell(p[1 .. ^1]))
  discard sh(create)
  for (base, member) in extras:
    discard sh("tar --format=posix -rf " & quoteShell(tarPath) & " -C " &
      quoteShell(base) & " " & quoteShell(member))
  let (parts, total) = writeCompressedParts("cat " & quoteShell(tarPath) &
    " | zstd -q -c -3 --long=27", dir, 128 * 1024)
  removeFile(tarPath)
  copyFile(honestDir / honest.registration.file,
    dir / honest.registration.file)
  result = honest
  result.id = id
  result.parts = parts
  result.compressedBytes = total

proc restoreShEnv(top, root, log: string): string =
  "env -i PATH=" & quoteShell(restoreScriptPath(top)) &
    " TMPDIR=" & quoteShell(top) & " REPRO_BUNDLE_STRICT=1" &
    " REPRO_BUNDLE_LOG=" & quoteShell(log) &
    " REPRO_BUNDLE_NIX_ROOT=" & quoteShell(root)

proc runRestoreSh(top: string; h: NixHalf; root, source: string;
                  extraEnv = ""): tuple[code: int; log: string] =
  ## restore.sh for `h`, rendered by the production renderer, run strict
  ## against `source` with the Nix half restored into `root`.
  let script = top / ("restore-" & h.id & ".sh")
  writeFile(script, renderRestoreScript(%*{"system": "x86_64-linux",
    "name": "bundle"}, true, h))
  let log = top / ("restore-" & h.id & "-" & extractFilename(root) & ".log")
  removeFile(log)
  let (output, code) = execCmdEx(restoreShEnv(top, root, log) & " " &
    extraEnv & " bash " & quoteShell(script) & " " & quoteShell(source))
  result = (code, (if fileExists(log): readFile(log) else: output))
  checkpoint "restore.sh exit " & $code & ":\n" & result.log

proc leftoverIntact(root, a: string): bool =
  ## Whether the truncated file `interruptedUnpack` left in `a` is still
  ## there: a refused half must not even clear the leftovers.
  let big = storeLocationIn(root, a) / "lib" / "big.so"
  fileExists(big) and getFileSize(big) == 4096

suite "a Nix half is confined to its registered store paths":
  test "members outside the registered paths are refused, by both entry points":
    if findExe("nix-store").len == 0 or findExe("nix-hash").len == 0 or
        findExe("zstd").len == 0:
      skip("nix-store, nix-hash and zstd are needed to restore a Nix half")
    else:
      let top = createTempDir("repro-bundle-hostile-", "")
      defer:
        discard execCmdEx("chmod -R u+w " & quoteShell(top))
        removeDir(top)
      let (a, b, c, _) = addPayloadPaths(top)
      let bundle = top / "bundle"
      let honestDir = bundle / "x86_64-linux" / NixHalfDir / "h"
      let h = packedHalf(@[a, b, c], honestDir, "h", a, b)
      # Outside the store altogether, and in a store path the half does not
      # register.
      let staging = top / "staging"
      createDir(staging / "etc")
      writeFile(staging / "etc" / "evil", "owned\n")
      let other = "nix/store/00000000000000000000000000000000-not-registered"
      createDir(staging / other)
      writeFile(staging / other / "evil", "owned\n")
      for (id, member, planted) in [
          ("etc", "etc/evil", "etc/evil"),
          ("other", other, other & "/evil")]:
        let evil = hostileHalf(h, honestDir, bundle, id, [(staging, member)])
        # The library path, over the state an interrupted unpack leaves.
        let root = top / ("lib-root-" & id)
        interruptedUnpack(honestDir, h, root)
        var refused = ""
        try: restoreNixHalf(evil, bundle / "x86_64-linux" / NixHalfDir / id,
          root)
        except CatchableError as e: refused = e.msg
        checkpoint "restoreNixHalf said: " & refused
        check member in refused
        check not fileExists(root / planted)
        check not pathValid(root, a)
        check not pathValid(root, b)
        check leftoverIntact(root, a)
        check outsideUntouched(root)
        # The bootstrap path.
        let shRoot = top / ("sh-root-" & id)
        interruptedUnpack(honestDir, h, shRoot)
        let (code, log) = runRestoreSh(top, evil, shRoot, bundle)
        check code != 0
        check member in log
        check "nix half restored" notin log
        check not fileExists(shRoot / planted)
        check not pathValid(shRoot, a)
        check not pathValid(shRoot, b)
        check leftoverIntact(shRoot, a)
        check outsideUntouched(shRoot)

  test "a member added inside an already-valid path is not written":
    if findExe("nix-store").len == 0 or findExe("nix-hash").len == 0 or
        findExe("zstd").len == 0:
      skip("nix-store, nix-hash and zstd are needed to restore a Nix half")
    else:
      let top = createTempDir("repro-bundle-valid-", "")
      defer:
        discard execCmdEx("chmod -R u+w " & quoteShell(top))
        removeDir(top)
      let (a, b, c, big) = addPayloadPaths(top)
      let bundle = top / "bundle"
      let honestDir = bundle / "x86_64-linux" / NixHalfDir / "h"
      let h = packedHalf(@[a, b, c], honestDir, "h", a, b)
      let onlyA = packedHalf(@[a], top / "only-a", "only-a", a, a)
      # `added` lies inside `a`, which is registered: the member list
      # accepts it. But `a` is already valid on the target, so it is Nix's,
      # and the restore must not write into it.
      let staging = top / "staging"
      let added = a[1 .. ^1] & "/lib/added"
      createDir(staging / added.parentDir)
      writeFile(staging / added, "planted\n")
      let evil = hostileHalf(h, honestDir, bundle, "add", [(staging, added)])
      for entry in ["lib", "sh"]:
        let root = top / (entry & "-root")
        restoreNixHalf(onlyA, top / "only-a", root)
        check pathValid(root, a)
        check not pathValid(root, b)
        # A store directory is read-only, which stops an unprivileged
        # restore from writing into it but not a root one (the setup-script
        # case). Making it writable lets this run see what root would.
        makeWritable(storeLocationIn(root, a) / "lib")
        if entry == "lib":
          restoreNixHalf(evil, bundle / "x86_64-linux" / NixHalfDir / "add",
            root)
        else:
          let (code, log) = runRestoreSh(top, evil, root, bundle)
          check "nix half restored" in log
          discard code # no `repro` to hand over to, so strict mode fails after
        check not fileExists(root / added)
        check pathValid(root, b)
        check pathValid(root, c)
        check intactFile(storeLocationIn(root, a) / "lib" / "big.so", big)

proc unfetchableHalf(): NixHalf =
  ## A Nix half whose store paths exist nowhere, for the cases refused before
  ## anything is fetched.
  NixHalf(id: "0123456789abcdef0123456789abcdef",
    zstd: "/nix/store/zzz-zstd-bin", repro: "",
    unpackedBytes: 1, compressedBytes: 1,
    parts: @[BundlePart(file: "part-0000", bytes: 5, sha256: "aa")],
    registration: BundlePart(file: "registration", bytes: 3, sha256: "ab"),
    shells: @[BundleShell(name: "lib:default",
      input: "/nix/store/00000000000000000000000000000000-in",
      env: "/nix/store/00000000000000000000000000000000-env")])

suite "bundles are fetched over https only":
  test "a plain http:// source is refused by both entry points":
    let top = createTempDir("repro-bundle-http-", "")
    defer: removeDir(top)
    # Port 9 (discard) on loopback: nothing is served there, so a fetch
    # that was not refused fails on its own, but with another message.
    for source in ["http://127.0.0.1:9/demo", "HTTP://127.0.0.1:9/demo"]:
      var refused = ""
      try: discard restoreBundle(RestoreOptions(source: source,
        workspaceDir: top / "ws"))
      except CatchableError as e: refused = e.msg
      checkpoint "restoreBundle said: " & refused
      check "refusing" in refused
      check "https://" in refused
    let h = unfetchableHalf()
    let (code, log) = runRestoreSh(top, h, top / "root",
      "http://127.0.0.1:9/demo")
    check code != 0
    check "refusing" in log
    check "https://" in log

  test "an http:// GitHub transport override is refused by both entry points":
    let top = createTempDir("repro-bundle-http-gh-", "")
    defer: removeDir(top)
    let h = unfetchableHalf()
    for (variable, other) in [("REPRO_BUNDLE_GITHUB_RAW",
                               "REPRO_BUNDLE_GITHUB_API"),
                              ("REPRO_BUNDLE_GITHUB_API",
                               "REPRO_BUNDLE_GITHUB_RAW")]:
      putEnv(variable, "http://127.0.0.1:9")
      # The other base exists nowhere, so nothing reaches the network.
      putEnv(other, "file://" & top / "nowhere")
      defer:
        delEnv(variable)
        delEnv(other)
      var refused = ""
      try: discard restoreBundle(RestoreOptions(
        source: "github:acme/bundles@0123abc/demo", workspaceDir: top / "ws"))
      except CatchableError as e: refused = e.msg
      checkpoint "restoreBundle said: " & refused
      check "refusing" in refused
      check variable in refused
      let (code, log) = runRestoreSh(top, h, top / "root",
        "github:acme/bundles@0123abc/demo", variable & "=http://127.0.0.1:9 " &
        other & "=" & quoteShell("file://" & top / "nowhere"))
      check code != 0
      check "refusing" in log
      check variable in log

# Workspace-Bundles.md §7 step 4: a sources half's members are checked
# against the checkouts and state files the half declares, and against
# symlinks, before anything is written. Each archive below is crafted with
# GNU tar to be what a hostile host or a buggy publisher could serve; the
# part hashes are right, because they come from the same unsigned manifest
# (§9). Regression tests for reprobuild-pm issue
# 2026-11-16-sources-half-extraction-is-not-checked-against-the-half-s-declared-checkouts.md.

proc craftedHalf(top, label, wsName: string; repos, state: openArray[string];
                 script: string): tuple[half: SourcesHalf; dir: string] =
  ## A sources half whose archive is whatever `script` (bash, run in an
  ## empty directory holding the file `f`) leaves in `archive.tar`, split
  ## into parts with their real hashes. The half declares `repos` as its
  ## checkouts and `state` as its carried state files, and says it was
  ## created at `/created/<wsName>`. Its id is well formed but is not the
  ## digest of its declarations; nothing here depends on that.
  let stage = top / ("stage-" & label)
  createDir(stage)
  writeFile(stage / "f", "planted\n")
  discard sh("bash -c " & quoteShell("set -e; " & script), stage)
  result.dir = top / ("parts-" & label)
  let (parts, total) = writeCompressedParts("cat " &
    quoteShell(stage / "archive.tar") & " | " &
    zstdCompressCommand(findExe("zstd"), 1, 0), result.dir, DefaultPartSize)
  result.half = SourcesHalf(id: repeat('a', 32),
    workspaceDir: "/created/" & wsName,
    parts: parts, compressedBytes: total)
  for r in repos:
    result.half.repos.add(SourceRepo(relPath: r, rev: repeat('0', 40)))
  for s in state:
    result.half.stateFiles.add((s, repeat('0', 64)))

proc addAs(names: varargs[string]): string =
  ## bash appending `f` to `archive.tar` once under each of `names`.
  for n in names:
    result.add("tar --format=posix -P --transform=" &
      quoteShell("flags=r;s|^f$|" & n & "|") & " -rf archive.tar f; ")

proc treeOf(dir: string): seq[string] =
  ## Every path under `dir`, links not followed, sorted.
  if not dirExists(dir): return
  for p in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}, relative = true):
    result.add(p)
  result.sort()

proc refusal(h: SourcesHalf; dir, ws: string): string =
  ## The restore's refusal message, or "" when it unpacked.
  try: discard restoreSourcesHalf(h, dir, ws)
  except BundleError as e: return e.msg

suite "sources half members are checked before anything is written":
  setup:
    let haveTools = findExe("zstd").len > 0 and findExe("tar").len > 0
    let top = createTempDir("repro-bundle-members-", "")
  teardown:
    removeDir(top)

  test "a member outside the workspace directory is refused":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let (h, dir) = craftedHalf(top, "sibling", "ws", ["."], [],
        addAs("ws/ok", "sibling/evil"))
      let parent = top / "restore"
      let msg = refusal(h, dir, parent / "ws")
      check "sibling/evil" in msg
      check treeOf(parent).len == 0

  test "a .. component and an absolute name are refused, not stripped":
    if not haveTools: skip("tar and zstd are needed")
    else:
      for (label, name, reason) in [
          ("dotdot", "ws/../evil", "not canonical"),
          ("abs", "/tmp/evil", "an absolute name"),
          ("dot", "ws/./x", "not canonical"),
          ("empty", "ws//x", "not canonical")]:
        let (h, dir) = craftedHalf(top, label, "ws", ["."], [], addAs(name))
        let parent = top / ("restore-" & label)
        let msg = refusal(h, dir, parent / "ws")
        check reason in msg
        check treeOf(parent).len == 0

  test "a member in no declared checkout or state file is refused":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let (h, dir) = craftedHalf(top, "undeclared", "ws", ["lib"],
        [".repro/workspace-state.toml"],
        addAs("ws/lib/a", "ws/.repro/workspace-state.toml", "ws/other/x"))
      let parent = top / "restore"
      let msg = refusal(h, dir, parent / "ws")
      check "ws/other/x" in msg
      check treeOf(parent).len == 0
      # The same declarations without the stray member restore, directories
      # on the way to a declared path included.
      let (good, goodDir) = craftedHalf(top, "declared", "ws", ["lib"],
        [".repro/workspace-state.toml"],
        "mkdir -p d/lib d/.repro; tar --format=posix --transform=" &
        quoteShell("s|^d|ws|") & " -cf archive.tar d; " &
        addAs("ws/lib/a", "ws/.repro/workspace-state.toml"))
      let ok = top / "restore-ok" / "ws"
      check refusal(good, goodDir, ok) == ""
      check readFile(ok / "lib" / "a") == "planted\n"
      check readFile(ok / ".repro" / "workspace-state.toml") == "planted\n"

  test "a member beneath a symlink member is refused":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let outside = top / "outside"
      createDir(outside)
      let (h, dir) = craftedHalf(top, "beneath", "ws", ["lib"], [],
        "ln -s " & quoteShell(outside) & " l; tar --format=posix " &
        "--transform=" & quoteShell("flags=r;s|^l$|ws/lib/l|") &
        " -cf archive.tar l; " & addAs("ws/lib/l/x"))
      let parent = top / "restore"
      let msg = refusal(h, dir, parent / "ws")
      check "below the symlink member" in msg
      check treeOf(parent).len == 0
      check treeOf(outside).len == 0

  test "duplicates, special files and a dangling hard link are refused":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let cases = [
        ("dup", addAs("ws/lib/a", "ws/lib/a"), "more than once"),
        ("fifo", "mkfifo p; tar --format=posix --transform=" &
          quoteShell("s|^p$|ws/lib/p|") & " -cf archive.tar p", "type"),
        ("hardlink", "ln f h; tar --format=posix --transform=" &
          quoteShell("flags=rh;s|^f$|ws/lib/a|;s|^h$|ws/lib/b|") &
          " -cf archive.tar f h; tar --delete -f archive.tar ws/lib/a",
          "hard link")]
      for (label, script, reason) in cases:
        let (h, dir) = craftedHalf(top, label, "ws", ["lib"], [], script)
        let parent = top / ("restore-" & label)
        let msg = refusal(h, dir, parent / "ws")
        check reason in msg
        check treeOf(parent).len == 0

  test "the half's own declarations must be canonical":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let (badName, dir1) = craftedHalf(top, "name", "..", ["."], [],
        addAs("../x"))
      check "workspace directory name" in refusal(badName, dir1,
        top / "r1" / "ws")
      let (badRepo, dir2) = craftedHalf(top, "repo", "ws", ["../up"], [],
        addAs("ws/../up/x"))
      check "checkout path" in refusal(badRepo, dir2, top / "r2" / "ws")
      let (badState, dir3) = craftedHalf(top, "state", "ws", ["lib"],
        ["/etc/x"], addAs("ws/lib/a"))
      check "state file" in refusal(badState, dir3, top / "r3" / "ws")
      check treeOf(top / "r1").len == 0
      check treeOf(top / "r2").len == 0
      check treeOf(top / "r3").len == 0

  test "a symlink already on disk inside the workspace is not followed":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let outside = top / "outside"
      createDir(outside)
      for membersOnly in [false, true]:
        let label = (if membersOnly: "members-only" else: "whole")
        let (h, dir) = craftedHalf(top, label, "ws", [".", "lib"], [],
          addAs("ws/README", "ws/lib/sub/a"))
        let ws = top / ("restore-" & label) / "ws"
        createDir(ws)
        if membersOnly: createDir(ws / ".git")
        createSymlink(outside, ws / "lib")
        let before = treeOf(ws)
        let msg = refusal(h, dir, ws)
        check "symlink" in msg
        check (ws / "lib") in msg
        check treeOf(ws) == before
        check treeOf(outside).len == 0

  test "a restore under another name renames only the top directory":
    if not haveTools: skip("tar and zstd are needed")
    else:
      # A regex in the creating name, and `\`, `&` and `,` in the target
      # name, must neither widen nor break the rename.
      let (h, dir) = craftedHalf(top, "rename", ".*q", ["lib"], [],
        "ln -s .*q/x s; tar --format=posix --transform=" &
        quoteShell("flags=r;s|^s$|.*q/lib/s|") & " -cf archive.tar s; " &
        addAs(".*q/lib/a"))
      let parent = top / "restore"
      let base = "dst&,\\x"
      let ws = parent / base
      check refusal(h, dir, ws) == ""
      check readFile(ws / "lib" / "a") == "planted\n"
      check expandSymlink(ws / "lib" / "s") == ".*q/x"
      for p in treeOf(parent):
        check p == base or p.startsWith(base & "/")

  test "an option-like top directory name is a name, not a tar option":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let name = "--to-command=touch pwned;#"
      let (h, dir) = craftedHalf(top, "option", name, [".", "lib"], [],
        addAs(name & "/lib/a"))
      for same in [true, false]:
        let parent = top / ("restore-" & $same)
        let ws = parent / (if same: name else: "ws")
        createDir(ws / ".git")
        check refusal(h, dir, ws) == ""
        check readFile(ws / "lib" / "a") == "planted\n"
        check not fileExists(parent / "pwned")
        check not fileExists(getCurrentDir() / "pwned")

  test "the archive cannot take the place of the restore's marker":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let outside = top / "outside"
      createDir(outside)
      let cases = [
        ("link", "ln -s " & quoteShell(outside) & " l; tar --format=posix " &
          "--transform=" & quoteShell("flags=r;s|^l$|ws/.repro|") &
          " -cf archive.tar l", "directory .repro"),
        ("marker", addAs("ws/.repro/bundle-sources-id"), "marker")]
      for (label, script, reason) in cases:
        let (h, dir) = craftedHalf(top, label, "ws", ["."], [], script)
        let parent = top / ("restore-" & label)
        let msg = refusal(h, dir, parent / "ws")
        check reason in msg
        check treeOf(parent).len == 0
        check treeOf(outside).len == 0

  test "ids, checkout paths and state files are held to their shapes":
    if not haveTools: skip("tar and zstd are needed")
    else:
      var (badId, dir1) = craftedHalf(top, "id", "ws", ["lib"], [],
        addAs("ws/lib/a"))
      badId.id = "../../x"
      check "id" in refusal(badId, dir1, top / "r1" / "ws")
      let (inGit, dir2) = craftedHalf(top, "git", "ws", [".git/info"], [],
        addAs("ws/.git/info/exclude"))
      check ".git" in refusal(inGit, dir2, top / "r2" / "ws")
      let (newline, dir3) = craftedHalf(top, "newline", "ws", ["a\nb"], [],
        addAs("ws/lib/a"))
      check "checkout path" in refusal(newline, dir3, top / "r3" / "ws")
      let (beneath, dir4) = craftedHalf(top, "beneath-state", "ws", ["lib"],
        ["workspace-projects.md"], addAs("ws/workspace-projects.md/evil"))
      check "lies in no checkout" in refusal(beneath, dir4, top / "r4" / "ws")
      for r in ["r1", "r2", "r3", "r4"]:
        check treeOf(top / r).len == 0

  test "members-only, a hard link to a member left on disk is refused":
    if not haveTools: skip("tar and zstd are needed")
    else:
      let (h, dir) = craftedHalf(top, "alias", "ws", [".", "lib"], [],
        "ln f h; tar --format=posix --transform=" &
        quoteShell("flags=rh;s|^f$|ws/.git/config|;s|^h$|ws/lib/h|") &
        " -cf archive.tar f h")
      let ws = top / "restore" / "ws"
      createDir(ws / ".git")
      writeFile(ws / ".git" / "config", "mine\n")
      let before = treeOf(ws)
      let msg = refusal(h, dir, ws)
      check "does not unpack" in msg
      check treeOf(ws) == before
