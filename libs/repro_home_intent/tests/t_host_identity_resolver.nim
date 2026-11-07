## The ONE host-identity resolver (`host_identity.resolveHostFrom` /
## `osHostnameFrom`, reached through `selectHost`), exercised over injected
## inputs so every platform's rule runs on every host
## (Home-Profile-Intent-Layer.md §Host Identity; reprobuild-pm issue
## 2026-10-17-repro-infra-host-identity-differs-from-repro-home).
##
## Why injected inputs: the Windows rule reads `%COMPUTERNAME%` and
## `GetComputerNameW`, which a Linux run cannot set up for real. The
## resolver therefore takes the platform's inputs as data
## (`OsHostnameSources`, with the OS call as a closure), and the process'
## real inputs are only gathered by `currentOsHostnameSources`. This is the
## only seam; the last case drives `selectHost` / `systemHostname` through
## the real process environment of whatever host runs it. The native
## Windows leg (the real `%COMPUTERNAME%` of eli-pc through the real
## `repro`) is a Verification entry of the GM10 milestone.
##
## Cases:
## * `windows_computername_is_lowercased`: `WIN-CI-BARE-001` is the host
##   `win-ci-bare-001`, the name a `hosts:` registry is written with; on
##   Windows `$HOSTNAME` is not consulted and the OS call is not made while
##   the variable names a host.
## * `windows_falls_back_to_the_os_call`: an empty `%COMPUTERNAME%` falls back
##   to `GetComputerNameW`'s answer, normalized the same way.
## * `posix_ignores_computername`: negative control for the old `repro infra`
##   rule, which took `%COMPUTERNAME%` on every platform: on POSIX only
##   `$HOSTNAME` (else gethostname(2)) counts.
## * `posix_hostname_command_output_is_trimmed`: the command's trailing
##   newline is not part of the name.
## * `no_hostname_is_no_identity`: no variable and no OS answer give "", and
##   the resolver refuses rather than inventing `localhost`.
## * `precedence_and_refusals`: `$REPRO_HOST` > `--host` > hostname; the
##   chosen names are used verbatim (only the OS hostname is normalized); a
##   conflicting `--host` and an empty `--host` are refused; the OS is asked
##   for its hostname only when neither override names a host.
## * `select_host_reads_this_process`: `selectHost` over the real
##   environment agrees with `resolveHostFrom` and installs the override that
##   `currentHost()` reads.

import std/[os, strutils, unittest]

import repro_home_intent/host_identity

proc failingProbe(): string =
  ## A probe that must not be reached: the variable already named a host.
  raise newException(AssertionDefect, "the OS hostname call was made")

suite "host identity: one resolver, testable on every platform":

  test "windows_computername_is_lowercased":
    let s = OsHostnameSources(windows: true, computerName: "WIN-CI-BARE-001",
      hostnameEnv: "posix-only-name", probe: failingProbe)
    check osHostnameFrom(s) == "win-ci-bare-001"
    check normalizeHostName("WIN-CI-BARE-001") == "win-ci-bare-001"
    # Through the resolver: no $REPRO_HOST, no --host.
    let id = resolveHostFrom("", "", false, proc (): string = osHostnameFrom(s))
    check id.name == "win-ci-bare-001"
    check id.source == hsHostname

  test "windows_falls_back_to_the_os_call":
    var calls = 0
    let s = OsHostnameSources(windows: true, computerName: "",
      hostnameEnv: "posix-only-name",
      probe: proc (): string =
        inc calls
        " Eli-PC ")
    check osHostnameFrom(s) == "eli-pc"
    check calls == 1

  test "posix_ignores_computername":
    let s = OsHostnameSources(windows: false, computerName: "WIN-DECOY",
      hostnameEnv: "Home-PC", probe: failingProbe)
    check osHostnameFrom(s) == "home-pc"
    check "decoy" notin osHostnameFrom(s)

  test "posix_hostname_command_output_is_trimmed":
    let s = OsHostnameSources(windows: false, computerName: "WIN-DECOY",
      hostnameEnv: "", probe: proc (): string = "M1-Studio\n")
    check osHostnameFrom(s) == "m1-studio"

  test "no_hostname_is_no_identity":
    for windows in [false, true]:
      let s = OsHostnameSources(windows: windows, computerName: "",
        hostnameEnv: "", probe: proc (): string = "")
      check osHostnameFrom(s) == ""
      expect EHostIdentity:
        discard resolveHostFrom("", "", false,
          proc (): string = osHostnameFrom(s))
      # Without a probe at all the answer is the same.
      check osHostnameFrom(OsHostnameSources(windows: windows)) == ""

  test "precedence_and_refusals":
    var asked = 0
    let osName = proc (): string =
      inc asked
      "host-from-os"
    # $REPRO_HOST first; verbatim, not lower-cased.
    let env = resolveHostFrom("Env-Host", "", false, osName)
    check env.name == "Env-Host"
    check env.source == hsEnv
    # The same name in both is accepted.
    check resolveHostFrom("Env-Host", "Env-Host", true, osName).source == hsEnv
    # --host next; verbatim.
    let flag = resolveHostFrom("", "Flag-Host", true, osName)
    check flag.name == "Flag-Host"
    check flag.source == hsFlag
    check asked == 0
    # The hostname last.
    let hostname = resolveHostFrom("", "", false, osName)
    check hostname.name == "host-from-os"
    check hostname.source == hsHostname
    check asked == 1
    # A --host that $REPRO_HOST contradicts.
    try:
      discard resolveHostFrom("env-host", "other-host", true, osName)
      check false
    except EHostIdentity as e:
      check "--host other-host conflicts with $REPRO_HOST=env-host" in e.msg
    # An empty --host is refused, not read as "no flag".
    try:
      discard resolveHostFrom("", "", true, osName)
      check false
    except EHostIdentity as e:
      check "--host needs a non-empty name" in e.msg
    check asked == 1

  test "select_host_reads_this_process":
    let savedRepro = getEnv(HomeHostEnvVar)
    let hadRepro = existsEnv(HomeHostEnvVar)
    const NameVar = when defined(windows): "COMPUTERNAME" else: "HOSTNAME"
    let savedName = getEnv(NameVar)
    let hadName = existsEnv(NameVar)
    defer:
      if hadRepro: putEnv(HomeHostEnvVar, savedRepro)
      else: delEnv(HomeHostEnvVar)
      if hadName: putEnv(NameVar, savedName)
      else: delEnv(NameVar)
      clearOverrides()
    delEnv(HomeHostEnvVar)
    putEnv(NameVar, "Resolver-Test-HOST")
    check systemHostname() == "resolver-test-host"
    let id = selectHost("")
    check id.name == "resolver-test-host"
    check id.source == hsHostname
    check currentHost() == "resolver-test-host"
    check machineHost() == "resolver-test-host"
    putEnv(HomeHostEnvVar, "resolver-env-host")
    let viaEnv = selectHost("resolver-env-host", true)
    check viaEnv.name == "resolver-env-host"
    check currentHost() == "resolver-env-host"
    expect EHostIdentity:
      discard selectHost("resolver-other-host", true)
