## Shared-Development-Services L4 test fixture: producer packages whose
## declared service IDENTITY and SCOPE are what the interface lift has to
## carry, plus the four fixtures the fingerprint pairs compare.
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
## pair, the same discipline L3's three follow:
##
## * ``l4SigBaseline`` vs ``l4SigSameImpl`` — IDENTICAL identity and
##   scope, DIFFERENT implementation (other argv, a ``description``). The
##   fingerprint must NOT move: §4.3's middle row only means something if
##   an implementation difference is immaterial.
## * ``l4SigBaseline`` vs ``l4SigOtherIdentity`` — byte-identical except
##   the stable id. It MUST move: a consumer that compiled against
##   instance `A` cannot silently be handed instance `B`.
## * ``l4SigBaseline`` vs ``l4SigOtherScope`` — byte-identical except the
##   scope word. It MUST move, for the same reason: scope is the other
##   half of the key.
##
## They declare no executables and no libraries, for the reason L3's do
## not: those lift into ``publicExecutables`` carrying package-derived
## provider entry-point ids, which would make every fingerprint differ
## for a reason that has nothing to do with identity.

import repro_project_dsl

package l4LiftProducer:
  devEnv:
    activity sso():
      config:
        port: int = 8080

      service zitadel:
        ## The worked case's shared identity provider: durable state
        ## (organisations, users, OIDC clients) that must outlive a
        ## change to its own definition, which is §4.2's "if and only
        ## if" for `stable`.
        args "start-from-init"
        identity stable "com.metacraft-labs.sso"
        scope workspace

      service bootstrap:
        ## No durable state, so `derived` — and written out loud, because
        ## §4.2 makes the choice the author's and not the reader's guess.
        args "--bootstrap", $port
        identity derived
        scope project

    activity edge:
      service nginx:
        ## Neither setter: §4's two defaults.
        args "-c", "etc/nginx.conf"

  ## A PACKAGE-LEVEL service, at the widest scope.
  service hostAgent:
    args "--agent"
    identity stable "com.metacraft-labs.host-agent"
    scope system

  service perUser:
    args "--per-user"
    scope user

package l4SigBaseline:
  devEnv:
    activity api():
      service api:
        args "--port", "8080"
        identity stable "com.example.api"
        scope workspace

package l4SigSameImpl:
  devEnv:
    activity api():
      service api:
        ## Same identity, same scope, COMPLETELY different argv plus a
        ## description. None of it is what a consumer compiles against.
        description "a completely different implementation"
        args "--totally", "--different", "--argv"
        identity stable "com.example.api"
        scope workspace

package l4SigOtherIdentity:
  devEnv:
    activity api():
      service api:
        args "--port", "8080"
        ## ONE thing differs from `l4SigBaseline`: the id.
        identity stable "com.example.api.OTHER"
        scope workspace

package l4SigOtherScope:
  devEnv:
    activity api():
      service api:
        args "--port", "8080"
        identity stable "com.example.api"
        ## ONE thing differs from `l4SigBaseline`: the scope.
        scope user
