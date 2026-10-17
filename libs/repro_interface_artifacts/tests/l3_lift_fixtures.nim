## Shared-Development-Services L3 test fixture: producer packages whose
## dev-env services and activities are what the interface lift carries.
##
## Lives in a separate module from the test mains for the reason
## ``activity_params_fixtures.nim`` and ``service_fragment_fixtures.nim``
## give: under ``-d:reproProviderMode`` the ``package`` macro emits a
## ``runPackageProvider`` shim guarded on ``isMainModule``, which would
## take over the test binary. Not named ``t_*`` / ``test_*``, so
## ``scripts/generate_test_edges.nim`` does not register it as a test
## binary of its own.
##
## MOCK POLICY — NO MOCKS. These are real ``package`` blocks expanded by
## the real DSL macro; the records the tests read are the ones the macro
## emitted.
##
## THE THREE SIGNATURE FIXTURES. ``l3SigBaseline``, ``l3SigSameSignature``
## and ``l3SigChangedSignature`` exist for L3's hardest clause — "a change
## to A's service signature re-lifts, re-fingerprints and invalidates B
## (B rebuilds; an unrelated change to A does not)". They are built so
## exactly one thing varies per pair:
##
## * baseline vs sameSignature — IDENTICAL activity signature, DIFFERENT
##   service implementation (other argv, a description, an extra service
##   setter). The lift must produce the same interface fingerprint.
## * baseline vs changedSignature — IDENTICAL service implementation, ONE
##   ``config:`` default changed. The lift must produce a different one.
##
## They declare no executables and no libraries on purpose: those lift
## into ``publicExecutables`` / ``publicLibraries`` carrying
## package-derived provider entry-point ids, which would make the three
## fingerprints differ for a reason that has nothing to do with services.

import repro_project_dsl

type
  LiftDemoDb* = object
    ## A capability type in the shape ``Package-Model.md`` §"Capability
    ## types and platform modules" specifies — "Capability types are
    ## plain Nim object types".
    connectionString*: string
    host*: string

const
  LiftDemoDbValue* = LiftDemoDb(connectionString: "postgres://x", host: "h")

package l3LiftProducer:
  devEnv:
    ## The pre-L2 surface, untouched: a bare activity name lifts nothing,
    ## because it declares nothing to lift. The control for
    ## "``publicActivities`` holds the constructor-shaped ones only".
    activity "default"

    activity sso(db: LiftDemoDb):
      ## The organisation's identity provider.
      config:
        ## The externally visible issuer host.
        externalDomain: string
        ## Whether the issuer URL is https.
        externalSecure: bool = true
        ## Loopback port the issuer binds.
        port: int = 8080

      service zitadel:
        args "start-from-init", "--host", db.host
      service bootstrap:
        args "--bootstrap", $port

    activity edge:
      ## Parameterless, no ``config:``, one service — the shape whose
      ## handle type has exactly one member.
      service nginx:
        args "-c", "etc/nginx.conf"

  ## A PACKAGE-LEVEL service: no declaring activity, so no handle type.
  service standalone:
    args "--standalone"

package l3SigBaseline:
  devEnv:
    activity api(db: LiftDemoDb):
      config:
        port: int = 8080
        issuer: string
      service api:
        args "--port", $port, "--host", db.host

package l3SigSameSignature:
  devEnv:
    activity api(db: LiftDemoDb):
      config:
        port: int = 8080
        issuer: string
      service api:
        ## Same SIGNATURE, different implementation: other argv, a
        ## description, and an extra setter. None of it is what a
        ## consumer compiles against.
        description "a completely different implementation"
        args "--totally", "--different", "--argv", db.connectionString
        args "--and", "--more"

package l3SigChangedSignature:
  devEnv:
    activity api(db: LiftDemoDb):
      config:
        ## ONE character of signature changed: the default moves from
        ## 8080 to 9090. Everything else, including the service body, is
        ## byte-identical to ``l3SigBaseline``.
        port: int = 9090
        issuer: string
      service api:
        args "--port", $port, "--host", db.host
