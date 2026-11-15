## Workspace bundles (docs/workspace-bundles.md): the parts of `repro bundle`
## that need no Nix build, against real git repositories, GNU tar and zstd on
## a temporary filesystem. No mocks.
##
## Building a Nix half from dev shells, publishing and the full restore are
## exercised end to end by the procedure recorded in docs/workspace-bundles.md
## (they need flakes and an S3 endpoint). Restoring a Nix half is tested here
## against the real `nix-store`, `nix-hash`, tar and zstd, into a store under
## another root, with store paths this test adds to the host's store.

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

const RestoreScriptTools = ["bash", "sh", "nix-store", "nix-hash", "tar",
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
      # Two store paths of our own: a tree with a 1 MiB file, and a file.
      let tree = top / "payload"
      createDir(tree / "lib")
      var big = newString(1 shl 20)
      # xorshift: incompressible, so the stream spans several parts, and
      # the same on every run, so the store path is too.
      var x = 0x9E3779B97F4A7C15'u64
      for i in 0 ..< big.len:
        x = x xor (x shl 13)
        x = x xor (x shr 7)
        x = x xor (x shl 17)
        big[i] = chr(int(x and 0xff))
      writeFile(tree / "lib" / "big.so", big)
      writeFile(tree / "env.sh", "export T_REPRO_BUNDLE=1\n")
      let a = sh("nix-store --add " & quoteShell(tree)).strip()
      let b = sh("nix-store --add " & quoteShell(tree / "env.sh")).strip()
      createSymlink("env.sh", top / "link")
      let c = sh("nix-store --add " & quoteShell(top / "link")).strip()
      let partsDir = top / "bundle" / "x86_64-linux" / NixHalfDir / "h"
      let packed = packNixHalf(@[a, b, c], partsDir, 3, 128 * 1024)
      check packed.parts.len > 1
      var h = NixHalf(id: "h", system: "x86_64-linux",
        zstd: storePathOf(expandFilename(findExe("zstd"))), paths: @[a, b, c],
        unpackedBytes: packed.unpackedBytes,
        compressedBytes: packed.compressedBytes, parts: packed.parts,
        registration: packed.registration,
        shells: @[BundleShell(name: "t:default", input: a, env: b)])

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
