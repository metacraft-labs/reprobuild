## The launchd renderer — pinned by text, NOT verified by launchd.
##
## There is no macOS machine in this environment. Every case here is
## about the plist this renders and none is about what launchd does with
## it, and the milestone says so in those words. What these cases buy is
## the difference between "the plist may be wrong" — checkable in a
## minute by anyone with a Mac — and the state they replace, which was a
## Darwin package whose `Distribution` carried a service and whose
## payload carried no daemon at all.
##
## The cases worth reading are the ones where copying the systemd
## renderer's shape would have produced a plausible file that behaves
## differently: `Disabled` (a semantic INVERSION), `KeepAlive` (where
## the nearest-looking value spins), and `after` (which launchd cannot
## express at all).

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc sample(): Distribution =
  result = newDistribution("reprobuild", "0.1.3", toDarwin, prefix = "/usr")
  result.components = @[
    executableComponent("build/bin/repro"),
    executableComponent("build/bin/repro-binary-cache")
  ]
  result.runtime.wrapExecutables = true
  result.services = @[
    ServiceDef(
      name: "repro-daemon",
      displayName: "Reprobuild build daemon",
      description: "Reprobuild per-user build, watch and lease daemon",
      scope: ssUser,
      execComponent: "repro",
      execArgs: @["daemon", "serve"],
      startAtBoot: false,
      restartOnFailure: true,
      after: @[]),
    ServiceDef(
      name: "repro-binary-cache",
      displayName: "Reprobuild binary cache server",
      description: "HTTP :7878",
      scope: ssSystem,
      execComponent: "repro-binary-cache",
      execArgs: @["--root=/var/lib/repro-binary-cache",
                  "--listen=0.0.0.0:7878"],
      environment: @[("REPRO_BINARY_CACHE_ROLE", "server")],
      startAtBoot: false,
      restartOnFailure: true,
      after: @["network.target"])
  ]

proc userSvc(): ServiceDef = sample().services[0]
proc systemSvc(): ServiceDef = sample().services[1]

