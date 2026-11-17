## A workspace bundle of a selection, published and then restored on a
## plain Linux machine (a container with no Nix store, no Reprobuild store
## and no cache), builds the selection without running any of the work it
## carries, and produces the exporter's outputs.
##
## THE MACHINES. The exporter is this host. The plain machine is a rootless
## podman container of `debian:bookworm-slim` (pulled once; a stock distro
## image, so nothing Nix or Reprobuild put there), run with `--network=none`.
## Its only additions are three statically linked tools bind-mounted read-only
## at `/opt/tools`, the ones a cloud session's setup needs before the bundle
## brings its own: `nix` (as `nix-store` and `nix-hash`), `zstd` and `curl`,
## from nixpkgs' `pkgsStatic`. They live outside `/nix`, so the container has
## no store contents before the restore.
##
## THE REPRO. The bundle carries the `repro` that restores it (its Nix half
## holds the package's store path), and a native half only imports into the
## same `repro` that made it. So the exporter runs the PACKAGED `repro` of
## this tree (`nix build git+file://<tree>#reprobuild`, or the store path in
## `REPRO_BUNDLE_E2E_REPRO`), not `build/bin/repro`.
##
## THE FLOW.
## 1. A workspace with three repositories (`bundle_selection_fixture`) and a
##    root flake whose dev shell carries the C toolchain and git. The root
##    shell's environment is captured once with `repro bundle create`
##    (Nix half only), and every build on both machines runs in it with the
##    same minimal environment (`env -i`, the same HOME, TMPDIR and roots).
## 2. All three repositories are built on the exporter.
## 3. `repro bundle create pair` writes the bundle of alpha and beta (all
##    three halves) and `pair-control` the same without its native half.
##    `repro bundle inspect` reads the roots to provision from the bundle.
## 4. `repro bundle publish --to=github:local/bundles` pushes both to a bare
##    repository (`REPRO_BUNDLE_GITHUB_REMOTE=file://…`). The published
##    branches are laid out as raw.githubusercontent.com serves them
##    (`<repo>/<ref>/<path>`), and the container reads them through
##    `REPRO_BUNDLE_GITHUB_RAW=file://…`.
## 5. In the container: the vacuity guard, then the roots `inspect` named are
##    provisioned (their parent directories created), then the bundle's
##    `restore.sh` restores the Nix half and hands over to the restored
##    `repro`, which restores the sources and native halves. Then alpha and
##    beta are built, with the engine's cache evidence written to a report.
##
## WHAT IT REQUIRES. In the restored container every action of alpha's and
## beta's build graphs is a cache hit that did not launch (the engine's
## `launched` and `cacheDecision`), and their outputs are byte-identical to
## the exporter's (SHA-256). gamma, which the selection left out, has no
## checkout there. The engine's own edges for each project, the provider
## compile and the interface extraction, whose records the bundle carries as
## well, must find those records (the same key on both machines); each is a
## hit or, the one recorded limit, a miss that names a file of the
## exporter's own `/bin/sh` closure, which the bundle does not carry: the
## Nim compiler starts the C compiler through `/bin/sh`, the edge records
## what that reads, and a Debian `/bin/sh` is not a NixOS one. That limit is
## a known defect, not the intended behaviour: once those compiles no longer
## depend on the host's `/bin/sh`, this gate requires every one of them to
## hit as well.
##
## `REPRO_BUNDLE_E2E_KEEP=1` keeps the scratch directory (bundles, the
## published repository, the reports and each container's `.repro` state)
## for a person investigating a failure.
##
## VACUITY GUARD. Before the restore the container has no `/nix`, none of
## the bundle's roots and no `repro` on PATH; the script fails otherwise and
## the test checks the marker it writes.
##
## NEGATIVE CONTROL. The same in a fresh container from `pair-control` (no
## native half): the build executes the produce edges, and still produces
## the same bytes. So the hits above come from the restored native half.
##
## THE GATE. The test needs podman, a Nix store with network access to
## cache.nixos.org on the exporter (for the static tools) and a packaged
## build of this tree, so the ordinary suite skips it with that reason, the
## way the add-on's VM gates are skipped. `just
## e2e_bundle_restores_on_a_plain_machine` runs it
## (`REPRO_BUNDLE_CONTAINER_GATE=1`). When the gate is on and podman cannot
## run a container, the test FAILS: it never passes without a container.
##
## MOCKS. One stand-in, justified: raw.githubusercontent.com is replaced by
## the same `<repo>/<ref>/<path>` layout on disk, written with `git archive`
## from the branches `repro bundle publish` pushed, and read by curl through
## `file://`. Reaching GitHub would need the network and credentials, and the
## layout is the only thing the restore reads from it. Everything else is
## real: the packaged `repro`, podman, Nix's own store tools, GNU tar, zstd,
## git, the engine's monitor and action cache.

