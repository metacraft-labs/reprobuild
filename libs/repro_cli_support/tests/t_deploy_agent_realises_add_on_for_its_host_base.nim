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
## No mocks: the real adapter, registry helpers and argument builder. The
## running machine's own base decides what `this-host` must give; the test
## derives the expectation from the same observation rather than assuming
## the build host's distribution.

import std/[sets, strutils, tables, unittest]

import repro_profile
import repro_profile_compile
import repro_infra
import repro_infra/addon_diagnostics
import repro_infra/host_base
import repro_deploy_agent
import repro_cli_support/infra_host_registry
import repro_cli_support/deploy_agent
import repro_addon/verified_compile

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
