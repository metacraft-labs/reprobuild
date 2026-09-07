## NF-4 — activating a whole flake from `repro.nim` (§2b's degenerate end).
##
## Three claims, against a real `nix`, a real git repo, a real flake with a
## real `--override-input path:` sibling, and the real monitored dev-env edge:
##
##   1. the shell Reprobuild produces is the shell `nix develop` produces;
##   2. the manifest Reprobuild OBSERVES contains what `direnv`'s DECLARED
##      `watch_file` set misses — all three failure modes §2b records;
##   3. re-entry decides staleness without re-evaluating the flake.
##
## MOCKS: none. `nix` is real (the fixture's `nixpkgs` input is the host's own
## registry entry, resolved to a store path, so nothing here needs the
## network), `git` is real, the flake is real, and the dev-env edge is the same
## `computeDevEnvEdge` the `repro shell` / direnv-activation paths call. The one
## interposition is a counting WRAPPER around the real `nix`
## (`REPRO_FOREIGN_ENV_NIX`, honoured by `foreign_env/flake.nim`): it appends a
## byte to a file and then `exec`s the real binary, so it changes nothing about
## the evaluation and exists only so claim 3 can assert that no evaluation was
## SPAWNED rather than that re-entry was merely fast. Its counter lives under
## `/dev/shm`, which the engine's `isVolatileMonitorPath` filter drops from
## evidence, so the wrapper cannot itself perturb the invalidation it measures.
##
## `nix` is a hard requirement, not a skip. This follows the precedent set by
## the M5 direnv gate in `Reprobuild-Dev-Environments.milestones.org`
## ("The test must not skip when direnv is missing in the test environment;
## the environment must provide direnv or the gate must fail"): a gate whose
## subject is a foreign provisioner is worthless if the absence of that
## provisioner reads as success.

import std/[os, osproc, sequtils, streams, strtabs, strutils, tempfiles,
  unittest]

import repro_build_engine
import repro_dev_env_artifacts
import repro_dev_env_engine
import repro_provider_runtime
import repro_test_support

const NixSystem =
  when defined(macosx):
    when defined(arm64): "aarch64-darwin" else: "x86_64-darwin"
  else:
    when defined(arm64): "aarch64-linux" else: "x86_64-linux"

const PathSentinel = "/repro-nf4-path-sentinel"
  ## A directory that does not exist, used as the whole `PATH` of the
  ## `nix develop` comparison run. Everything before it in the resulting `PATH`
  ## is exactly what the dev shell contributed, with nothing of the test
  ## harness's own environment mixed in.

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc runTool(exe: string; args: openArray[string]; workDir = "";
             env: StringTableRef = nil):
    tuple[output, error: string, code: int] =
  var process = startProcess(exe, workDir, args, env, {})
  try:
    let outText = process.outputStream().readAll()
    let errText = process.errorStream().readAll()
    result = (outText, errText, process.waitForExit())
  finally:
    process.close()

proc nixExe(): string =
  let found = findExe("nix")
  doAssert found.len > 0,
    "NF-4's flake gate needs `nix` on PATH. Install nix (or run the suite " &
    "inside the repo dev shell); this gate must not pass without it."
  found

proc bashExe(): string =
  let found = findExe("bash")
  doAssert found.len > 0, "NF-4's flake gate needs `bash` on PATH."
  found

proc gitExe(): string =
  let found = findExe("git")
  doAssert found.len > 0, "NF-4's flake gate needs `git` on PATH."
  found

proc nixArgs(rest: openArray[string]): seq[string] =
  # The host may or may not have the flake features enabled in nix.conf, and a
  # gate that depends on the host's nix.conf is a gate that reports the host.
  result = @["--extra-experimental-features", "nix-command flakes"]
  for item in rest:
    result.add(item)

