## M9.N Batch C.1 verification: from-source custom-shell (Tier 2b)
## convention.
##
## Pins the wiring between:
##
##   * the M9.N Batch C.1 ``registeredShellActions`` registry → one
##     ``BuildActionDef`` per shell action, in declaration order;
##   * the M9.H ``registeredFetchSpec`` registry → optional fetch
##     ``BuildActionDef`` prepended via the shared ``fetch_action``
##     helper;
##   * the per-recipe ``executable`` / ``library`` / ``files``
##     declarations → per-artifact stage-copy ``BuildActionDef`` one
##     per declared member;
##   * the ``$fetch`` / ``$extracted`` / ``$out`` substitution surface
##     → expanded inline at ``emitFragment`` time so the recorded
##     shell strings travel verbatim through the convention without
##     leaking the placeholder tokens into the engine's action argv.
##
## The test runs against the production ``mesonSource`` recipe under
## ``recipes/packages/source/meson/`` — meson 1.6.1 (Python-only tool;
## the canonical M9.N Batch C.1 vertical-slice recipe).

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_custom as
  from_source_custom_convention

# Side-effect import: triggers the meson recipe's package macro which
# registers the fetch spec + executable artifact under the
# ``mesonSource`` key at module init time. In ``reproProviderMode`` the
# build body is NOT spliced at module init (the macro layer gates it
# behind ``when not defined(reproProviderMode)`` to keep the legacy
# ``buildMesonSourcePackage*()`` proc the sole executor); we call the
# proc ourselves in a setup block so the shell-action registry is
# populated for the convention's recognise + emit assertions below.
import "../../../recipes/packages/source/meson/repro"

# Provider-mode bridge: under reproProviderMode the M4 emitter gates
# the build-body splice behind ``when not defined(reproProviderMode)``
# so the legacy ``buildMesonSourcePackage*()`` proc is the sole
# executor. The convention test runs with ``reproProviderMode`` defined
# (so the convention's emitFragment compiles); we therefore have to
# call the build proc ourselves to populate the M9.N Batch C.1
# shell-action registry. Outside provider mode the body already ran at
# module-init time; calling the proc again would double-register, so
# the call is gated on the same define the M4 emitter uses.
when defined(reproProviderMode):
  buildMesonSourcePackage()

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_from_source_custom_convention.nim``
  ## lands at the reprobuild repo root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MesonRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "meson"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    result.add(decodeBuildActionPayload(toBytes(node.payload)))

proc findById(actions: seq[BuildActionDef]; id: string): BuildActionDef =
  for a in actions:
    if a.id == id:
      return a
  raise newException(ValueError, "action not found: " & id)

