## Shared-Development-Services J-2 fixture: TWO shared services and TWO
## `<package>.<activity>.<service>.shared()` calls IN ONE RECIPE.
##
## WHY THIS FIXTURE EXISTS, quoted from the round that owed it: "*The
## announcement suppressed for every resolution after the first* (round
## 3's finding, re-probed on this change). HONOURED by construction: the
## `read N minted attribute(s) from instance <address>` line is inside
## the per-resolution loop, and the rows accumulate across resolutions
## and merge once below it. **NOT asserted end to end for TWO
## resolutions** -- the integration fixture has one -- so what holds it
## is the merge test's order-independent accumulation case plus reading
## the loop. A reviewer wanting it closed should add a second shared
## service to the owner's recipe and a second `.shared()` to the
## consumer's; that is the fixture that would redden it."
##
## This is that fixture. Everything the existing `dss11_resolver_fixtures`
## proves of ONE resolver, this exercises for TWO AT ONCE, and the claim
## it adds is the one a single resolver cannot support: **the resolver is
## PER-SERVICE**, so two shared services resolved in one recipe do not
## collide -- distinct instance keys, distinct registrations, distinct
## contributions, and no member of one reaching the other.
##
## WHY TWO ACTIVITIES AND NOT TWO SERVICES IN ONE. §4.6's spelling has
## THREE components (`<package>.<activity>.<service>`), and the component
## that a per-service resolver could most plausibly ignore is the
## middle one. §9.7 also records that "the edge being a **second shared
## service** rather than part of `sso` is a position" this document
## takes, and the real workspace's two shared services are in two
## activities -- so the fixture is shaped like the thing it stands in
## for.
##
## In a separate module from the test main for the reason L5's, L8's and
## D-SS11's fixtures give: under `-d:reproProviderMode` the `package`
## macro emits a `runPackageProvider` shim guarded on `isMainModule`,
## which would take over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Real `package` blocks with two real `devEnv:` activities, real
## `config:` contribution points, real `converge` setters, real
## `identity` / `scope` / `instance` declarations and two real resolver
## calls in ONE `enable`, all expanded by the real DSL macro.

import repro_project_dsl

const
  Dssj2OwnerName* = "dssj2Owner"
  Dssj2StackName* = "dssj2Stack"
  Dssj2IdpService* = "idp"
  Dssj2ProxyService* = "proxy"
  Dssj2SsoActivity* = "sso"
  Dssj2EdgeActivity* = "edge"
  Dssj2IdpStableId* = "com.example.dssj2.idp"
    ## The same text as the fixture's `identity stable "..."` literal.
    ## `identity stable` requires a STRING LITERAL, so the const cannot
    ## be spliced there; the test asserts the two agree rather than
    ## leaving a reader to compare them by eye.
  Dssj2ProxyStableId* = "com.example.dssj2.proxy"
  Dssj2RelyingParties* = "relyingParties"
  Dssj2Sites* = "sites"
  Dssj2IdpMember* = "dssj2-stack-relying-party"
  Dssj2ProxyMember* = "vhost|stack.dssj2.test|http://127.0.0.1:19080"
    ## Deliberately a DIFFERENT SHAPE from the idp member, so a case
    ## asserting "the idp's members are exactly these" cannot be
    ## satisfied by the proxy's text and the other way round.

package dssj2Owner:
  ## ONE owner, TWO shared services, in two activities.
  devEnv:
    activity sso():
      config:
        relyingParties: seq[string]

      service idp:
        executable executableAtPath("/bin/sh")
        args "-c", "sleep 1"
        args "--relying-parties"
        args relyingParties
        identity stable "com.example.dssj2.idp"
        scope workspace
        workingDirectory "."
        ## D-SS10 (§7.1): a `converge` needs an evaluable probe. Never
        ## evaluated by these cases, so the path need not exist.
        readiness fileExists(".repro/dssj2/idp-ready")
        instance:
          lease keep
        converge relyingParties

    activity edge():
      config:
        sites: seq[string]

      service proxy:
        executable executableAtPath("/bin/sh")
        args "-c", "sleep 1"
        args "--sites"
        args sites
        ## A DIFFERENT stable id, which is what makes the instance keys
        ## differ for a reason the recipe states rather than for one
        ## derived from the service's name.
        identity stable "com.example.dssj2.proxy"
        scope workspace
        workingDirectory "."
        readiness fileExists(".repro/dssj2/proxy-ready")
        instance:
          lease keep
        converge sites

    enable sso
    enable edge

package dssj2Stack:
  ## ONE consumer, ONE activity, TWO `.shared()` calls in ONE `enable`.
  uses:
    "dssj2Owner"

  devEnv:
    activity stack(sso: SharedServiceHandle[LiftedServiceHandle],
                   edge: SharedServiceHandle[LiftedServiceHandle]):
      service app:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dssj2.stack-app"
        scope project

    enable stack(
      sso = dssj2Owner.sso.idp.shared(
        relyingParties = append(Dssj2IdpMember)),
      edge = dssj2Owner.edge.proxy.shared(
        sites = append(Dssj2ProxyMember)))
