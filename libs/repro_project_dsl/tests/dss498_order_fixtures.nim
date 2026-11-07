## Shared-Development-Services, reprobuild issue #498 fixture: ONE
## package, TWO activities, and a contribution made by one activity's
## body to the OTHER activity's contribution point -- written out twice,
## once in each declaration order.
##
## WHY TWO PACKAGES AND NOT ONE. The property under test is that
## DECLARATION ORDER IS NOT SEMANTICALLY SIGNIFICANT, so the two orders
## have to exist side by side in one compilation and be lowered by the
## same macro expansion in the same process. Two packages whose bodies
## are character-for-character mirror images (only the package name, the
## key it names and the `identity stable` literal differ) is the only
## shape that gives a test both orders to compare; one package written
## twice in two modules would compare two processes.
##
## In a separate module from the test main for the reason L5's, L8's and
## D-SS11's fixtures give: under `-d:reproProviderMode` the `package`
## macro emits a `runPackageProvider` shim guarded on `isMainModule`,
## which would take over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Real `package` blocks with a real `devEnv:` body, real `activity`
## declarations, a real `config:` contribution point, a real `converge`
## setter and a real `args <point>` on a real `service`, all expanded by
## the real DSL macro and folded by the real `dsl_port_runtime` fold.
##
## THE CONTRIBUTION IS WRITTEN AS A RAW `contributeMembers` CALL, and
## that is the shape the issue names rather than a shortcut: §9.1.1's
## measurement is of exactly this ("an activity body CAN call
## `contributeMembers("<pkg>.<activity>.<point>", ...)` -- it compiles,
## it runs, and the key resolves"), because `contribute:` is a
## PACKAGE-level section that runs at module init and therefore cannot
## be ordered against an activity body at all. The funnel is the same
## one the `contribute:` lowering emits into, not a stub of it.

import repro_project_dsl

const
  Dss498OwnerDefault* = "owner-default"
    ## The owner's own construction default for the point.
  Dss498LateMember* = "from-the-other-activity"
    ## The member the OTHER activity's body contributes.
  Dss498ArgvFlag* = "--members"
  Dss498ExpectedArgv* = @[Dss498ArgvFlag, Dss498OwnerDefault,
                          Dss498LateMember]
    ## What BOTH orders must put on the service's command line. Named
    ## here so the two cases compare against one text rather than
    ## against each other alone -- two artifacts can agree and both be
    ## wrong.
  Dss498ExpectedMembers* = @[Dss498OwnerDefault, Dss498LateMember]
  Dss498OwnerFirstName* = "dss498OwnerFirst"
  Dss498ContributorFirstName* = "dss498ContributorFirst"
  Dss498ExplicitOverrideName* = "dss498ExplicitOverride"
  Dss498ExplicitMember* = "explicit-at-the-enable-site"
  Dss498ServiceName* = "svc"
  Dss498OwnerActivity* = "owner"
  Dss498ContributorActivity* = "contributor"
  Dss498PointName* = "members"
  Dss498OwnerFirstKey* =
    Dss498OwnerFirstName & "." & Dss498OwnerActivity & "." &
      Dss498PointName
  Dss498ContributorFirstKey* =
    Dss498ContributorFirstName & "." & Dss498OwnerActivity & "." &
      Dss498PointName

package dss498OwnerFirst:
  ## THE OWNING ACTIVITY IS DECLARED AND ENABLED FIRST. This is the
  ## arrangement #498 measured as broken: the member reaches
  ## `registrationMembers` and does NOT reach argv, so one artifact
  ## states two different member sets for one point.
  devEnv:
    activity owner():
      config:
        members: seq[string] = @["owner-default"]

      service svc:
        executable executableAtPath("/bin/sh")
        args "--members"
        args members
        identity stable "com.example.dss498.owner-first"
        scope project
        ## D-SS10 (§7.1): a service that `converge`s a point must
        ## declare an evaluable readiness probe. Never evaluated here --
        ## these cases lower a dev-env and read it -- so the path need
        ## not exist.
        readiness fileExists(".repro/dss498/ready")
        converge members

    activity contributor():
      contributeMembers("dss498OwnerFirst.owner.members",
        "dss498OwnerFirst", epSet, coAppend,
        l8ContributionMembers("from-the-other-activity"),
        "dss498_order_fixtures.nim", 90)

    enable owner
    enable contributor

package dss498ContributorFirst:
  ## THE CONTRIBUTING ACTIVITY IS DECLARED AND ENABLED FIRST -- the
  ## arrangement that already worked. Everything else is identical.
  devEnv:
    activity contributor():
      contributeMembers("dss498ContributorFirst.owner.members",
        "dss498ContributorFirst", epSet, coAppend,
        l8ContributionMembers("from-the-other-activity"),
        "dss498_order_fixtures.nim", 105)

    activity owner():
      config:
        members: seq[string] = @["owner-default"]

      service svc:
        executable executableAtPath("/bin/sh")
        args "--members"
        args members
        identity stable "com.example.dss498.contributor-first"
        scope project
        readiness fileExists(".repro/dss498/ready")
        converge members

    enable contributor
    enable owner

package dss498ExplicitOverride:
  ## THE CONTROL FOR THE ONE CASE THAT MUST **NOT** DEFER: the owner
  ## passes the point explicitly at its own `enable` site.
  ##
  ## An activity's `config:` key lowers to a parameter whose DEFAULT
  ## reads the fold, so `enable owner(members = @[...])` supplies the
  ## argument and the read of the fold never happens (§6's own
  ## paragraph: "an `enable` override that passes the argument
  ## explicitly still wins, because the default is then not evaluated at
  ## all"). Deferring such a value would let a later contribution
  ## OVERWRITE an explicit argument -- the owner overriding its own
  ## environment at its own enable site, silently undone. So this
  ## package's argv must carry the explicit value and nothing else, in
  ## the presence of exactly the contribution the two packages above
  ## receive.
  devEnv:
    activity owner():
      config:
        members: seq[string] = @["owner-default"]

      service svc:
        executable executableAtPath("/bin/sh")
        args "--members"
        args members
        identity stable "com.example.dss498.explicit-override"
        scope project
        readiness fileExists(".repro/dss498/ready")
        converge members

    activity contributor():
      contributeMembers("dss498ExplicitOverride.owner.members",
        "dss498ExplicitOverride", epSet, coAppend,
        l8ContributionMembers("from-the-other-activity"),
        "dss498_order_fixtures.nim", 160)

    enable owner(members = @["explicit-at-the-enable-site"])
    enable contributor