suite "from-source-custom convention M9.N Batch C.1 — meson recipe":

  test "convention name is 'from-source-custom'":
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    check conv.name == "from-source-custom"

  test "recognize: positive — meson source recipe":
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    # Sanity: the production recipe must exist at the expected path.
    check fileExists(MesonRecipe / "repro.nim")
    # Sanity: the recipe import must have populated the M9.H fetch
    # registry AND the M9.N Batch C.1 shell-action registry.
    let spec = registeredFetchSpec("mesonSource")
    check spec.url.len > 0
    let shellRows = registeredShellActions("mesonSource")
    check shellRows.len == 4
    # All four standard flag channels must be empty — that's how the
    # catch-all distinguishes itself from the standard from-source-*
    # siblings.
    check registeredBuildFlags("mesonSource", "", "meson").len == 0
    check registeredBuildFlags("mesonSource", "", "cmake").len == 0
    check registeredBuildFlags("mesonSource", "", "configure").len == 0
    check registeredBuildFlags("mesonSource", "", "make").len == 0
    let request = dummyRequest(MesonRecipe)
    check conv.recognize(MesonRecipe, request)

  test "recognize: negative — no shell() actions registered":
    # A recipe that declares fetch + meson uses but no ``shell()`` calls
    # must NOT be claimed by the catch-all. The convention test sets up
    # a scratch projectRoot whose repro.nim shape is a fetch-only recipe.
    let scratch = getTempDir() /
      "test_from_source_custom_convention_no_shell"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceCustomNoShellPkg:\n" &
      "  fetch:\n" &
      "    url: \"https://example.com/foo.tar.gz\"\n" &
      "    sha256: \"abc\" & repeat(\"0\", 61)\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "recognize: negative — in-tree build manifest at projectRoot":
    # If ``Makefile`` (or another in-tree manifest) exists at the root,
    # the corresponding in-tree convention claims the project and the
    # custom catch-all yields. The convention's recognise rejects
    # without even consulting the shell-action registry.
    let scratch = getTempDir() /
      "test_from_source_custom_convention_intree_makefile"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    writeFile(scratch / "Makefile", "all:\n\techo nothing\n")
    writeFile(scratch / "repro.nim",
      "import repro_project_dsl\n" &
      "package fromSourceCustomIntreeMakefilePkg:\n" &
      "  executable foo:\n" &
      "    discard\n")
    defer:
      removeDir(scratch)
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(scratch)
    check not conv.recognize(scratch, request)

  test "substitutePlaceholders expands $fetch / $extracted / $out":
    # The substitution helper is part of the convention's public
    # surface — tests pin it directly to guard the placeholder
    # vocabulary the recipe authors rely on.
    let resolved = from_source_custom_convention.substitutePlaceholders(
      "tar -xf $fetch -C $extracted && cp $extracted/lib $out/lib",
      "/proj/.repro/fetch/abc.tar",
      "/proj/src",
      "/proj/.repro/build/from-source-custom/meson")
    check resolved.contains("/proj/.repro/fetch/abc.tar")
    check resolved.contains("/proj/src")
    check resolved.contains("/proj/.repro/build/from-source-custom/meson")
    check not resolved.contains("$fetch")
    check not resolved.contains("$extracted")
    check not resolved.contains("$out")

  test "emitFragment: produces fetch + N shell + per-member stage-copy":
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(MesonRecipe)
    require conv.recognize(MesonRecipe, request)
    let fragment = conv.emitFragment(MesonRecipe, request)
    let actions = extractActions(fragment)

    # Expected shape: 1 fetch + 4 shell + 1 stage-copy = 6 actions.
    check actions.len >= 6

    var sawFetch = false
    var sawStageMeson = false
    var shellCount = 0
    for a in actions:
      if a.id == "ccpp-fetch-mesonSource":
        sawFetch = true
      elif a.id == "from-source-custom-stage-meson":
        sawStageMeson = true
      elif a.id.startsWith("from-source-custom-shell-"):
        inc shellCount
    check sawFetch
    check sawStageMeson
    check shellCount == 4

  test "emitFragment: shell action argv carries substituted command":
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(MesonRecipe)
    let fragment = conv.emitFragment(MesonRecipe, request)
    let actions = extractActions(fragment)
    # The FIRST shell action is the recipe's ``mkdir -p $out/share/meson
    # $out/bin`` line. After substitution the ``$out`` placeholder is
    # gone and the absolute output path is in the argv.
    let firstShell = findById(actions,
      "from-source-custom-shell-1-mesonSource")
    let argvJoined = inlineArgvOf(firstShell).join(" ")
    # The placeholder tokens MUST have been substituted by the
    # convention — the engine must not see ``$out`` / ``$extracted``.
    check not argvJoined.contains("$out")
    check not argvJoined.contains("$extracted")
    # The substituted path is rooted at the meson recipe's projectRoot.
    check argvJoined.contains("from-source-custom")
    check argvJoined.contains("share/meson")

  test "emitFragment: shell action chain wires sequential deps":
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(MesonRecipe)
    let fragment = conv.emitFragment(MesonRecipe, request)
    let actions = extractActions(fragment)
    # First shell depends on the fetch action (no prior shell).
    let firstShell = findById(actions,
      "from-source-custom-shell-1-mesonSource")
    check firstShell.deps == @["ccpp-fetch-mesonSource"]
    # Second shell depends on the first.
    let secondShell = findById(actions,
      "from-source-custom-shell-2-mesonSource")
    check secondShell.deps == @["from-source-custom-shell-1-mesonSource"]
    # The fourth shell depends on the third (last one in the chain).
    let fourthShell = findById(actions,
      "from-source-custom-shell-4-mesonSource")
    check fourthShell.deps == @["from-source-custom-shell-3-mesonSource"]

  test "emitFragment: stage-copy depends on the LAST shell action":
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(MesonRecipe)
    let fragment = conv.emitFragment(MesonRecipe, request)
    let actions = extractActions(fragment)
    let stage = findById(actions, "from-source-custom-stage-meson")
    check stage.deps == @["from-source-custom-shell-4-mesonSource"]

  test "emitFragment: last shell + stage carry publishToBinaryCache":
    # M9.L.4-refactor Step B: only the LAST shell action + the stage-
    # copy edges carry the binary-cache identity (so the engine's
    # publisher hook fires once per logical cache entry). Intermediate
    # shell actions do NOT publish.
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(MesonRecipe)
    let fragment = conv.emitFragment(MesonRecipe, request)
    let actions = extractActions(fragment)
    let firstShell = findById(actions,
      "from-source-custom-shell-1-mesonSource")
    let fourthShell = findById(actions,
      "from-source-custom-shell-4-mesonSource")
    let stage = findById(actions, "from-source-custom-stage-meson")
    check not firstShell.publishToBinaryCache
    check fourthShell.publishToBinaryCache
    check fourthShell.cacheEntryIdentity.isSome
    check stage.publishToBinaryCache
    check stage.cacheEntryIdentity.isSome

  test "emitFragment: toolIdentityRefs include 'sh' on every action":
    # The shell actions all shell out via ``sh -c``; the stage-copy
    # action also uses ``sh`` for the probe-chain. The engine resolves
    # the bare tool name via the catalog at fork time.
    let conv = from_source_custom_convention.fromSourceCustomConvention()
    let request = dummyRequest(MesonRecipe)
    let fragment = conv.emitFragment(MesonRecipe, request)
    let actions = extractActions(fragment)
    for a in actions:
      if a.id.startsWith("from-source-custom-"):
        check "sh" in a.toolIdentityRefs
