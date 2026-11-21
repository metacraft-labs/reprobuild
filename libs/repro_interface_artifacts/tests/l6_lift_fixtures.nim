## Shared-Development-Services L6 test fixture: producer packages whose
## declared MAJOR COMPATIBILITY FIELD is what the interface lift has to
## carry, plus the fixtures the fingerprint pairs compare.
##
## Lives in a separate module from the test main for the reason
## ``l3_lift_fixtures.nim`` gives: under ``-d:reproProviderMode`` the
## ``package`` macro emits a ``runPackageProvider`` shim guarded on
## ``isMainModule``, which would take over the test binary. Not named
## ``t_*`` / ``test_*``, so ``scripts/generate_test_edges.nim`` does not
## register it as a test binary of its own.
##
## MOCK POLICY — NO MOCKS. These are real ``package`` blocks expanded by
## the real DSL macro; the records the tests read are the ones the macro
## emitted.
##
## THE FOUR FINGERPRINT FIXTURES, built so exactly one thing varies per
## pair — the same discipline L3's three and L4's four follow:
##
## * ``l6SigBaseline`` vs ``l6SigSameImpl`` — IDENTICAL identity, scope
##   and major, DIFFERENT implementation (other argv, a ``description``).
##   The fingerprint must NOT move. This is §4.3's control: "a change to
##   the *implementation only* (args, config bytes) must attach with NO
##   warning emitted".
## * ``l6SigBaseline`` vs ``l6SigOtherMajor`` — byte-identical except the
##   declared major. It MUST move: the major is signature, and a consumer
##   that compiled against generation 2 must recompile when the
##   generation changes.
## * ``l6SigBaseline`` vs ``l6SigNoMajor`` — byte-identical except that
##   the setter is absent. It MUST move too, and for the same reason the
##   DSL refuses ``compatibility 0``: "declared nothing" is major 0, and
##   0 is a different generation from 2.
##
## They declare no executables and no libraries, for the reason L3's and
## L4's do not: those lift into ``publicExecutables`` carrying
## package-derived provider entry-point ids, which would make every
## fingerprint differ for a reason that has nothing to do with the major.

import repro_project_dsl

package l6LiftProducer:
  devEnv:
    activity sso():
      config:
        port: int = 8080

      service zitadel:
        ## The worked case's shared identity provider. Declares a major,
        ## because §4.3's refusal is the outcome that protects a consumer
        ## from being handed a handle whose members it cannot use.
        args "start-from-init"
        identity stable "com.metacraft-labs.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        ## Declares NO major, so it carries the undeclared 0 — which is
        ## what every service in every recipe written before this setter
        ## existed carries, and what a v24 artifact decodes to.
        args "--bootstrap", $port
        identity derived
        scope project

    activity edge:
      service nginx:
        ## First generation, written out loud.
        args "-c", "etc/nginx.conf"
        compatibility 1

  ## A PACKAGE-LEVEL service with a declared major, so the lift is
  ## exercised on the row shape that has no declaring activity.
  service hostAgent:
    args "--agent"
    identity stable "com.metacraft-labs.host-agent"
    scope system
    compatibility 7

  ## The LARGEST major the field can hold. It is here because a literal
  ## above `int32` range parses as `nnkInt64Lit` rather than `nnkIntLit`,
  ## which the first draft of the `compatibility` setter refused -- found
  ## by this milestone's probe sweep, and this fixture is what keeps it
  ## closed end to end rather than only at the refusal site.
  service maxGen:
    args "--max-generation"
    compatibility 4294967295

package l6SigBaseline:
  devEnv:
    activity api():
      service api:
        args "--port", "8080"
        identity stable "com.example.api"
        scope workspace
        compatibility 2

package l6SigSameImpl:
  devEnv:
    activity api():
      service api:
        ## Same identity, same scope, same major, COMPLETELY different
        ## argv plus a description. None of it is what a consumer
        ## compiles against.
        description "a completely different implementation"
        args "--totally", "--different", "--argv"
        identity stable "com.example.api"
        scope workspace
        compatibility 2

package l6SigOtherMajor:
  devEnv:
    activity api():
      service api:
        args "--port", "8080"
        identity stable "com.example.api"
        scope workspace
        ## ONE thing differs from `l6SigBaseline`: the major.
        compatibility 3

package l6SigNoMajor:
  devEnv:
    activity api():
      service api:
        args "--port", "8080"
        identity stable "com.example.api"
        scope workspace
        ## ONE thing differs from `l6SigBaseline`: there is no
        ## `compatibility` setter at all.
