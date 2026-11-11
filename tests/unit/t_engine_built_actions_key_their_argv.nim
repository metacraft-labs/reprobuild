## Engine-built actions key the command line they spawn.
##
## `action()` keys `argv[0]` only when it lies under a content-addressed
## root; everything else in argv reaches the local key only if the
## constructor puts it there. Each constructor below computed its
## fingerprint over a hand-picked part of its command (the inner `nim c`,
## the artifact path, the compilers) and left the rest out: the provider
## compile's `--work-dir`, `--out` and `--interface`, the CMake
## regeneration's `--metadata`, the dev-env edges' `--out`,
## `--protocol-root` and `--navigator-stats`, the profile edges'
## `--repo-root`. Two edges differing only there shared one record.
##
## Each case changes ONE argv element through the constructor's own inputs,
## holding everything else the key covers (cwd, declared environment, the
## seed fingerprint) fixed, and asserts the key moved. Falsifier: drop the
## `keyedOnArgv` call at a site and its case goes red.

import std/[importutils, os, tables, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_interface_artifacts
import repro_cli_support {.all.}
import repro_dev_env_engine {.all.}
import repro_profile_compile/edge
import repro_profile_compile/apply_build_actions
from repro_profile import ProfileBuildAction

template withRoot(body: untyped) =
  ## A fresh directory per case, named `root` in `body`, removed after it.
  let root {.inject.} = createTempDir("repro-engine-argv-key", "")
  try:
    body
  finally:
    removeDir(root)

proc seedPlan(outputBinaryPath: string): ProviderCompilePlan =
  result.outputBinaryPath = outputBinaryPath
  result.compileEdge.actionFingerprint = weakFingerprintFromText("inner nim c")
  result.providerCompileActionKey = weakFingerprintFromText("recipe key")

proc cliCompile(root: string; plan: ProviderCompilePlan;
                interfacePath = "iface.rbif"; artifact = "provider-compile.rbsz";
                workDir = "libs"): BuildAction =
  repro_cli_support.providerCompileBuildAction(plan, root / "repro.nim",
    root / interfacePath, root / artifact, root / "bin" / "repro",
    root / workDir, root / "provider-work")

proc devEnvCompile(root: string; plan: ProviderCompilePlan;
                   interfacePath = "iface.rbif";
                   artifact = "provider-compile.rbsz";
                   workDir = "libs"): BuildAction =
  repro_dev_env_engine.providerCompileBuildAction(plan, root / "repro.nim",
    root / interfacePath, root / artifact, root / "bin" / "repro",
    root / workDir, root / "provider-work")

proc relocated(root, recipe: string; helper = "repro";
               workDir = "libs"): BuildAction =
  ## The recipe-relative edge for a recipe at `root / recipe`.
  privateAccess(RecipeRelativeProviderCompile)
  let recipeDir = root / recipe
  createDir(recipeDir)
  let identityDir = root / "action-cache" / "provider" / "id"
  var edge = RecipeRelativeProviderCompile(active: true,
    recipeDir: recipeDir,
    anchors: @[root / "action-cache", root / "libs", root / "bin"],
    edgePlan: seedPlan(identityDir / "staging" / "provider" /
      "project-provider"),
    edgeArtifactPath: identityDir / "staging" / "provider-compile.rbsz",
    identityDir: identityDir,
    stagingDir: identityDir / "staging")
  recipeRelativeProviderCompileAction(edge, recipeDir / "repro.nim",
    root / "bin" / helper, root / workDir)

proc regen(root, metadataFile: string): BuildAction =
  privateAccess(CmakeRegenerationMetadata)
  let meta = CmakeRegenerationMetadata(enabled: true,
    metadataFile: root / "build" / metadataFile,
    sourceDir: root / "src", binaryDir: root / "build",
    cmakeCommand: "/usr/bin/cmake",
    checkFile: root / "build" / "CMakeFiles" / "cmake.check_cache",
    providerFile: root / "build" / "provider.repro",
    providerStateFile: root / "build" / "provider.state")
  cmakeRegenerationBuildAction(meta, root / "bin" / "repro")

proc devEnvConfig(root: string; outDir = "dev-env"): DevEnvEdgeConfig =
  DevEnvEdgeConfig(projectRoot: root / "project", outDir: root / outDir,
    workDir: root / "libs", publicCliPath: root / "bin" / "repro")

proc introspect(root: string; config: DevEnvEdgeConfig;
                artifact = "artifact.rbde"): BuildAction =
  let provider = ProviderCompileArtifact(
    outputBinaryPath: root / "dev-env" / "provider" / "project-provider")
  devEnvIntrospectionAction(config, provider,
    root / "dev-env" / "provider-compile.rbsz", "artifact-id",
    root / "dev-env" / artifact)

proc render(root: string; shell = "shell.sh";
            stats = "nav.stats"): BuildAction =
  shellRenderAction(devEnvConfig(root), root / "dev-env" / "artifact.rbde",
    root / "dev-env" / shell, root / "dev-env" / stats)

proc profileCompile(repoRoot: string; verbose = false): BuildAction =
  profileCompileBuildAction("/profile/home.nim", "/cache/abc.profile-build",
    "/cache/nimcache/abc", "/bin/repro", "/profile", repoRoot,
    weakFingerprintFromText("profile seed"), verbose = verbose)

proc probe(repoRoot: string): BuildAction =
  profilePlatformProbeBuildAction("/profile/home.nim", "/cache/abc.probe",
    "/cache/abc.probe-scratch", "/bin/repro", "/profile", repoRoot,
    weakFingerprintFromText("profile seed"))

suite "provider compile keys its helper's command line":

  test "the CLI edge: --work-dir, --out, --interface and --artifact":
    withRoot:
      let plan = seedPlan(root / "out" / "project-provider")
      let base = cliCompile(root, plan).weakFingerprint
      check base == cliCompile(root, plan).weakFingerprint
      check base != cliCompile(root, plan, workDir = "other-libs").weakFingerprint
      check base != cliCompile(root,
        seedPlan(root / "out2" / "project-provider")).weakFingerprint
      check base !=
        cliCompile(root, plan, interfacePath = "other.rbif").weakFingerprint
      check base !=
        cliCompile(root, plan, artifact = "other.rbsz").weakFingerprint

  test "the dev-env edge: the same command, so the same key":
    withRoot:
      let plan = seedPlan(root / "out" / "project-provider")
      let base = devEnvCompile(root, plan).weakFingerprint
      check base == cliCompile(root, plan).weakFingerprint
      check base !=
        devEnvCompile(root, plan, workDir = "other-libs").weakFingerprint
      check base != devEnvCompile(root,
        seedPlan(root / "out2" / "project-provider")).weakFingerprint
      check base !=
        devEnvCompile(root, plan, interfacePath = "other.rbif").weakFingerprint

suite "recipe-relative provider compile keys its command line":

  test "the helper's file name and the work dir are keyed":
    withRoot:
      let edge = relocated(root, "tree-a" / "pkg")
      check edge.relocatable
      check edge.weakFingerprint !=
        relocated(root, "tree-a" / "pkg", helper = "repro-other").weakFingerprint
      check edge.weakFingerprint !=
        relocated(root, "tree-a" / "pkg", workDir = "libs" / "nested").weakFingerprint

  test "a copy of the recipe elsewhere keys the same":
    # Keyed in the names its record uses, so relocation still shares.
    withRoot:
      check relocated(root, "tree-a" / "pkg").weakFingerprint ==
        relocated(root, "tree-b" / "pkg").weakFingerprint

suite "CMake regeneration keys its command line":

  test "--metadata is keyed":
    withRoot:
      let base = regen(root, "provider.meta").weakFingerprint
      check base == regen(root, "provider.meta").weakFingerprint
      check base != regen(root, "other.meta").weakFingerprint

suite "dev-env edges key their command lines":

  test "introspection: --out and --protocol-root are keyed":
    withRoot:
      let base = introspect(root, devEnvConfig(root)).weakFingerprint
      check base == introspect(root, devEnvConfig(root)).weakFingerprint
      check base != introspect(root, devEnvConfig(root),
        artifact = "other.rbde").weakFingerprint
      # `--protocol-root` is `<outDir>/dev-env-protocol`.
      check base != introspect(root,
        devEnvConfig(root, outDir = "dev-env-2")).weakFingerprint

  test "shell render: --out and --navigator-stats are keyed":
    withRoot:
      let base = render(root).weakFingerprint
      check base == render(root).weakFingerprint
      check base != render(root, shell = "other.sh").weakFingerprint
      check base != render(root, stats = "other.stats").weakFingerprint

suite "profile edges key their command lines":

  test "compile: --repo-root and --verbose are keyed":
    check profileCompile("/repo").weakFingerprint ==
      profileCompile("/repo").weakFingerprint
    check profileCompile("/repo").weakFingerprint !=
      profileCompile("/other-repo").weakFingerprint
    check profileCompile("/repo").weakFingerprint !=
      profileCompile("/repo", verbose = true).weakFingerprint

  test "platform probe: --repo-root is keyed":
    check probe("/repo").weakFingerprint == probe("/repo").weakFingerprint
    check probe("/repo").weakFingerprint != probe("/other-repo").weakFingerprint

suite "profile build actions key their argv framed":

  test "one changed argv element is a different key":
    proc key(argv: seq[string]): string =
      buildActionFingerprintHex(ProfileBuildAction(id: "unpack",
        argv: argv, cwd: "/work", outputs: @["/work/out"]))
    check key(@["/bin/tar", "-xf", "a.tar"]) == key(@["/bin/tar", "-xf", "a.tar"])
    check key(@["/bin/tar", "-xf", "a.tar"]) != key(@["/bin/tar", "-xf", "b.tar"])
    # Framed, not newline-joined: an element carrying a newline must not
    # read as two elements, nor as a declared output.
    check key(@["/bin/x", "a\nargv:b"]) != key(@["/bin/x", "a", "b"])
    check buildActionFingerprintHex(ProfileBuildAction(id: "unpack",
        argv: @["/bin/x", "a\nout:/work/out"], cwd: "/work")) !=
      buildActionFingerprintHex(ProfileBuildAction(id: "unpack",
        argv: @["/bin/x", "a"], cwd: "/work", outputs: @["/work/out"]))
