## STAGE 2 — the undeclared-environment population is COUNTED and
## REPORTED, and the number is the real one.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The census is taken by the real `runBuild` over a real graph of real
## `sh` subprocesses, and the header line is produced by the real
## `environmentInheritanceHeaderLine` that `repro build` logs. A mock
## anywhere would defeat the point: the defect class this guards against
## is a reported number that is a constant rather than a measurement
## (the `providerCompileAction` `status`/`launched` defect), and only the
## production producer can be checked for that.
##
## ## What this is for
##
## Reprobuild applies an action's `env` as an OVERLAY on the environment
## the build process inherited. An action that declares nothing therefore
## runs with the developer's or the CI runner's entire environment, and
## nothing anywhere records that it did. That is a real channel, it is
## currently silent, and closing it will break edges.
##
## So it is measured before it is touched. This file exists to make sure
## the measurement is a measurement:
##
## 1. the census counts what is actually in the graph, per class;
## 2. the classes are not confused with one another;
## 3. built-in (non-forking) actions are excluded from the denominator,
##    because an action that never spawns cannot inherit an environment
##    and would only dilute the number;
## 4. the header line reports the census it is given, and reports a
##    DIFFERENT census differently — the check that a reported figure is
##    not a constant.
##
## Governing spec text: Filesystem-Policy-And-Observed-Inputs.md
## §"The Environment An Action Is Given" / "Measuring The Inherited
## Channel" — "Before P2 is enforced, a build reports how much of its
## graph runs on an environment Reprobuild does not control."
##
## This file asserts NOTHING about inheritance being reduced. Stage 2 is
## a count, not a change.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_hash

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("env-inheritance-census." & name)

proc shPath(): string = findExe("sh")

suite "the undeclared-environment population is measured":

  test "the census counts each declaration class over a real build":
    let sh = shPath()
    if sh.len == 0:
      skip()
    else:
      let root = createTempDir("repro-env-census-", "")
      defer: removeDir(root)
      let workRoot = root / "work"
      createDir(workRoot / "out")

      proc edge(id: string; env: openArray[string] = [];
                passthrough: openArray[string] = []): BuildAction =
        action(id,
          [sh, "-c", "printf 'ok\\n' > out/" & id & ".txt"],
          cwd = workRoot,
          outputs = ["out/" & id & ".txt"],
          cacheable = false,
          weakFingerprint = weak(id),
          env = env,
          envPassthrough = passthrough,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())

      # Five process edges spanning every class, plus one built-in that
      # must NOT be counted (it does not fork, so it cannot inherit).
      #
      # `passonly` is the one that stops the classes from being counted
      # by a single test. An action that names a passthrough variable
      # and declares no value is still an action that SAYS something
      # about its environment, so it must not fall into "declares
      # nothing". Measured: without this edge in the fixture, a mutation
      # that drops the passthrough clause from the undeclared test goes
      # completely undetected.
      # The three counters must come out DISTINCT. With every class at
      # the same count a mutation that swaps two counters passes, and
      # this fixture originally had 2/2/2 — the swap mutation survived
      # it. Sized here for 4 declaring, 3 passthrough, 2 undeclared, so
      # no permutation of the three reads as the identity.
      let g = graph([
        edge("bare"),                                   # declares nothing
        edge("alsobare"),                               # declares nothing
        edge("declares", env = ["FOO=1"]),              # declares a value
        edge("declares2", env = ["BAR=2"]),             # declares a value
        edge("passonly", passthrough = ["REPRO_TEST_HOST_VAR"]),  # names only
        edge("both", env = ["PATH=/tool/bin"],
             passthrough = ["PATH"]),                   # value + name
        edge("both2", env = ["QUX=3"],
             passthrough = ["REPRO_TEST_OTHER_VAR"]),   # value + name
        builtinAction(bakEnsureDir, "mkdir",
          cwd = workRoot,
          outputs = ["out"],
          weakFingerprint = weak("mkdir"),
          governingLockIdentity = lockIdentityOutsideSolvedGraph())])

      var config = defaultBuildEngineConfig(root / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 2'u32
      let census = runBuild(g, config).environmentInheritance
      checkpoint("census: total=" & $census.totalActions &
        " declaring=" & $census.declaringActions &
        " passthrough=" & $census.passthroughActions &
        " undeclared=" & $census.undeclaredActions)

      # The built-in is excluded: 8 actions in the graph, 7 in the
      # denominator.
      check census.totalActions == 7
      # `declares`, `declares2`, `both`, `both2` carry a NAME=VALUE
      # Reprobuild chose.
      check census.declaringActions == 4
      # `passonly`, `both`, `both2` name a host-valued variable.
      check census.passthroughActions == 3
      # Only `bare` and `alsobare` say nothing at all — `passonly` says
      # something even though it declares no value.
      check census.undeclaredActions == 2
      # Distinct by construction, so no counter can stand in for
      # another.
      check census.declaringActions != census.passthroughActions
      check census.passthroughActions != census.undeclaredActions
      check census.declaringActions != census.undeclaredActions
      # Every action is in the denominator, and no action is counted as
      # saying nothing while also being counted as saying something.
      check census.undeclaredActions <= census.totalActions
      check census.declaringActions + census.undeclaredActions <=
        census.totalActions

  test "the header line reports the census, and is not a constant":
    # The defect this forbids: a reported figure that does not depend on
    # what it claims to report. Two different censuses must produce two
    # different lines, and each must state its own numbers.
    let heavy = EnvironmentInheritanceCensus(
      totalActions: 200, declaringActions: 20,
      passthroughActions: 8, undeclaredActions: 180)
    let light = EnvironmentInheritanceCensus(
      totalActions: 200, declaringActions: 190,
      passthroughActions: 190, undeclaredActions: 10)

    let heavyLine = environmentInheritanceHeaderLine(heavy)
    let lightLine = environmentInheritanceHeaderLine(light)
    checkpoint("heavy: " & heavyLine)
    checkpoint("light: " & lightLine)

    check heavyLine != lightLine
    for fragment in ["20/200", "8", "180", "90%"]:
      checkpoint("heavy fragment: " & fragment)
      check heavyLine.contains(fragment)
    for fragment in ["190/200", "10", "5%"]:
      checkpoint("light fragment: " & fragment)
      check lightLine.contains(fragment)

    # The count of actions that DECLARE nothing must not be presented as
    # the count that INHERITS nothing. `env` is an overlay on the build
    # process environment, so every process action is exposed to the host
    # -- the exposed population is the TOTAL. A line that reported only
    # the narrow number would say the channel is closed on a graph where
    # it is open for every edge, which is exactly what this repository's
    # own graph looks like (0 declare nothing, 1391 inherit).
    check heavyLine.contains("200")
    for line in [heavyLine, lightLine]:
      check line.contains("inherit the build environment")
      check line.contains("overlay")

    # An empty graph says so rather than dividing by zero.
    let empty = environmentInheritanceHeaderLine(
      EnvironmentInheritanceCensus())
    checkpoint("empty: " & empty)
    check empty.len > 0
    check not empty.contains("%")

    # It is a FACT line, not a warning. A measurement dressed as a
    # warning is a measurement people learn to skip, and nothing here is
    # wrong yet — stage 2 changes no behaviour.
    for line in [heavyLine, lightLine, empty]:
      check not line.toLowerAscii.contains("warning")
      check not line.toLowerAscii.contains("error")
