## The deploy agent realises an add-on selection for the base of the host it
## compiles on, as `repro infra plan` does there (ReproOS-Add-On-Mode §8.1,
## §8.3 *Services on Arch*): `add-on-arch` on an Arch-family base,
## `add-on-debian` on a Debian-family one, `EAddOnUnsupportedBase` otherwise.
## Before, `--system-mode addOn` always meant `add-on-debian`, so an Arch
## host's agent compiled with the Debian classes (a `.deb` closure
## projected as shared).
##
## 1. `addOnRealisationFor` maps a base to its realisation; the registry's
##    `realisationFor` and the agent's compile share it.
## 2. `compileTargetFor` takes the base: `this-host` observes the running
##    machine (`observeHostBase`, the operator path's observation), `arch` and
##    `debian` name it, "" keeps the producer's default (`debian`); a base
##    with another mode, or an unknown one, is refused.
## 3. The compile an agent runs on its host (`verified_compile.compileFactArgs`)
##    asks for `this-host` whenever the pin's selection is `addOn`.
## 4. The realisation never changes the compiled text, only what is
##    refused: an accepted profile adapts to the same `SystemProfile` under
##    both, so the producer's pin digest still reproduces on an Arch host.
##
## 5. An agent whose compiler predates `--system-base` (spec §13 decision
##    134, as amended at AR1 review round 2): it retries without the option
##    only on the usage exit (2); a target the compiler refuses -- an
##    unreadable `os-release` among them -- exits 3 and is never retried; a
##    retried compile is refused when it reports the pinned revision, and
##    on any host that is not Debian-family it is refused as the revision
##    mismatch; on a Debian-family host the retry reaches the pin check,
##    which reports the mismatch.
##
## No mocks for 1-4: the real adapter, registry helpers and argument
## builder. The running machine's own base decides what `this-host` must
## give; the test derives the expectation from the same observation rather
## than assuming the build host's distribution.
##
## Two stand-ins in 5, both justified: (a) the compiler is a closure
## answering as a compiler of an older revision would (the usage exit for
## the unknown option, then a stdio result with its own revision), because
## the point is a revision that is NOT this tree's, which no build of this
## tree can be; the closure is passed through the same `run` parameter the
## agent's real compile runs through. (b) An unreadable `os-release` is the
## observation `classifyHostBase` gives when no file was read, passed
## through `resolveCompileTarget`'s `observe` parameter, because the test
## must not make the build host's own `/etc/os-release` unreadable; the
## real command uses `observeHostBase`, which returns exactly that value in
## that case.

import std/[base64, json, sets, strutils, tables, unittest]

import repro_profile
import repro_profile_compile
import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/host_base
import repro_deploy_agent
import repro_cli_support/infra_host_registry
import repro_cli_support/deploy_agent
import repro_addon/verified_compile
import repro_addon/host_exec

proc base(id, idLike: string): HostBase =
  var osr = {"ID": id}.toTable
  if idLike.len > 0: osr["ID_LIKE"] = idLike
  classifyHostBase(osr, "/etc/os-release", true)

