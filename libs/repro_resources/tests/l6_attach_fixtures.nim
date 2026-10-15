## Shared-Development-Services L6 test fixture: the producer packages the
## attach decision is measured over.
##
## Lives in a separate module from the test main for the reason
## ``l3_lift_fixtures.nim`` gives: under ``-d:reproProviderMode`` the
## ``package`` macro emits a ``runPackageProvider`` shim guarded on
## ``isMainModule``, which would take over the test binary. Not named
## ``t_*`` / ``test_*``, so ``scripts/generate_test_edges.nim`` does not
## register it as a test binary of its own.
##
## MOCK POLICY — NO MOCKS. These are real ``package`` blocks expanded by
## the real DSL macro. The snapshots the tests compare are taken from the
## real ``toProjectInterface`` lift of these packages; nothing about a
## service's interface is hand-written.
##
## HOW THE SET IS BUILT. ``l6AttBase`` is the one definition every other
## fixture is compared against, and each other fixture differs from it in
## EXACTLY ONE declared way — the discipline L3's, L4's and L6's lift
## fixtures all follow, because a pair that differs in two ways cannot
## say which one the decision reacted to.
##
##   l6AttBase            the reference definition
##   l6AttOtherImpl       SAME interface, different argv + description
##                        -> §4.3 row 1, SILENT attach. The gate's control.
##   l6AttAddedKey        + one `config:` key          -> row 2, warn
##   l6AttChangedKeyType  `port` retyped               -> row 2, warn
##   l6AttRequiredKey     `port` loses its default     -> row 2, warn
##   l6AttOtherParamType  the constructor param retyped-> row 2, warn
##   l6AttNoSibling       the sibling service deleted  -> row 2, warn
##   l6AttOtherMajor      `compatibility 3`            -> row 3, REFUSE
##   l6AttUndeclaredA     no `compatibility` at all
##   l6AttUndeclaredB     no `compatibility` at all, identical otherwise
##                        -> row 1 against each other: the undeclared
##                        major is 0 on both sides, which is why 0 and
##                        not 1 is the default.
##   l6AttKeySource       a PACKAGE-LEVEL service with the same declared
##                        identity and scope, so the test has a real
##                        LOWERED `DslServiceDef` to check its projected
##                        instance key against. See its own comment.
##
## AND THE REORDER SET, added by L6's review after it found a real defect
## with exactly these inputs (an empty row-2 warning). These are PAIRS,
## not single-difference variants of ``l6AttBase``, because the property
## is a relation between two spellings of one interface:
##
##   l6AttOrderA/B        two `config:` keys, the two orders
##   l6AttOrderAPlusFront side A + one key inserted AT THE FRONT
##                        -> the ANTI-SPRAY control: one addition and no
##                        reorders
##   l6AttParamOrderA/B   two ACTIVITY PARAMETERS, the two orders, both
##                        `string` so they cannot be told apart by type
##
## They declare no executables and no libraries, for the reason L3's and
## L4's do not: those lift into ``publicExecutables`` carrying
## package-derived provider entry-point ids, which would make every
## fingerprint differ for a reason that has nothing to do with the
## service's interface.

import repro_project_dsl

package l6AttBase:
  devEnv:
    activity sso(pg: string):
      config:
        ## Required — declared with no default, which L5 made a REQUIRED
        ## configurable. It is here because required-ness is part of what
        ## a consumer compiles against, and L6's report turns on whether
        ## carrying it needed a new envelope field.
        externalDomain: string
        port: int = 8080

      service zitadel:
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        args "--bootstrap"
        identity derived
        scope project
        compatibility 2

package l6AttOtherImpl:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        port: int = 8080

      service zitadel:
        ## THE CONTROL (§4.3): the implementation and nothing else.
        ## Different argv, a `description`, a `restart` policy, an extra
        ## `env` pair — none of it is what a consumer compiles against,
        ## so the decision must be SILENT attach with no warning emitted.
        description "a completely different implementation"
        restart "always"
        env("ZITADEL_LOG", "debug")
        args "--totally", "--different", "--argv"
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        args "--bootstrap-differently", "--and-more"
        identity derived
        scope project
        compatibility 2

package l6AttAddedKey:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        port: int = 8080
        ## The one difference.
        fixtureUsers: string = ""

      service zitadel:
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        args "--bootstrap"
        identity derived
        scope project
        compatibility 2

package l6AttChangedKeyType:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        ## The one difference: `port` is a string here.
        port: string = "8080"

      service zitadel:
        args "start-from-init", "--port", port
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        args "--bootstrap"
        identity derived
        scope project
        compatibility 2

package l6AttRequiredKey:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        ## The one difference: `port` loses its default and becomes a
        ## REQUIRED configurable. A consumer's `enable sso(...)` that
        ## compiled against the defaulted form does not typecheck against
        ## this one, so it is an interface change — and the point of the
        ## case is that it is visible WITHOUT a new field on
        ## `InterfaceConfigKey`, because `hasDefault` has carried it
        ## since L3.
        port: int

      service zitadel:
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        args "--bootstrap"
        identity derived
        scope project
        compatibility 2

package l6AttOtherParamType:
  devEnv:
    ## The one difference: the activity's CONSTRUCTOR parameter is retyped.
    activity sso(pg: int):
      config:
        externalDomain: string
        port: int = 8080

      service zitadel:
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      service bootstrap:
        args "--bootstrap"
        identity derived
        scope project
        compatibility 2