suite "packaging: the launchd renderer (text only, no Darwin host)":

  test "a system job is a LaunchDaemon and a user job a LaunchAgent":
    # The two scopes launchd genuinely has, which is why -- unlike the
    # MSI -- this renderer drops nothing.
    check launchdPlistPath(sample(), systemSvc()) ==
      "Library/LaunchDaemons/reprobuild.repro-binary-cache.plist"
    check launchdPlistPath(sample(), userSvc()) ==
      "Library/LaunchAgents/reprobuild.repro-daemon.plist"
    check darwinUnsupportedServices(sample()).len == 0

  test "NO PRODUCER CONSUMES THIS RENDERER, and that is the state of it":
    # THE HONEST STATEMENT, MADE CHECKABLE. Every case in this suite
    # pins the plist's TEXT; not one of them puts a plist into a
    # package, because there is no producer that would. macOS's native
    # format is `.pkg`, `pkgbuild` runs on Darwin only, and there is no
    # Darwin host here -- so this renderer is DEAD CODE until a `.pkg`
    # producer exists, and saying so in a comment is a claim that goes
    # stale silently.
    #
    # So it is asserted instead: no registered producer stages a
    # LaunchDaemons or LaunchAgents path. The day one does, this case
    # fails and whoever wrote it has to move the statement rather than
    # discover later that the milestone still says "no consumer".
    #
    # It is NOT an argument for deleting the renderer. What it replaced
    # was worse: a Darwin `Distribution` carrying `services` rendered to
    # nothing at all -- a package with a daemon in its data model and no
    # daemon in its payload, which looks like success.
    resetBuildActionRegistry()
    var found: seq[string] = @[]
    for reg in registeredProducers():
      var dist = sampleDistribution(
        if reg.format == "msi": toWindows else: toLinux)
      dist.runtime.requireEnvDefaultPayload = false
      dist.outputDir = "build/dist"
      dist.stagingRoot = "build/dist/sampletool-0.2.0"
      resetBuildActionRegistry()
      let artifact =
        try: produce(reg.format, dist, noSite())
        except CatchableError: continue
      for f in artifact.tree.files:
        if f.rootRelPath.contains("LaunchDaemons") or
            f.rootRelPath.contains("LaunchAgents"):
          found.add(reg.format & ": " & f.rootRelPath)
    doAssert found.len == 0,
      "a producer now stages a launchd plist (" & found.join(", ") &
      "); this renderer is no longer dead code and the milestone's " &
      "residual has to move"
    # Non-vacuity: the loop really did drive producers, and they really
    # did stage the SERVICE this distribution declares -- in systemd's
    # spelling, which is the point.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    var sawUnit = false
    for f in deb.tree.files:
      if f.rootRelPath.endsWith("sampletool-daemon.service"): sawUnit = true
    check sawUnit
    check registeredProducers().len >= 4
    # ...and the renderer itself still produces a plist when called
    # directly, so "no consumer" is a fact about the callers and not
    # about the code.
    let dist = sampleDistribution(toDarwin)
    check launchdPlistText(dist, dist.services[0]).contains("<plist")

  test "the plist path is ROOT-relative, not prefix-relative":
    # launchd reads four fixed absolute directories and nothing else, so
    # a package installed under /opt still puts its plist here. Same
    # rule, same reason, as systemdUnitPath.
    var elsewhere = sample()
    elsewhere.prefix = "/opt/reprobuild"
    check launchdPlistPath(elsewhere, systemSvc()) ==
      launchdPlistPath(sample(), systemSvc())
    check not launchdPlistPath(elsewhere, systemSvc()).contains("opt")

  test "Disabled INVERTS startAtBoot, which systemd does not need":
    # THE CASE THIS RENDERER EXISTS FOR. A systemd unit a package ships
    # and does not `enable` simply does not run. launchd loads every
    # plist in /Library/LaunchDaemons at boot, so shipping the file IS
    # enabling it -- and a plist that merely omitted the key would make
    # the Darwin package open 0.0.0.0:7878 at install time when every
    # other format's package does not.
    let text = launchdPlistText(sample(), systemSvc())
    check text.contains("<key>Disabled</key>\n  <true/>")
    check text.contains("<key>RunAtLoad</key>\n  <false/>")
    var enabled = systemSvc()
    enabled.startAtBoot = true
    let onText = launchdPlistText(sample(), enabled)
    check onText.contains("<key>Disabled</key>\n  <false/>")
    check onText.contains("<key>RunAtLoad</key>\n  <true/>")

  test "both switches are always written, never left to a default":
    # RunAtLoad and Disabled are two different questions and their
    # defaults have differed between macOS releases. Writing one and
    # omitting the other is how a package acquires behaviour nobody
    # chose.
    for svc in sample().services:
      let text = launchdPlistText(sample(), svc)
      check text.contains("<key>RunAtLoad</key>")
      check text.contains("<key>Disabled</key>")

  test "restartOnFailure is KeepAlive/SuccessfulExit=false, not KeepAlive=true":
    # A bare <key>KeepAlive</key><true/> is the nearest-looking value and
    # is wrong: it restarts a job that exited SUCCESSFULLY, turning a
    # one-shot into a spin.
    let text = launchdPlistText(sample(), systemSvc())
    check text.contains("<key>KeepAlive</key>\n  <dict>")
    check text.contains("<key>SuccessfulExit</key>\n    <false/>")
    check not text.contains("<key>KeepAlive</key>\n  <true/>")
    var never = systemSvc()
    never.restartOnFailure = false
    check not launchdPlistText(sample(), never).contains("KeepAlive")

  test "after is dropped, exactly as it is for the MSI":
    # launchd has no ordering graph. Mapping network.target onto
    # KeepAlive-with-conditions or a launchd socket would be an
    # invention, and the same one the MSI arm refuses.
    let text = launchdPlistText(sample(), systemSvc())
    check systemSvc().after == @["network.target"]
    check not text.contains("network.target")
    check not text.toLowerAscii().contains("after")

  test "the job runs the WRAPPER, matching systemd and not the MSI":
    # launchd forks an ordinary process and a shell script is a fine
    # thing to fork. The Windows SCM's requirement for a service image
    # is what makes that arm the exception, so this is the place the two
    # non-Windows renderers must agree.
    let text = launchdPlistText(sample(), userSvc())
    check text.contains("<string>/usr/bin/repro</string>")
    check not text.contains("repro.real")
    check installedExecPath(sample(), userSvc()) == "/usr/bin/repro"
    # ...and each argument is its own <string>, never one joined line.
    check text.contains("<string>daemon</string>")
    check text.contains("<string>serve</string>")
    check not text.contains("<string>daemon serve</string>")

  test "arguments that look like flags survive verbatim":
    # `--root=PATH` is the form repro-binary-cache's parser accepts and
    # the separated form is refused; a renderer that re-split arguments
    # would produce a service that is installed, enabled and dead.
    let text = launchdPlistText(sample(), systemSvc())
    check text.contains(
      "<string>--root=/var/lib/repro-binary-cache</string>")
    check text.contains("<string>--listen=0.0.0.0:7878</string>")

  test "the environment block appears only when there is one":
    check launchdPlistText(sample(), systemSvc()).contains(
      "<key>REPRO_BINARY_CACHE_ROLE</key>\n    <string>server</string>")
    check not launchdPlistText(sample(), userSvc()).contains(
      "EnvironmentVariables")

  test "the label is unique per service and invents no domain":
    # Reverse-DNS is Apple's CONVENTION; uniqueness is launchd's
    # REQUIREMENT. A layer that followed the convention would have to
    # invent an organisation's domain for every recipe that supplied
    # none.
    let dist = sample()
    check launchdLabel(dist, userSvc()) == "reprobuild.repro-daemon"
    check not launchdLabel(dist, userSvc()).startsWith("com.")
    check launchdLabel(dist, userSvc()) != launchdLabel(dist, systemSvc())
    # A service whose name IS the package name is not doubled.
    var same = userSvc()
    same.name = "reprobuild"
    check launchdLabel(dist, same) == "reprobuild"

  test "XML metacharacters in a description or value cannot break the plist":
    var svc = systemSvc()
    svc.environment = @[("X", "a & b < c > d")]
    let text = launchdPlistText(sample(), svc)
    check text.contains("a &amp; b &lt; c &gt; d")
    check not text.contains("a & b")

  test "the document is a well-formed-looking plist with balanced tags":
    for svc in sample().services:
      let text = launchdPlistText(sample(), svc)
      check text.startsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
      check text.contains("<!DOCTYPE plist PUBLIC")
      check text.count("<dict>") == text.count("</dict>")
      check text.count("<array>") == text.count("</array>")
      check text.count("<plist") == 1
      check text.strip().endsWith("</plist>")