suite "the add-on realisation follows the host's base":
  test "addOnRealisationFor maps each family, and refuses the rest":
    check addOnRealisationFor(base("arch", "")) == srAddOnArch
    check addOnRealisationFor(base("omarchy", "arch")) == srAddOnArch
    check addOnRealisationFor(base("debian", "")) == srAddOnDebian
    check addOnRealisationFor(base("raspbian", "debian")) == srAddOnDebian
    expect EAddOnUnsupportedBase:
      discard addOnRealisationFor(base("fedora", ""))
    expect EAddOnUnsupportedBase:
      discard addOnRealisationFor(base("nixos", ""))

  test "compileTargetFor realises addOn for the base it is given":
    check compileTargetFor("h", "", "", "addOn", @[], "arch").realisation ==
      srAddOnArch
    check compileTargetFor("h", "", "", "addOn", @[], "debian").realisation ==
      srAddOnDebian
    # The producer's default, unchanged.
    check compileTargetFor("h", "", "", "addOn").realisation == srAddOnDebian
    check compileTargetFor("h", "", "", "full").realisation == srFull

  test "this-host is the operator path's observation of the running machine":
    var expected: SystemRealisation
    var refused = false
    try:
      expected = addOnRealisationFor(observeHostBase())
    except EAddOnUnsupportedBase:
      refused = true
    if refused:
      expect EAddOnUnsupportedBase:
        discard compileTargetFor("h", "", "", "addOn", @[], SystemBaseThisHost)
    else:
      check compileTargetFor("h", "", "", "addOn", @[],
        SystemBaseThisHost).realisation == expected

  test "a base with another mode, or an unknown base, is refused":
    expect ValueError:
      discard compileTargetFor("h", "", "", "full", @[], "arch")
    expect ValueError:
      discard compileTargetFor("h", "", "", "", @[], SystemBaseThisHost)
    expect ValueError:
      discard compileTargetFor("h", "", "", "addOn", @[], "gentoo")

  test "an agent's own compile asks for its host's base when the pin is addOn":
    var m: DeployManifest
    m.compiledProfile = CompiledProfilePin(digest: "sha256:" & "0".repeat(64),
      platform: "linux", arch: "x86_64", host: "h", systemMode: "addOn")
    let args = compileFactArgs(m)
    check "--system-base" in args
    check args[args.find("--system-base") + 1] == "this-host"
    m.compiledProfile.systemMode = "full"
    m.compiledProfile.systemActivities = @["web"]
    check "--system-base" notin compileFactArgs(m)

  test "an accepted profile adapts to the same text under both realisations":
    var p = ProfileIntent(name: "h")
    p.addOn = AddOnIntent(declared: true, managedEtcPrefixes: @["/etc/app/"])
    systemdSystemUnit(p.resources, name = "app.service",
      content = "[Service]\nExecStart=/repro/store/prefixes/app/1-0123456789abcdef/bin/app\n",
      address = "app")
    fsSystemFile(p.resources, path = "/etc/app/app.conf", content = "x\n",
      address = "conf")
    let deb = adaptSystemProfile(p, compileTargetFor("h", "", "", "addOn"))
    let arch = adaptSystemProfile(p, compileTargetFor("h", "", "", "addOn", @[],
                                                      "arch"))
    check renderSystemProfileToText(deb.profile) ==
      renderSystemProfileToText(arch.profile)
    check deb.projection.profile == "add-on-debian"
    check arch.projection.profile == "add-on-arch"

proc unreadableOsRelease(): HostBase =
  ## What ``observeHostBase`` returns when no ``os-release`` was readable.
  classifyHostBase(initTable[string, string](), "", true)