import std/[json, os, osproc, streams, strutils, tables, tempfiles,
  unittest]

import repro_test_support/reasoned_skip
import ../../integration/bundle_selection_fixture

const
  Gate = "REPRO_BUNDLE_CONTAINER_GATE"
  Image = "docker.io/library/debian:bookworm-slim"
  RawRepo = "local/bundles"

proc sh(cmd: string; cwd = ""): string =
  ## Run `cmd`; its stdout is the result (Nix's warnings on stderr must not
  ## become part of a store path), its stderr is shown only on failure.
  let errFile = getTempDir() / ("repro-bundle-e2e-stderr-" &
    $getCurrentProcessId())
  let p = startProcess("/bin/sh", workingDir = cwd,
    args = ["-c", "(" & cmd & ") 2>" & quoteShell(errFile)], options = {})
  result = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  let errText = (if fileExists(errFile): readFile(errFile) else: "")
  if fileExists(errFile): removeFile(errFile)
  if code != 0:
    raise newException(OSError, "`" & cmd & "` failed (exit " & $code &
      "):\n" & result & errText)

proc nixBuild(installable: string): string =
  sh("nix build --no-link --print-out-paths --inputs-from " &
    quoteShell(ReprobuildRoot) & " " & quoteShell(installable)).strip()
    .splitLines()[^1]

proc packagedRepro(): string =
  ## The store path of this tree's `repro` package.
  result = getEnv("REPRO_BUNDLE_E2E_REPRO")
  if result.len == 0:
    result = sh("nix build --no-link --print-out-paths " &
      quoteShell("git+file://" & ReprobuildRoot & "#reprobuild")).strip()
      .splitLines()[^1]
  if not fileExists(result / "bin" / "repro"):
    raise newException(IOError, "no packaged repro at " & result)

type Machine = object
  base: string          ## everything lives under it, on both machines
  ws, store, ac, home, tmp: string
  repro: string         ## the packaged repro's store path
  envFile: string       ## the root dev shell's captured environment
  bash: string          ## the machine's own bash (`env -i` clears PATH)
  cc: string            ## the wrapped C compiler the recipes compile with

proc cleanEnv(m: Machine): string =
  ## The environment every build runs in, on both machines.
  # PATH is set, to the same value on both machines: the captured shell
  # environment appends the invoking PATH to its own, and an unset one is
  # bash's compiled-in default, which differs between distributions.
  "env -i PATH=/usr/bin:/bin HOME=" & quoteShell(m.home) & " TMPDIR=" &
    quoteShell(m.tmp) &
    " USER=root LANG=C.UTF-8 REPRO_STORE_ROOT=" & quoteShell(m.store) &
    " REPROBUILD_ACTION_CACHE_ROOT=" & quoteShell(m.ac) &
    " REPRO_CACHE_DISABLE=1 XDG_CONFIG_HOME=" & quoteShell(m.home / ".config") &
    " XDG_CACHE_HOME=" & quoteShell(m.home / ".cache") &
    " XDG_DATA_HOME=" & quoteShell(m.home / ".local/share") &
    " XDG_STATE_HOME=" & quoteShell(m.home / ".local/state") &
    # The compiler selection must be the same on both machines (the recipe
    # and provider compiles key on it), and the plain machine has no Nix to
    # provision the pinned one: the root shell's own wrapped gcc, which the
    # Nix half carries.
    " REPRO_BOOTSTRAP_CC=" & quoteShell(m.cc)

proc buildCommand(m: Machine; repo, report: string): string =
  ## `repro build` of one repository in the root shell's environment.
  cleanEnv(m) & " " & quoteShell(m.bash) & " -c " &
    quoteShell(". " & quoteShell(m.envFile) &
    " && cd " & quoteShell(m.ws / repo) & " && exec " &
    quoteShell(m.repro / "bin" / "repro") & " build --daemon=off " &
    "--no-runquota --tool-provisioning=path --action-cache-root=" &
    quoteShell(m.ac) & " --measure=trace,cache-evidence --log=actions " &
    "--write-report=" & quoteShell(report))

proc writeRootFlake(ws, nixpkgs: string) =
  writeFile(ws / "flake.nix", """{
  inputs.nixpkgs.url = "path:NIXPKGS";
  outputs = { self, nixpkgs }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.git pkgs.gnutar pkgs.zstd ];
      };
    };
}
""".replace("NIXPKGS", nixpkgs))
  discard sh("git add flake.nix && nix flake lock && git add flake.lock && " &
    "git -c user.email=fixture@example.invalid -c user.name=fixture " &
    "-c commit.gpgsign=false commit -q -m flake", ws)