proc resolveLocalNixpkgs(): string =
  ## The host's own `nixpkgs` registry entry, resolved to the store path it
  ## already points at. Using it as a `path:` input keeps the fixture flake
  ## buildable with no network access at all.
  let probe = runTool(nixExe(),
    nixArgs(["flake", "metadata", "nixpkgs", "--json"]))
  doAssert probe.code == 0,
    "NF-4's flake gate needs a resolvable `nixpkgs` flake registry entry.\n" &
    probe.error
  let marker = "\"path\":\""
  let at = probe.output.find(marker)
  doAssert at >= 0, "no path in `nix flake metadata nixpkgs --json` output"
  let rest = probe.output[at + marker.len .. ^1]
  let closing = rest.find('"')
  doAssert closing > 0, "unterminated path in `nix flake metadata` output"
  rest[0 ..< closing]

proc gitEnv(): StringTableRef =
  ## A deterministic committer so the fixture repo's tree revision does not
  ## depend on the host's git identity being configured at all.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["GIT_AUTHOR_NAME"] = "repro-nf4"
  result["GIT_AUTHOR_EMAIL"] = "repro-nf4@example.invalid"
  result["GIT_COMMITTER_NAME"] = "repro-nf4"
  result["GIT_COMMITTER_EMAIL"] = "repro-nf4@example.invalid"

proc git(workDir: string; args: openArray[string]) =
  let res = runTool(gitExe(), args, workDir, gitEnv())
  doAssert res.code == 0,
    "git " & args.join(" ") & " failed in " & workDir & ":\n" & res.error

type
  Fixture = object
    root: string          ## Temp root holding template/, sibA/, sibB/, bin/.
    templateProject: string
    sibA: string
    sibB: string
    nixWrapper: string
    spawnCounter: string
    repoRoot: string
    reproBin: string

proc recipeText(sibB, nixWrapper: string): string =
  ## The fixture recipe. §2b's degenerate end verbatim: no `uses:`, no build
  ## edges, nothing but the flake activation — the flake still defines
  ## everything in the shell.
  "import repro_project_dsl\n" &
  "import repro_dsl_stdlib/foreign_env\n" &
  "\n" &
  "package nf4flake:\n" &
  "  devEnv:\n" &
  "    useFlakeDevShell(flakeRef = \".?submodules=1\",\n" &
  "      overrideInputs = @[(\"sib\", \"" & sibB & "\")],\n" &
  "      nixExe = \"" & nixWrapper & "\")\n"

proc flakeText(nixpkgs, sibA: string): string =
  "{\n" &
  "  inputs.nixpkgs.url = \"path:" & nixpkgs & "\";\n" &
  "  inputs.sib.url = \"path:" & sibA & "\";\n" &
  "  outputs = { self, nixpkgs, sib }:\n" &
  "    let pkgs = import nixpkgs { system = \"" & NixSystem & "\"; };\n" &
  "    in {\n" &
  "      devShells." & NixSystem & ".default = pkgs.mkShellNoCC {\n" &
  "        packages = [ pkgs.coreutils ];\n" &
  "        NF4_PROBE = \"nf4-probe-value\";\n" &
  "        NF4_SIB_MARKER = sib.marker;\n" &
  "      };\n" &
  "    };\n" &
  "}\n"

proc writeSibling(dir, marker: string) =
  createDir(dir)
  writeFile(dir / "flake.nix",
    "{ outputs = { self }: { marker = builtins.readFile ./marker.txt; }; }\n")
  writeFile(dir / "marker.txt", marker & "\n")