suite "an agent whose compiler predates --system-base":
  # The compiler is a closure that answers as a compiler of the revision
  # before the option did: it refuses the option as a usage error (exit 2)
  # and compiles without it, reporting its own revision.
  proc oldCompiler(calls: ref seq[seq[string]]; revision = "0ld0ld0ld0"):
      proc(a: seq[string]): HostToolResult =
    result = proc(a: seq[string]): HostToolResult =
      calls[].add(a)
      if "--system-base" in a:
        return HostToolResult(exitCode: 2, output: "repro deploy-agent " &
          "compile-profile: unknown option --system-base\n")
      HostToolResult(exitCode: 0, output: verified_compile.CompiledProfileStdioMarker &
        base64.encode($(%*{"canonical": base64.encode("x"),
          "actions": base64.encode("[]"), "revision": revision})) & "\n")

  proc pinned(): DeployManifest =
    result.compiledProfile = CompiledProfilePin(digest: "sha256:" &
      "1".repeat(64), compilerRevision: "a8f640f709", platform: "linux",
      arch: "x86_64", host: "h", systemMode: "addOn")

  proc agentArgv(m: DeployManifest): seq[string] =
    @["/x/reprobuild", "deploy-agent", "compile-profile", "--stdio"] &
      compileFactArgs(m)

  test "an unreadable os-release is a target refusal (exit 3), never retried":
    let r = resolveCompileTarget("h", "linux", "x86_64", "addOn", @[],
      SystemBaseThisHost, unreadableOsRelease)
    check r.exitCode == deploy_agent.CompileProfileTargetExit
    check r.exitCode != verified_compile.CompileProfileUsageExit
    check verified_compile.CompileProfileTargetExit ==
      deploy_agent.CompileProfileTargetExit
    check "EAddOnUnsupportedBase" in r.message
    # The agent sees that exit and does not fall back.
    let calls = new seq[seq[string]]
    let refusing = proc(a: seq[string]): HostToolResult =
      calls[].add(a)
      HostToolResult(exitCode: r.exitCode, output: r.message)
    let attempt = runCompileForAnyRevision(agentArgv(pinned()), refusing)
    check calls[].len == 1
    check not attempt.retriedWithoutBase
    check attempt.result.exitCode == deploy_agent.CompileProfileTargetExit
    # A named base the compiler refuses is the same exit.
    check resolveCompileTarget("h", "linux", "x86_64", "addOn", @[],
      "nosuchbase").exitCode == deploy_agent.CompileProfileTargetExit

  test "an old compiler on an Arch host is refused, naming the revision mismatch":
    let m = pinned()
    let calls = new seq[seq[string]]
    let argv = agentArgv(m)
    let attempt = runCompileForAnyRevision(argv, oldCompiler(calls))
    check calls[].len == 2
    check calls[][1] == withoutSystemBase(argv)
    check attempt.retriedWithoutBase
    let res = parseCompileOutput(attempt.result.output)
    check res.ok and res.revision == "0ld0ld0ld0"
    let why = retriedCompileRefusal(attempt.retriedWithoutBase, res.revision,
      m.compiledProfile.compilerRevision, hostIsDebianFamily = false)
    check why.startsWith(CompilerRevisionMismatch)
    check "0ld0ld0ld0" in why and "a8f640f709" in why

  test "an old compiler on a Debian host: the retry reaches the pin check":
    let m = pinned()
    let calls = new seq[seq[string]]
    let attempt = runCompileForAnyRevision(agentArgv(m), oldCompiler(calls))
    check calls[].len == 2 and attempt.retriedWithoutBase
    let res = parseCompileOutput(attempt.result.output)
    check retriedCompileRefusal(true, res.revision,
      m.compiledProfile.compilerRevision, hostIsDebianFamily = true) == ""
    check compiledProfileRefusal(m, res.canonical, res.actionsJson,
      res.revision).startsWith(CompilerRevisionMismatch)

  test "a retried compile that reports the pinned revision is refused":
    let m = pinned()
    let calls = new seq[seq[string]]
    let attempt = runCompileForAnyRevision(agentArgv(m),
      oldCompiler(calls, revision = m.compiledProfile.compilerRevision))
    let res = parseCompileOutput(attempt.result.output)
    for debian in [true, false]:
      let why = retriedCompileRefusal(attempt.retriedWithoutBase, res.revision,
        m.compiledProfile.compilerRevision, debian)
      check "pinned revision" in why

  test "a compile that was not retried is left to the pin check":
    check retriedCompileRefusal(false, "0ld", "a8f640f709", false) == ""

  test "a profile the realisation refuses (exit 1) is never retried":
    let calls = new seq[seq[string]]
    let refusing = proc(a: seq[string]): HostToolResult =
      calls[].add(a)
      HostToolResult(exitCode: 1, output: "EAddOnOutOfScope: ...")
    let attempt = runCompileForAnyRevision(@["c", "--system-base", "this-host"],
                                           refusing)
    check attempt.result.exitCode == 1 and calls[].len == 1
    check not attempt.retriedWithoutBase