proc materializeRaw(bare, raw: string) =
  ## raw.githubusercontent.com's layout of every pushed branch, and of the
  ## commit `latest` points at.
  var refs: seq[string]
  for line in sh("git --git-dir=" & quoteShell(bare) &
      " for-each-ref --format='%(refname:short)' refs/heads").splitLines():
    if line.strip().len > 0: refs.add(line.strip())
  refs.add(sh("git --git-dir=" & quoteShell(bare) &
    " rev-parse refs/heads/latest").strip())
  for r in refs:
    let dest = raw / RawRepo / r
    createDir(dest)
    discard sh("git --git-dir=" & quoteShell(bare) & " archive " &
      quoteShell(r) & " | tar -x -C " & quoteShell(dest))

proc containerScript(host: Machine; latestRef, bundle: string;
                     provision: seq[string]): string =
  ## What the plain machine runs: the vacuity guard, provisioning, the
  ## bundle's own restore.sh, then the builds.
  var m = host
  m.bash = "/bin/bash"
  result = "set -uo pipefail\nexport PATH=/opt/tools:/usr/sbin:/usr/bin:/sbin:/bin\n"
  result.add("fail() { echo \"container: $*\"; exit 1; }\n")
  # Vacuity guard: no store, no roots, no repro.
  result.add("[ ! -e /nix ] || fail '/nix exists before the restore'\n")
  for p in [m.base, m.store, m.ac, m.ws]:
    result.add("[ ! -e " & quoteShell(p) & " ] || fail " &
      quoteShell(p & " exists before the restore") & "\n")
  result.add("! command -v repro >/dev/null || fail 'repro is on PATH'\n")
  result.add("echo plain > /results/plain-" & bundle & "\n")
  # Provision the roots `repro bundle inspect` named, at the same paths.
  for p in provision & @[m.home, m.tmp]:
    result.add("mkdir -p " & quoteShell(p.parentDir) & "\n")
  result.add("mkdir -p " & quoteShell(m.home) & " " & quoteShell(m.tmp) & "\n")
  result.add("export NIX_CONFIG='build-users-group ='\n")
  result.add(cleanEnv(m) & " PATH=\"$PATH\" NIX_CONFIG=\"$NIX_CONFIG\" " &
    "REPRO_BUNDLE_STRICT=1 REPRO_BUNDLE_LOG=/results/restore-" & bundle &
    ".log REPRO_BUNDLE_GITHUB_RAW=file:///srv/raw " &
    "REPRO_BUNDLE_GITHUB_API=file:///srv/no-api bash " &
    quoteShell("/srv/raw/" & RawRepo & "/" & latestRef & "/" & bundle &
      "/x86_64-linux/restore.sh") & " " &
    quoteShell("github:" & RawRepo & "@" & latestRef & "/" & bundle) &
    " --allow-dev-env || fail 'restore failed'\n")
  result.add("[ -e " & quoteShell(m.ws / "gamma") &
    " ] && fail 'gamma was restored' || true\n")
  for repo in ["alpha", "beta"]:
    result.add(buildCommand(m, repo, "/results/report-" & bundle & "-" &
      repo & ".json") & " > /results/build-" & bundle & "-" & repo &
      ".log 2>&1 || fail 'build of " & repo & " failed'\n")
    result.add("sha256sum " & quoteShell(m.ws / repo / outputRel(repo)) &
      " | cut -d' ' -f1 > /results/sum-" & bundle & "-" & repo & "\n")
    # For a failure's diagnosis: the engine's project state after the build.
    result.add("tar -C " & quoteShell(m.ws / repo) & " -cf /results/state-" &
      bundle & "-" & repo & ".tar .repro || true\n")
  result.add("echo done > /results/done-" & bundle & "\n")