proc prepareFixture(): Fixture =
  ## Build the template project ONCE. Every test copies it (`cp -a` semantics
  ## via `copyDir` plus a `.git` copy), which keeps nix's fetcher cache warm:
  ## the template costs ~20 s to lock and hash, a copy costs ~0.3 s.
  result.repoRoot = getCurrentDir()
  result.reproBin = reproBinary(result.repoRoot)
  result.root = createTempDir("repro-nf4-flake", "")
  result.sibA = result.root / "sibA"
  result.sibB = result.root / "sibB"
  writeSibling(result.sibA, "sibA")
  writeSibling(result.sibB, "sibB")

  # The counting wrapper. `/dev/shm` because the engine's evidence fold drops
  # every path under `/dev`, so the counter cannot become a cache input and
  # cannot invalidate the very edge whose invalidation it is measuring.
  result.spawnCounter = "/dev/shm/repro-nf4-nix-spawns-" &
    $getCurrentProcessId()
  removeFile(result.spawnCounter)
  createDir(result.root / "bin")
  result.nixWrapper = result.root / "bin" / "nix"
  writeFile(result.nixWrapper,
    "#!" & bashExe() & "\n" &
    "printf 'x' >> " & quoteShell(result.spawnCounter) & "\n" &
    "exec " & quoteShell(nixExe()) & " \"$@\"\n")
  setFilePermissions(result.nixWrapper,
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
     fpOthersRead, fpOthersExec})

  result.templateProject = result.root / "template"
  createDir(result.templateProject)
  writeFile(result.templateProject / "flake.nix",
    flakeText(resolveLocalNixpkgs(), result.sibA))
  writeFile(result.templateProject / "repro.nim",
    recipeText(result.sibB, result.nixWrapper))
  git(result.templateProject, ["init", "-q", "-b", "main", "."])
  # `flake.nix` must be tracked before `nix flake lock` will look at it: a
  # dirty git tree flake sees only what git knows about.
  git(result.templateProject, ["add", "flake.nix"])
  let locked = runTool(nixExe(), nixArgs(["flake", "lock"]),
    result.templateProject)
  doAssert locked.code == 0,
    "`nix flake lock` failed for the NF-4 fixture:\n" & locked.error
  git(result.templateProject, ["add", "flake.lock"])
  git(result.templateProject, ["commit", "-qm", "nf4 fixture"])

proc cloneProject(f: Fixture; name: string): string =
  ## `cp -a` rather than Nim's `copyDir`: the clone must carry `.git` and the
  ## file mtimes with it, or git treats every file as racily-changed and nix
  ## re-hashes the whole tree — which is the ~20 s the template exists to pay
  ## exactly once.
  result = f.root / name
  # `followSymlinks = false`: on a Nix host `cp` is a symlink into a
  # multi-call `coreutils` binary, and resolving it hands us a program that
  # dispatches on `argv[0]` and rejects `-a` outright.
  let cp = findExe("cp", followSymlinks = false)
  doAssert cp.len > 0, "NF-4's flake gate needs `cp` on PATH."
  let res = runTool(cp, ["-a", f.templateProject, result])
  doAssert res.code == 0, "cp -a failed:\n" & res.error

proc runRepro(f: Fixture; args: openArray[string]; userConfig: string):
    tuple[output, error: string, code: int] =
  ## Run the public CLI with the three HL-1 configuration layers pinned: the
  ## user layer at `userConfig`, and the system and VCS-private layers at
  ## paths that do not exist. Without the last two the gate would report the
  ## developer's own machine — a host with `auto_load_flake` set in
  ## `/etc/reprobuild/config.toml` would pass the "off" case for the wrong
  ## reason, and one without it would still be measuring a file this test does
  ## not control.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["REPROBUILD_USER_CONFIG"] = userConfig
  env["REPROBUILD_SYSTEM_CONFIG"] = f.root / "no-such-system-config.toml"
  env["REPROBUILD_VCS_PRIVATE_CONFIG"] = f.root / "no-such-private-config.toml"
  runTool(f.reproBin, args, f.repoRoot, env)

proc nixSpawnCount(f: Fixture): int =
  if not fileExists(f.spawnCounter):
    return 0
  readFile(f.spawnCounter).len

