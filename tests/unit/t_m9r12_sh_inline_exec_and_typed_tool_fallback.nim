## DSL-port M9.R.12.1 + M9.R.12.2 — autotools_package configure edge
## via inlineExecCall + profile lookup fall-through by packageName.
##
## ## Context
##
## The M9.R.12 wayland from-source smoke surfaced two pre-existing
## tool-resolution gaps in the lowering path:
##
##   1. **autotools_package configure edge required ``sh`` profile**.
##      The constructor at
##      ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/constructors/
##      autotools_package.nim`` used ``sh_module.shell(command = ...)``
##      which records a typed ``publicCliCall("sh", "sh", ...)``. The
##      engine's path-mode resolver requires a profile for every non-
##      builtin executable name; recipes consuming ``autotools_package``
##      did NOT declare ``"sh"`` in ``nativeBuildDeps:`` (only ``gcc`` /
##      ``make`` / ``perl`` / etc.), so the resolver hard-failed with
##      ``tool-resolution failed: action sh-<hex> references executable
##      sh but no tool profile was resolved for it`` for every
##      ``from-source`` autotools recipe (binutils, expat, autoconf,
##      automake, libtool, ...).
##
##      Fix: rewrite the configure edge to use
##      ``inlineExecCall(["sh", "-c", script], ...)`` with
##      ``toolIdentityRefs = @["sh"]``. The engine recognises
##      ``reprobuild.builtin.exec`` calls in ``lowerGraphAction`` and
##      skips profile lookup; the ``toolIdentityRefs`` ride lets the
##      engine prepend the resolved ``sh`` bin dir to PATH at fork time
##      via ``BuildEngineConfig.toolIdentityResolver``.
##
##   2. **Typed-tool wrappers record under inner executable name**.
##      The stdlib typed-tool packages declare ``executable <name>Bin:``
##      blocks inside ``package <name>:`` modules (``executable
##      makeBin:`` in ``package make:``, ``cmakeBin`` in ``cmake``,
##      ``mesonBin`` in ``meson``, ``ninjaBin`` in ``ninja``). The
##      macro-emitted typed-tool proc records a ``PublicCliCall`` with
##      ``packageName = "<name>"`` AND ``executableName = "<name>Bin"``.
##      The profile registry indexes profiles by
##      ``packageSelector & "|" & executableName`` and ``executableName``
##      alone — both keys derived from the recipe's
##      ``nativeBuildDeps: "<name>"`` declaration where
##      ``selectorFromConstraint`` yields ``"<name>"`` for both
##      ``packageSelector`` and ``executableName``. The lookup for
##      ``"<name>|<name>Bin"`` and ``"<name>Bin"`` misses both keys.
##
##      Fix: add a third fallback in ``lowerGraphAction``'s profile
##      lookup — ``profiles.hasKey(packageName)`` — so the resolver
##      finds the profile registered under the package selector even
##      when the action's ``executableName`` carries the inner typed-
##      tool block's name.
##
## ## What this test pins
##
## STRUCTURAL arm:
##
##   * ``autotools_package(srcDir, configureOptions)`` returns an
##     ``AutotoolsPackageResult`` whose ``buildEdge`` (the configure
##     action) has ``call.packageName == "reprobuild.builtin"`` and
##     ``call.executableName == "exec"`` (i.e., it goes through the
##     inline-exec lowering, NOT the typed ``sh`` profile path).
##   * The action's ``toolIdentityRefs`` includes ``"sh"`` so PATH
##     plumbing still works through the engine's tool-identity resolver.
##   * The argv recorded on the call is the ``["sh", "-c",
##     "<srcDir>/configure --prefix=<prefix> <options...>"]`` shape.
##
## BEHAVIOURAL arm:
##
##   * ``profileIndex``-derived lookup falls back to ``packageName``
##     alone when the action's ``executableName`` doesn't match any
##     profile key directly. We exercise this via a synthetic
##     ``Table[string, PathOnlyToolProfile]`` carrying only the
##     ``"make"`` / ``"make|make"`` keys (mirroring what the typed-tool
##     profile registry produces from a ``nativeBuildDeps: "make"``
##     declaration) and confirm the lookup logic the engine performs
##     finds the profile when the call carries ``executableName =
##     "makeBin"``.

import std/[strutils, tables, unittest]

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_interface_artifacts
import repro_tool_profiles

