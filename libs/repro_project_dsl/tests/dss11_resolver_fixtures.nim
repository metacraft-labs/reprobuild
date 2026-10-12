## Shared-Development-Services D-SS11 (§4.6) fixture: one OWNER package
## declaring a shared service with two contribution points, and two
## CONSUMER packages reaching it through the resolver
## `<package>.<service>.shared(...)`.
##
## §4.6's worked shape, entire: the owner declares and converges; each
## consumer resolves at its OWN `enable <activity>(...)` call and passes
## its contributions as ARGUMENTS of that call. No consumer names a
## hostname, no consumer binds a configurable, and no consumer writes a
## `contribute:` section -- which is the point, because L9 measured that
## lane as intra-process and therefore unable to reach the owner at all.
##
## In a separate module from the test main for the reason L5's, L8's and
## L9's fixtures give: under `-d:reproProviderMode` the `package` macro
## emits a `runPackageProvider` shim guarded on `isMainModule`, which
## would take over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Real `package` blocks with a real `devEnv:` activity, a real
## `config:` block whose keys are real contribution points, real
## `converge` setters and real resolver calls, all expanded by the real
## DSL macro. The claim under test is what the real lowering carries.
##
## THREE CONTROLS, each the absence of one thing under test:
##
##   * `plain` is a session-owned service in the SAME activity: no
##     `instance:` block and no `converge`. Every assertion about a
##     shared service's lifted contribution points would pass for an
##     implementation that set them unconditionally without it.
##   * `dss11Quiet` is a consumer that resolves the SAME service and
##     contributes NOTHING. Without it, "the resolution travelled"
##     could not be distinguished from "a contribution travelled".
##   * `dss11Unresolved` is a consumer with a `devEnv:` activity and NO
##     resolver at all, so `sharedResolutions` being non-empty is a
##     property of writing a resolver rather than of having a dev-env.

import repro_project_dsl

const
  Dss11IdpStableId* = "com.example.dss11.idp"
    ## The same text as the fixture's `identity stable "..."` literal.
    ## `identity stable` requires a STRING LITERAL, so this const cannot
    ## be spliced there; the test asserts the two agree rather than
    ## leaving a reader to compare them by eye.
  Dss11PlainStableId* = "com.example.dss11.plain"
  Dss11RelyingParties* = "relyingParties"
  Dss11FixtureUsers* = "fixtureUsers"
  Dss11LoudMember* = "dss11-loud-rp"
  Dss11LoudFixtureUser* = "dev@dss11.test"

package dss11Owner:
  devEnv:
    activity sso():
      config:
        ## Two contribution points -- `seq[string]` with no default, so
        ## `recordContributionPoint` seeds `@[]` rather than making them
        ## required (L8's rule: "no relying parties have been
        ## contributed yet" is a VALUE, not an absence).
        relyingParties: seq[string]
        fixtureUsers: seq[string]

      service idp:
        executable executableAtPath("/bin/sh")
        args "-c", "sleep 1"
        args "--relying-parties"
        args relyingParties
        identity stable "com.example.dss11.idp"
        scope workspace
        workingDirectory "."
        ## D-SS10 (§7.1): `readiness none` cannot order a registration,
        ## and this service `converge`s two points. An evaluable probe is
        ## what makes the edge's completion mean something. The probe is
        ## never evaluated by these cases -- they lift and compare
        ## interfaces -- so the path need not exist.
        readiness fileExists(".repro/dss11/ready")
        instance:
          lease keep
        converge relyingParties, fixtureUsers

      ## THE CONTROL: session-owned, no `instance:`, no `converge`.
      service plain:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dss11.plain"
        scope project

    enable sso

package dss11Loud:
  ## A consumer that contributes to BOTH points, with two members on one
  ## of them -- the shape §9.3's "contributes a lot" consumer has.
  uses:
    "dss11Owner"

  devEnv:
    activity stack(sso: SharedServiceHandle[LiftedServiceHandle]):
      service app:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dss11.loud-app"
        scope project

    enable stack(sso = dss11Owner.sso.idp.shared(
      relyingParties = append(Dss11LoudMember, "dss11-loud-second"),
      fixtureUsers = append(@[Dss11LoudFixtureUser])))

package dss11Quiet:
  ## A consumer that resolves the same service and contributes NOTHING.
  ## §9.4's "contributes little", taken to its limit.
  uses:
    "dss11Owner"

  devEnv:
    activity ide(sso: SharedServiceHandle[LiftedServiceHandle]):
      service host:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dss11.quiet-host"
        scope project

    enable ide(sso = dss11Owner.sso.idp.shared())

package dss11Unresolved:
  ## A consumer with a dev-env and NO resolver. The control for every
  ## assertion that a resolution reached the artifact.
  uses:
    "dss11Owner"

  devEnv:
    activity bare():
      service only:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dss11.unresolved-only"
        scope project

    enable bare