proc configFor(f: Fixture; projectRoot, outDir, monitorCliPath: string;
               monitorCliArgs: seq[string]; shim: string): DevEnvEdgeConfig =
  DevEnvEdgeConfig(
    modulePath: projectRoot / "repro.nim",
    projectRoot: projectRoot,
    outDir: outDir,
    workDir: f.repoRoot,
    publicCliPath: f.reproBin,
    monitorCliPath: monitorCliPath,
    monitorCliArgs: monitorCliArgs,
    monitorShimLibPath: shim,
    activity: "default",
    lockSliceId: "nf4",
    renderShell: true,
    statsEnabled: true)

proc shellOp(path, name: string): DevEnvShellOp =
  for op in readDevEnvArtifact(path).shellOps:
    if op.name == name:
      return op
  raise newException(ValueError, "missing shell op " & name & " in " & path)

proc hasShellOp(path, name: string): bool =
  for op in readDevEnvArtifact(path).shellOps:
    if op.name == name:
      return true
  false

proc observedPaths(edge: DevEnvEdgeResult): seq[string] =
  ## Everything the monitor saw the introspection edge touch, normalised to
  ## forward slashes. Reads, probes and enumerations together: the point of
  ## §2b is precisely that the manifest is not just "files that were read".
  for path in edge.introspectionAction.evidence.monitorReads:
    result.add(path.replace('\\', '/'))
  for path in edge.introspectionAction.evidence.monitorProbes:
    result.add(path.replace('\\', '/'))
  for path in edge.introspectionAction.evidence.monitorDirectoryEnumerations:
    result.add(path.replace('\\', '/'))

proc observedProbes(edge: DevEnvEdgeResult): seq[string] =
  for path in edge.introspectionAction.evidence.monitorProbes:
    result.add(path.replace('\\', '/'))

proc observedReads(edge: DevEnvEdgeResult): seq[string] =
  for path in edge.introspectionAction.evidence.monitorReads:
    result.add(path.replace('\\', '/'))

proc describeEdge(label: string; edge: DevEnvEdgeResult): string =
  ## Everything that decides whether an entry re-evaluated, in one line. The
  ## introspection edge's weak fingerprint includes the provider binary's
  ## fingerprint, so "why did this re-evaluate" is only answerable with the
  ## PROVIDER's decision beside the introspection's.
  label &
    ": providerLaunched=" & $edge.stats.providerBuildLaunched &
    " providerStatus=" & $edge.providerCompileAction.status &
    " providerMiss=" & edge.providerCompileAction.cacheMissReason &
    " providerArtifactId=" & edge.providerArtifactId &
    " introspectionLaunched=" & $edge.stats.providerIntrospectionLaunched &
    " introspectionMiss=" & edge.introspectionAction.cacheMissReason &
    "\n  providerDiagnostics=" &
      edge.providerCompileAction.evidence.diagnostics.join(" | ") &
    "\n  introspectionDiagnostics=" &
      edge.introspectionAction.evidence.diagnostics.join(" | ")

proc dumpObserved(edge: DevEnvEdgeResult) =
  echo "monitorReads=", edge.introspectionAction.evidence.monitorReads.join("|")
  echo "monitorProbes=",
    edge.introspectionAction.evidence.monitorProbes.join("|")
  echo "monitorEnumerations=",
    edge.introspectionAction.evidence.monitorDirectoryEnumerations.join("|")

proc nixDevelopEnv(f: Fixture; projectRoot: string):
    tuple[path: string, probe, marker: string] =
  ## The reference shell: `nix develop` on the same flake with the same
  ## override, run with `PATH` set to nothing but a sentinel so the resulting
  ## `PATH` is exactly what the dev shell contributed plus that sentinel.
  var env = newStringTable(modeCaseSensitive)
  env["HOME"] = getEnv("HOME")
  env["PATH"] = PathSentinel
  for name in ["NIX_SSL_CERT_FILE", "SSL_CERT_FILE", "XDG_RUNTIME_DIR",
               "NIX_REMOTE", "TMPDIR", "USER"]:
    if existsEnv(name):
      env[name] = getEnv(name)
  let res = runTool(nixExe(), nixArgs([
      "develop", ".?submodules=1",
      "--override-input", "sib", "path:" & f.sibB,
      "--command", bashExe(), "--noprofile", "--norc", "-c",
      "printf '%s\\n%s\\n%s\\n' \"$PATH\" \"$NF4_PROBE\" \"$NF4_SIB_MARKER\""]),
    projectRoot, env)
  doAssert res.code == 0, "`nix develop` reference run failed:\n" & res.error
  let lines = res.output.strip().splitLines()
  doAssert lines.len >= 3, "unexpected `nix develop` output: " & res.output
  (lines[0], lines[1], lines[2])