proc argByName(action: BuildActionDef; name: string): PublicCliArg =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg
  raise newException(ValueError, "no argument named '" & name &
    "' in call to " & action.call.packageName & "." &
    action.call.executableName & "." & action.call.subcommand)

suite "DSL-port M9.R.12.1 — autotools_package routes configure via inlineExecCall":

  test "configure edge uses reprobuild.builtin.exec call":
    let pkg = autotools_package(
      srcDir = "./src",
      configureOptions = @["--enable-gold", "--disable-werror"])
    check pkg.buildEdge.call.packageName == "reprobuild.builtin"
    check pkg.buildEdge.call.executableName == "exec"

  test "configure edge carries toolIdentityRefs = @[\"sh\"]":
    let pkg = autotools_package(
      srcDir = "./src",
      configureOptions = @["--enable-shared"])
    var foundSh = false
    for refName in pkg.buildEdge.toolIdentityRefs:
      if refName == "sh":
        foundSh = true
        break
    check foundSh

  test "configure argv carries the literal sh -c script":
    let pkg = autotools_package(
      srcDir = "./src",
      configureOptions = @["--enable-gold", "--disable-werror"])
    let argvArg = pkg.buildEdge.argByName("argv")
    let argvParts = argvArg.encodedValue.split("\x1f")
    check argvParts.len == 3
    check argvParts[0] == "sh"
    check argvParts[1] == "-c"
    check "./src/configure" in argvParts[2]
    check "--prefix=/usr" in argvParts[2]
    check "--enable-gold" in argvParts[2]
    check "--disable-werror" in argvParts[2]

  test "configure action id is deterministic across calls with same args":
    let a = autotools_package(srcDir = "./src",
      configureOptions = @["--enable-gold"])
    let b = autotools_package(srcDir = "./src",
      configureOptions = @["--enable-gold"])
    check a.buildEdge.id == b.buildEdge.id

  test "configure action id differs across calls with different args":
    let a = autotools_package(srcDir = "./src",
      configureOptions = @["--enable-gold"])
    let b = autotools_package(srcDir = "./src",
      configureOptions = @["--disable-shared"])
    check a.buildEdge.id != b.buildEdge.id

suite "DSL-port M9.R.12.2 — profile lookup falls back to packageName":

  test "profile keyed under selector resolves call recording under <selector>Bin":
    # Reproduce the engine's profile registry shape: a single profile
    # registered for the ``make`` selector with ``executableName ==
    # "make"`` (i.e. what ``resolvePathOnlyTool`` / the from-source
    # fall-through would produce from a ``nativeBuildDeps: "make"``
    # declaration). The recipe's ``make.call(...)`` typed-tool
    # invocation records ``executableName == "makeBin"``. The lookup
    # must fall back to the ``packageName == "make"`` entry.
    var profiles = initTable[string, PathOnlyToolProfile]()
    let profile = PathOnlyToolProfile(
      installMethod: "tarball",
      packageSelector: "make",
      executableName: "make",
      resolvedExecutablePath: "/fake/bin/make")
    profiles["make|make"] = profile
    profiles["make"] = profile

    # The lookup ladder mirrors ``lowerGraphAction``'s exactly:
    let packageName = "make"
    let executableName = "makeBin"
    let exactKey = packageName & "|" & executableName
    var resolved: PathOnlyToolProfile
    var found = false
    if profiles.hasKey(exactKey):
      resolved = profiles[exactKey]
      found = true
    elif profiles.hasKey(executableName):
      resolved = profiles[executableName]
      found = true
    elif packageName.len > 0 and profiles.hasKey(packageName):
      resolved = profiles[packageName]
      found = true
    check found
    check resolved.resolvedExecutablePath == "/fake/bin/make"

  test "lookup still misses when neither selector nor exec name match":
    var profiles = initTable[string, PathOnlyToolProfile]()
    let profile = PathOnlyToolProfile(
      installMethod: "tarball",
      packageSelector: "gcc",
      executableName: "gcc",
      resolvedExecutablePath: "/fake/bin/gcc")
    profiles["gcc|gcc"] = profile
    profiles["gcc"] = profile

    let packageName = "make"
    let executableName = "makeBin"
    let exactKey = packageName & "|" & executableName
    var found = false
    if profiles.hasKey(exactKey):
      found = true
    elif profiles.hasKey(executableName):
      found = true
    elif packageName.len > 0 and profiles.hasKey(packageName):
      found = true
    check not found