package l6AttNoSibling:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        port: int = 8080

      service zitadel:
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

      ## The one difference: no `bootstrap`. A consumer that reached the
      ## sibling through the same activity handle loses a member.

package l6AttOtherMajor:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        port: int = 8080

      service zitadel:
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace
        ## The one difference: a different generation.
        compatibility 3

      service bootstrap:
        args "--bootstrap"
        identity derived
        scope project
        compatibility 2

package l6AttUndeclaredA:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        port: int = 8080

      service zitadel:
        ## No `compatibility` setter — the undeclared major 0.
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace

package l6AttUndeclaredB:
  devEnv:
    activity sso(pg: string):
      config:
        externalDomain: string
        port: int = 8080

      service zitadel:
        ## Also no `compatibility` setter, and identical otherwise. The
        ## pair exists to pin that two definitions that declare nothing
        ## attach SILENTLY rather than refusing each other — the whole
        ## reason the undeclared value is 0 and not 1.
        args "start-from-init", "--port", $port
        identity stable "com.example.l6.sso"
        scope workspace

package l6AttKeySource:
  ## A PACKAGE-LEVEL service, declared so that the test has a REAL
  ## lowered ``DslServiceDef`` with the same ``identity`` and ``scope``
  ## as the fixtures' ``zitadel``.
  ##
  ## WHY IT IS SEPARATE AND WHY IT IS PACKAGE-LEVEL. A ``service``
  ## declared inside ``devEnv: activity <name>(...):`` lowers into the
  ## body of the generated ``reproActivity_<name>`` proc, so its
  ## ``DslServiceDef`` is registered when the activity is ENABLED, not at
  ## module init -- measured on this tree: ``registeredServices(
  ## "l6AttBase")`` holds no ``zitadel``, which is why the key below is
  ## PROJECTED from the lifted row rather than read off a lowered record.
  ## A package-level service registers at module init, so this one gives
  ## the test a real record to CHECK that projection against.
  service zitadel:
    args "--serve"
    identity stable "com.example.l6.sso"
    scope workspace
    compatibility 2

# ---------------------------------------------------------------------------
# THE REORDER PAIRS. Added by L6's review, which found a REAL DEFECT with
# them: the digest below is order-sensitive (deliberately -- see
# ``serviceInterfaceMembers``' own comment on positional ``enable``
# binding) while ``memberDifferences`` keyed both sides on ``(kind, name)``
# only, so a pure reorder warned with an EMPTY member list and §4.3's
# row 2 -- "the warning names ... the members that differ" -- did not
# hold for it. These fixtures are the inputs that measurement was taken
# on, kept as the regression.
#
# They are PAIRS rather than single-difference variants of ``l6AttBase``
# for the reason ``l6AttUndeclaredA`` / ``B`` are a pair: the property
# under test is a relation between two spellings of the SAME interface,
# so both sides have to be written out. Each pair differs in NOTHING but
# the order of two declarations.
# ---------------------------------------------------------------------------

package l6AttOrderA:
  ## The reviewer's exact input, side A: two ``config:`` keys, in this
  ## order. Deliberately NOT ``l6AttBase``'s key set -- two keys and two
  ## plain ``int`` defaults, so the ONLY thing that can differ from side
  ## B is the order they are written in.
  devEnv:
    activity sso(pg: string):
      config:
        first: int = 1
        second: int = 2

      service zitadel:
        args "--serve"
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

package l6AttOrderB:
  ## Side B: the same two keys, written in the reverse order, and
  ## nothing else changed. A consumer's POSITIONAL ``enable
  ## sso(..., 9)`` binds a DIFFERENT key against this definition than
  ## against side A, which is why this is an interface change and why the
  ## digest must keep distinguishing it.
  devEnv:
    activity sso(pg: string):
      config:
        second: int = 2
        first: int = 1

      service zitadel:
        args "--serve"
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

package l6AttOrderAPlusFront:
  ## THE ANTI-SPRAY CASE. Side A with ONE key INSERTED AT THE FRONT and
  ## nothing else touched. Every following key's absolute ordinal moves,
  ## so a position-aware diff that compared ABSOLUTE ordinals would
  ## report one addition plus a reorder for each of ``first`` and
  ## ``second`` -- two reorders nobody made. Compared against side A this
  ## fixture must yield exactly ONE difference, the addition.
  devEnv:
    activity sso(pg: string):
      config:
        zeroth: int = 0
        first: int = 1
        second: int = 2

      service zitadel:
        args "--serve"
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

package l6AttParamOrderA:
  ## The same experiment one category up: two ACTIVITY CONSTRUCTOR
  ## parameters, in this order. A constructor parameter is bound
  ## positionally with no keyword form at all in the ``activity`` call
  ## the DSL generates, so its order is if anything MORE load-bearing
  ## than a ``config:`` key's.
  devEnv:
    activity sso(pg: string, cache: string):
      config:
        port: int = 8080

      service zitadel:
        args "--serve"
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2

package l6AttParamOrderB:
  ## Side B: the same two parameters, same types, reverse order.
  ## Both are ``string``, so the pair cannot be distinguished by TYPE --
  ## only by the name at each position, which is exactly the difference
  ## a ``(kind, name)``-keyed diff is blind to.
  devEnv:
    activity sso(cache: string, pg: string):
      config:
        port: int = 8080

      service zitadel:
        args "--serve"
        identity stable "com.example.l6.sso"
        scope workspace
        compatibility 2