suite "e2e_nf4_flake_dev_shell":
  when isIoMonitorSupported:
    let fixture = prepareFixture()
    let monitor = prepareMonitorTools(fixture.repoRoot,
      fixture.root / "monitor", "nf4-flake")

    test "activating_a_flake_from_repro_nim_yields_the_same_shell":
      let project = fixture.cloneProject("same-shell")
      let outDir = fixture.root / "same-shell-out"
      createDir(outDir)
      let edge = computeDevEnvEdge(fixture.configFor(project, outDir,
        monitor.monitorCliPath, monitor.monitorCliArgs, monitor.shim))
      check edge.stats.providerIntrospectionLaunched

      let reference = fixture.nixDevelopEnv(project)

      # (1) Same PATH entries, in the same order. The reference `PATH` is the
      # dev shell's contribution followed by the sentinel and nothing else, so
      # this is an exact list comparison rather than a containment check.
      let referenceEntries = reference.path.split(PathSep)
      check referenceEntries.len >= 2
      check referenceEntries[^1] == PathSentinel
      let contributed = shellOp(edge.artifactPath, "PATH")
      check contributed.kind == deskPrependPath
      check contributed.value.split(PathSep) ==
        referenceEntries[0 ..< referenceEntries.len - 1]

      # (2) Same store paths. Every entry the flake contributed is a store
      # path, and they are the same store paths `nix develop` selected — which
      # is the claim that the two environments agree about what is in play.
      for entry in contributed.value.split(PathSep):
        check entry.startsWith("/nix/store/")
        check reference.path.contains(entry)

      # (3) Non-path variables come across too, including one whose value only
      # exists because the `--override-input` was applied: `sibB`, not the
      # `sibA` the committed `flake.lock` names.
      check shellOp(edge.artifactPath, "NF4_PROBE").value == reference.probe
      check shellOp(edge.artifactPath, "NF4_PROBE").value == "nf4-probe-value"
      check shellOp(edge.artifactPath, "NF4_SIB_MARKER").value.strip() ==
        reference.marker.strip()
      check shellOp(edge.artifactPath, "NF4_SIB_MARKER").value.strip() == "sibB"

      # (4) The capture is a DIFF, not the capturing process's environment:
      # variables the flake never mentions must not have been baked in.
      check not hasShellOp(edge.artifactPath, "PWD")
      check not hasShellOp(edge.artifactPath, "SHLVL")

    test "the_observed_manifest_catches_what_watch_file_misses":
      let project = fixture.cloneProject("observed")
      let outDir = fixture.root / "observed-out"
      createDir(outDir)
      let cfg = fixture.configFor(project, outDir, monitor.monitorCliPath,
        monitor.monitorCliArgs, monitor.shim)
      let first = computeDevEnvEdge(cfg)
      check first.stats.providerIntrospectionLaunched

      let observed = first.observedPaths()
      if observed.len == 0:
        first.dumpObserved()
      check observed.len > 0

      # The DECLARED watch set, for this exact flake expression, computed the
      # way `nix-direnv`'s `use_flake` computes it: it registers `flake.nix`
      # and `flake.lock` only when `[[ -d $flake_expr ]]`, and the expression
      # here is `.?submodules=1`, which is not a directory. So the declared set
      # is EMPTY, and every assertion below names a file that a `watch_file`
      # list built that way does not contain.
      let declaredWatchSet: seq[string] = @[]
      check declaredWatchSet.len == 0

      proc sawSuffix(paths: openArray[string]; suffix: string): bool =
        for path in paths:
          if path.endsWith(suffix):
            return true
        false

      # Failure mode 1 — a watch that never happened. `flake.nix` and
      # `flake.lock` are load-bearing inputs of this evaluation and were never
      # in the declared set; they ARE in the observed one.
      check observed.sawSuffix("/flake.nix")
      check observed.sawSuffix("/flake.lock")
      check not declaredWatchSet.sawSuffix("/flake.nix")
      check not declaredWatchSet.sawSuffix("/flake.lock")

      # Failure mode 2 — a watch that cannot exist. `--override-input sib
      # path:<sibB>` makes that working tree a build input. Nothing in direnv
      # watches it; the monitor saw nix read the file inside it whose contents
      # became `NF4_SIB_MARKER`.
      check observed.anyIt(it.startsWith(fixture.sibB.replace('\\', '/')))
      check observed.sawSuffix("sibB/marker.txt")

      # Failure mode 3 — a watch nobody thought of. `.gitignore` does not
      # exist, so no `watch_file` can name it, yet the evaluation asked for it:
      # a git-tree flake's source is decided by what git ignores, so the file
      # appearing changes what the flake IS. It is an ABSENT-path probe, which
      # is why it appears among the probes and not among the reads.
      let gitignore = (project / ".gitignore").replace('\\', '/')
      check not fileExists(gitignore)
      if not first.observedProbes().anyIt(it == gitignore):
        first.dumpObserved()
      check first.observedProbes().anyIt(it == gitignore)
      check not first.observedReads().anyIt(it == gitignore)

      # And the absent probe is not decoration. Three more entries bracket the
      # single change: unchanged → HIT, `.gitignore` appears → MISS, unchanged
      # again → HIT. The two hits are what make the miss attributable: an
      # implementation that simply re-evaluated every time would fail them, and
      # nothing but the appearing file differs across the bracket.
      let unchanged = computeDevEnvEdge(cfg)
      if unchanged.stats.providerIntrospectionLaunched:
        echo describeEdge("first", first)
        echo describeEdge("unchanged", unchanged)
      check not unchanged.stats.providerIntrospectionLaunched
      check unchanged.stats.providerIntrospectionCacheHit

      writeFile(project / ".gitignore", "/.repro/\n")
      let afterAppearing = computeDevEnvEdge(cfg)
      check afterAppearing.stats.providerIntrospectionLaunched
      # The engine's own miss reason names a path inside the project, so the
      # re-evaluation is attributed to what the monitor observed there rather
      # than to a tool's private state elsewhere on the machine.
      check afterAppearing.introspectionAction.cacheMissReason.len > 0
      check afterAppearing.introspectionAction.cacheMissReason.contains(project)

      let settled = computeDevEnvEdge(cfg)
      if settled.stats.providerIntrospectionLaunched:
        echo describeEdge("afterAppearing", afterAppearing)
        echo describeEdge("settled", settled)
      check not settled.stats.providerIntrospectionLaunched
      check settled.stats.providerIntrospectionCacheHit

    test "a_stale_manifest_is_detected_without_re_evaluating":
      let project = fixture.cloneProject("stale")
      let outDir = fixture.root / "stale-out"
      createDir(outDir)
      let cfg = fixture.configFor(project, outDir, monitor.monitorCliPath,
        monitor.monitorCliArgs, monitor.shim)

      let before = fixture.nixSpawnCount()
      let cold = computeDevEnvEdge(cfg)
      check cold.stats.providerIntrospectionLaunched
      let afterCold = fixture.nixSpawnCount()
      # The cold entry really did evaluate the flake: without this the "no
      # spawn on re-entry" assertion below would also hold for an
      # implementation that never spawns nix at all.
      check afterCold > before

      let warm = computeDevEnvEdge(cfg)
      if warm.stats.providerIntrospectionLaunched:
        echo describeEdge("cold", cold)
        echo describeEdge("warm", warm)
      check not warm.stats.providerIntrospectionLaunched
      check warm.stats.providerIntrospectionCacheHit
      check warm.artifactPath == cold.artifactPath
      check readFile(warm.artifactPath) == readFile(cold.artifactPath)
      # The claim, asserted on the evaluation itself and not on elapsed time:
      # the re-entry spawned no `nix` at all. The decision that the cached
      # manifest is still valid was a fingerprint comparison.
      check fixture.nixSpawnCount() == afterCold

      # Staleness is likewise decided without re-evaluating: the DECISION is a
      # fingerprint comparison against the observed manifest, and the engine's
      # own miss reason names the input whose fingerprint moved. Appending a
      # blank line to `flake.nix` is a real edit to a real observed input that
      # leaves the flake evaluable, so the re-evaluation that follows the
      # decision still succeeds.
      writeFile(project / "flake.nix",
        readFile(project / "flake.nix") & "\n")
      let stale = computeDevEnvEdge(cfg)
      check stale.stats.providerIntrospectionLaunched
      check stale.introspectionAction.cacheMissReason.len > 0
      check stale.introspectionAction.cacheMissReason.contains("flake.nix")

    test "auto_load_goes_through_the_synthesised_repro_nim":
      # No `repro.nim` at all, and `[foreign_env] auto_load_flake = true` in a
      # configuration layer. The shell that comes out must be the flake's, and
      # the route it came out by must be the ORDINARY one: a `repro.nim` that
      # Reprobuild wrote, carrying the same one-liner a person would write.
      let project = fixture.cloneProject("autoload-on")
      removeFile(project / "repro.nim")
      let configPath = fixture.root / "autoload-on-config.toml"
      writeFile(configPath,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[foreign_env]\n" &
        "auto_load_flake = true\n")

      let activation = fixture.runRepro(["__repro-direnv-activate", project],
        configPath)
      check activation.code == 0

      # The synthesised recipe exists, where the stdlib says it goes, and it
      # is the one-liner. Not a parallel mechanism — a recipe.
      let synthesized = project / ".repro" / "foreign-env" / "repro.nim"
      check fileExists(synthesized)
      let synthesizedText = readFile(synthesized)
      check synthesizedText.contains("devEnv:")
      check synthesizedText.contains("useFlakeDevShell()")
      check synthesizedText.contains("import repro_dsl_stdlib/foreign_env")

      # And the environment it produced is the flake's. `NF4_SIB_MARKER` is
      # `sibA` here and `sibB` in the hand-written-recipe tests above, because
      # the synthesised recipe passes no `--override-input`: the value proves
      # WHICH recipe ran, not merely that something did.
      check activation.output.contains("NF4_PROBE")
      check activation.output.contains("nf4-probe-value")
      check activation.output.contains("sibA")
      check not activation.output.contains("sibB")

    test "auto_load_is_off_until_a_configuration_layer_enables_it":
      # The same directory, the same flake, no flag: Reprobuild refuses rather
      # than helpfully evaluating a flake nobody asked it to evaluate, and
      # writes no synthesised recipe on the way out.
      let project = fixture.cloneProject("autoload-off")
      removeFile(project / "repro.nim")
      let configPath = fixture.root / "autoload-off-config.toml"
      writeFile(configPath,
        "schema = \"reprobuild.config.v1\"\n\n" &
        "[foreign_env]\n" &
        "auto_load_flake = false\n" &
        "auto_load_envrc = false\n")

      let refused = fixture.runRepro(["__repro-direnv-activate", project],
        configPath)
      check refused.code != 0
      check (refused.output & refused.error).contains(
        "dev-env target module not found")
      check not fileExists(project / ".repro" / "foreign-env" / "repro.nim")
      check not refused.output.contains("nf4-probe-value")