suite "a bundle restores on a plain machine without rebuilding":
  test "a published selection bundle restored in a plain container builds with no producer action":
    if getEnv(Gate) != "1":
      skip("container gate: set " & Gate & "=1 to run it " &
        "(just e2e_bundle_restores_on_a_plain_machine); it needs podman, " &
        "Nix and a packaged build of this tree")
    else:
      # The gate is on: a missing container runtime is a failure.
      let probe = execCmdEx("podman run --rm --network=none " & Image &
        " true")
      checkpoint("podman probe, exit " & $probe.exitCode & ":\n" &
        probe.output)
      require probe.exitCode == 0

      let base = createTempDir("repro-bundle-e2e-", "")
      defer:
        if getEnv("REPRO_BUNDLE_E2E_KEEP") == "1":
          # For a person investigating a failure: everything stays.
          echo "kept: " & base
        else:
          # The container's files are ours (rootless podman maps its root to
          # the invoking user); store paths unpacked read-only need +w first.
          discard execCmdEx("chmod -R u+w " & quoteShell(base))
          removeDir(base)
      var m = Machine(base: base, ws: base / "ws", store: base / "store",
        ac: base / "action-cache", home: base / "home", tmp: base / "tmp",
        bash: findExe("bash"))
      createDir(m.home)
      createDir(m.tmp)
      m.repro = packagedRepro()
      checkpoint("packaged repro: " & m.repro)

      let tools = base / "tools"
      createDir(tools)
      let nixStatic = nixBuild("nixpkgs#pkgsStatic.nix")
      copyFile(expandSymlink(nixStatic / "bin" / "nix"), tools / "nix")
      copyFile(nixBuild("nixpkgs#pkgsStatic.zstd.bin") / "bin" / "zstd",
        tools / "zstd")
      copyFile(nixBuild("nixpkgs#pkgsStatic.curl.bin") / "bin" / "curl",
        tools / "curl")
      for t in ["nix", "zstd", "curl"]:
        setFilePermissions(tools / t, {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      createSymlink("nix", tools / "nix-store")
      createSymlink("nix", tools / "nix-hash")
      let zstdPath = nixBuild("nixpkgs#zstd.bin")
      m.cc = nixBuild("nixpkgs#stdenv.cc") / "bin" / "gcc"
      let nixpkgs = sh("nix eval --raw --inputs-from " &
        quoteShell(ReprobuildRoot) & " nixpkgs#path").strip()

      writeWorkspace(m.ws)
      writeRootFlake(m.ws, nixpkgs)
      let r = quoteShell(m.repro / "bin" / "repro")
      let roots = " --workspace-root=" & quoteShell(m.ws) & " --store-root=" &
        quoteShell(m.store) & " --action-cache-root=" & quoteShell(m.ac) &
        " --repro=" & quoteShell(m.repro) & " --zstd=" & quoteShell(zstdPath) &
        " --level=3"
      # 1. The root shell's environment, as the bundle will carry it.
      discard sh(cleanEnv(m) & " PATH=" & quoteShell(getEnv("PATH")) & " " &
        r & " bundle create all --no-sources --no-native --out=" &
        quoteShell(base / "probe") & roots, m.ws)
      let probeLatest = parseJson(readFile(base / "probe" / "all" /
        "x86_64-linux" / "latest.json"))
      m.envFile = probeLatest["halves"]["nix"]["shells"]["workspace:default"][
        "env"].getStr()
      checkpoint("root shell environment: " & m.envFile)

      # 2. Build everything on the exporter.
      var hostSums = initTable[string, string]()
      for repo in Repos:
        let report = base / ("report-host-" & repo & ".json")
        let log = sh(buildCommand(m, repo, report))
        checkpoint("host build of " & repo & ":\n" & log)
        let run = parseJson(readFile(report))
        var launched = false
        for a in run["actions"]:
          if a["id"].getStr() == produceEdge(repo) and
              a{"launched"}.getBool(): launched = true
        require launched
        hostSums[repo] = sh("sha256sum " &
          quoteShell(m.ws / repo / outputRel(repo)) & " | cut -d' ' -f1").strip()

      # 3. The bundles, and the roots they need.
      for (name, extra) in [("pair", ""),
                            ("pair-control", " --no-native --name=pair-control")]:
        discard sh(cleanEnv(m) & " PATH=" & quoteShell(getEnv("PATH")) & " " &
          r & " bundle create pair --out=" & quoteShell(base / "out") & roots &
          extra, m.ws)
      var nixHalfPaths: seq[string]
      for p in parseJson(readFile(base / "out" / "pair" / "x86_64-linux" /
          "latest.json"))["halves"]["nix"]["paths"]:
        nixHalfPaths.add(p.getStr())
      let inspected = parseJson(sh(r & " bundle inspect " &
        quoteShell(base / "out" / "pair") & " --json"))
      checkpoint("inspect: " & $inspected)
      let pr = inspected["provision"]
      require pr["storeRoot"].getStr() == m.store
      require pr["actionCacheRoot"].getStr() == m.ac
      require pr["workspaceDir"].getStr() == m.ws
      require pr["nixStore"].getStr() == "/nix/store"
      var provision = @[pr["storeRoot"].getStr(), pr["actionCacheRoot"].getStr(),
        pr["workspaceDir"].getStr()]
      for w in pr["workspaceRoots"]: provision.add(w.getStr())

      # 4. Publish both to a bare repository, and lay it out as raw files.
      let remote = base / "remote"
      let bare = remote / RawRepo
      createDir(bare)
      discard sh("git init -q --bare " & quoteShell(bare))
      for name in ["pair", "pair-control"]:
        discard sh("REPRO_BUNDLE_GITHUB_REMOTE=" &
          quoteShell("file://" & remote) & " " & r & " bundle publish " &
          quoteShell(base / "out" / name) & " --to=github:" & RawRepo)
      let raw = base / "raw"
      materializeRaw(bare, raw)
      let latestRef = sh("git --git-dir=" & quoteShell(bare) &
        " rev-parse refs/heads/latest").strip()

      # 5. The plain machines.
      let results = base / "results"
      createDir(results)
      for bundle in ["pair", "pair-control"]:
        let script = base / ("container-" & bundle & ".sh")
        writeFile(script, containerScript(m, latestRef, bundle, provision))
        let res = execCmdEx("podman run --rm --network=none -v " &
          quoteShell(tools & ":/opt/tools:ro") & " -v " &
          quoteShell(raw & ":/srv/raw:ro") & " -v " &
          quoteShell(results & ":/results") & " -v " &
          quoteShell(script & ":/srv/run.sh:ro") & " " & Image &
          " bash /srv/run.sh")
        var logs = ""
        for kind, f in walkDir(results):
          if bundle in f.extractFilename and f.endsWith(".log"):
            logs.add("--- " & f.extractFilename & "\n" & readFile(f))
        checkpoint("container " & bundle & ", exit " & $res.exitCode & ":\n" &
          res.output & "\n" & logs)
        require res.exitCode == 0
        # Vacuity guard: the container was plain before the restore.
        check fileExists(results / ("plain-" & bundle))
        require fileExists(results / ("done-" & bundle))

      for repo in ["alpha", "beta"]:
        # Restored: every action of the build is a hit that did not launch.
        let restored = parseJson(readFile(results / ("report-pair-" & repo &
          ".json")))
        var sawProduce = false
        for a in restored["actions"]:
          let id = a["id"].getStr()
          checkpoint("restored " & repo & ": " & id & " launched=" &
            $a{"launched"}.getBool() & " cache=" & a{"cacheDecision"}.getStr() &
            " miss=" & a{"cacheMissReason"}.getStr())
          if id == produceEdge(repo): sawProduce = true
          check not a{"launched"}.getBool()
          check a{"cacheDecision"}.getStr() == "cdHit"
        check sawProduce
        # The engine's own edges for the project (the provider compile and
        # the interface extraction). The bundle carries their records too,
        # and they must be FOUND (same key on both machines). They are hits,
        # except for the one recorded limit: the compiler they run starts the
        # C compiler through the machine's `/bin/sh`, whose files the edge
        # records as inputs, and a plain Debian machine's `/bin/sh` is not
        # the exporter's (a known defect; see the header).
        # Such a miss must name a file of the exporter that the bundle does
        # not carry, and nothing else.
        check restored{"providerCompileActions"}.getElems().len > 0
        check restored{"interfaceExtractActions"}.getElems().len > 0
        for key in ["providerCompileActions", "interfaceExtractActions"]:
          for a in restored{key}.getElems():
            let reason = a{"cacheMissReason"}.getStr()
            checkpoint("restored " & repo & ": " & a["id"].getStr() &
              " launched=" & $a{"launched"}.getBool() & " cache=" &
              a{"cacheDecision"}.getStr() & " miss=" & reason)
            if a{"cacheDecision"}.getStr() == "cdHit":
              check not a{"launched"}.getBool()
              continue
            # Found, and refused only for a host file outside the bundle.
            check "candidate record considered" in reason
            check reason.startsWith("input changed: /nix/store/")
            let changed = reason["input changed: ".len .. ^1].split(' ')[0]
            let storePath = "/nix/store/" &
              changed["/nix/store/".len .. ^1].split('/')[0]
            check storePath notin nixHalfPaths
        check readFile(results / ("sum-pair-" & repo)).strip() ==
          hostSums[repo]
        # Negative control: without the native half, the producer runs.
        let control = parseJson(readFile(results / ("report-pair-control-" &
          repo & ".json")))
        var controlLaunched = false
        for a in control["actions"]:
          if a["id"].getStr() == produceEdge(repo) and
              a{"launched"}.getBool(): controlLaunched = true
        check controlLaunched
        check readFile(results / ("sum-pair-control-" & repo)).strip() ==
          hostSums[repo]
