## Shared-Development-Services L4 — the INSTANCE IDENTITY and SCOPE
## model: which instance a consumer resolves to, and where that
## instance's state lives.
##
## This file carries the clauses that make the milestone, so it is worth
## being explicit about what it does and does not prove.
##
## WHAT IS PROVEN HERE, in full:
##
##   * §4.2 `derived` — two project roots whose service closures are
##     IDENTICAL resolve to one identity; two whose closures DIFFER
##     resolve to two. Measured over real rendered configuration files
##     written into two throwaway roots.
##   * §4.2 `stable` — a service reached from two different worktrees
##     resolves to ONE instance with ONE state root, and the NEGATIVE
##     CONTROL is the same scenario with `derived`, which resolves to
##     two. Neither half alone proves anything, so both are here and
##     each names the other.
##   * §4.2 — a `stable` service survives a change to its own definition
##     with its state directory intact: a value written before the change
##     is read back after it, from a real directory. The negative control
##     shows the `derived` service's value is NOT at the new state root
##     and IS still at the old one -- i.e. the state FORKED rather than
##     vanished, which is §4.2's "my test user is gone".
##   * §4.1 / D-SS3 — `workspace` scope resolves two checkouts of one
##     workspace at different paths to the same instance, and says what
##     it degrades to when the workspace identity is unavailable.
##   * §4.4 — the state root is addressed BY IDENTITY: asserted
##     positively (two worktrees agree) and negatively (no component of
##     the resulting path is derived from either consumer's path).
##
## WHAT IS NOT PROVEN HERE, AND WHICH MILESTONE PROVES IT. There is no
## daemon in this file and none is faked. §4.3's three-outcome ATTACH
## DECISION is L6; §4.5's instance REGISTRY and order-independent
## convergence are L7; §6.5's environment component of the key is L5.
## This file measures the key those milestones will key on, the state
## root they will address, and the lease address/holder they will
## reference-count -- and nothing about attaching, starting or converging.
##
## MOCK POLICY — NO MOCKS, DOUBLES OR FAKES ARE USED IN THIS FILE, AND
## NONE MAY BE ADDED. The service definitions are lowered by the real
## `package` macro from real recipe text in this module. The worktrees,
## the workspace manifests, the rendered configuration files and the
## state store are real directories under a throwaway root created by
## `createDir` and removed afterwards. Nothing in this file writes to
## `.repro/` anywhere in the repository or to any live state store: every
## state-store root is passed explicitly, which is why
## `serviceStateRoot` refuses to default it.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/types    # Executable, for the artifact slot var
import repro_resources/lease
import repro_resources/service_identity

# ---------------------------------------------------------------------------
# The service definitions, lowered by the real macro.
#
# One recipe, eight services. The pairs are built so exactly one thing
# varies: `ssoStable` / `ssoStableRedefined` differ only in an added
# argument (a redefinition), and `ssoDerived` / `ssoDerivedRedefined` are
# the same two bodies under `derived`.
#
# THE CONFIG IS A REAL RENDERED BUILD OUTPUT, not a path literal. That is
# load-bearing: `serviceDeclaredOutputPaths` collects the outputs a
# service references BY THEIR PRODUCING EDGE, so a `const` path string on
# argv contributes nothing to a derived identity -- correctly, since a
# literal names no output this graph produces. The first draft of this
# fixture passed `ConfigPath` as a literal and every
# `renderedOutputDigests` call returned an empty table, which made three
# cases below compare a digest against itself. They failed rather than
# passing vacuously, which is the only reason it was caught.
# ---------------------------------------------------------------------------

const ConfigPath = "etc/sso/config.toml"

var ssoConfig: BuildOutput

package l4KeyPkg:
  executable l4KeyBin:
    build:
      output("bin/sso")

  build:
    ssoConfig = renderConfigFile(ConfigPath,
      "issuer = \"http://localhost:8080\"\n")

  service ssoStable:
    executable l4KeyBin
    args "start-from-init", "--config", ssoConfig.path
    runtimeFile ssoConfig
    identity stable "com.metacraft-labs.sso"
    scope workspace

  service ssoStableRedefined:
    ## The SAME service after its author changed its definition. §4.2:
    ## "There is one instance per `(id, scope)`, and it survives
    ## redefinition."
    executable l4KeyBin
    args "start-from-init", "--config", ssoConfig.path, "--verbose"
    runtimeFile ssoConfig
    identity stable "com.metacraft-labs.sso"
    scope workspace

  service ssoDerived:
    executable l4KeyBin
    args "start-from-init", "--config", ssoConfig.path
    runtimeFile ssoConfig
    identity derived
    scope workspace

  service ssoDerivedRedefined:
    ## Byte-for-byte `ssoStableRedefined`'s body under `derived`. The
    ## negative control's other side.
    executable l4KeyBin
    args "start-from-init", "--config", ssoConfig.path, "--verbose"
    runtimeFile ssoConfig
    identity derived
    scope workspace

  service ssoPerProject:
    executable l4KeyBin
    args "start-from-init"
    identity stable "com.metacraft-labs.sso"
    scope project

  service ssoPerUser:
    executable l4KeyBin
    args "start-from-init"
    identity stable "com.metacraft-labs.sso"
    scope user

  service ssoPerMachine:
    executable l4KeyBin
    args "start-from-init"
    identity stable "com.metacraft-labs.sso"
    scope system

proc svc(name: string): DslServiceDef =
  for entry in registeredServices("l4KeyPkg"):
    if entry.serviceName == name:
      return entry
  raise newException(ValueError, "fixture drift: no service " & name)

proc derivedDescribed(): DslServiceDef =
  ## `ssoDerived` with the two COSMETIC fields changed and nothing else:
  ## a `description` and a different body source text. See the fixture
  ## suite's note for why this is an edited copy of a real record rather
  ## than a second `service` block.
  result = svc("ssoDerived")
  result.description = "the organisation's identity provider"
  result.bodyRepr = result.bodyRepr & "\n  ## a comment the author added"

# ---------------------------------------------------------------------------
# The throwaway filesystem. Created once for the file, removed at the end.
# ---------------------------------------------------------------------------

let scratch = getTempDir() /
  ("repro-l4-identity-" & $getCurrentProcessId())

const WorkspaceProject = "sdsL4"

proc writeWorkspace(root, project: string) =
  ## A real `.repro/workspace.toml`, in the shape the real manifest
  ## reader requires -- `schema = "reprobuild.workspace.local.v1"` and a
  ## non-empty `[workspace] project`. The first draft of this helper
  ## wrote `reprobuild.workspace.v1`, which `readWorkspaceLocal`
  ## correctly rejects, and the fixture then measured the DEGRADATION
  ## path while claiming to measure the identity one. Reconstructed from
  ## the reader's own requirement rather than from memory.
  createDir(root / ".repro")
  writeFile(root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\n" &
    "project = \"" & project & "\"\n")

proc writeConfigured(root, content: string) =
  ## A materialised project root with the service's rendered config in
  ## it, at the DECLARED relative path.
  createDir(root / ConfigPath.parentDir())
  writeFile(root / ConfigPath, content)

# wsA and wsB are two CHECKOUTS of the same workspace, at different
# paths, with the same declared workspace identity -- D-SS3's scenario.
let wsA = scratch / "checkout-a"
let wsB = scratch / "somewhere" / "else" / "checkout-b"
# wsNoId declares a workspace with no readable identity; lone has no
# workspace at all. Both exist to measure a DEGRADATION rather than to
# let one pass unnoticed.
let wsNoId = scratch / "checkout-no-id"
let lone = scratch / "lone-project"
let store = scratch / "state-store"

let projA = wsA / "infra"
let projASibling = wsA / "isonim-platform"
let projB = wsB / "infra"
let projNoId = wsNoId / "infra"

suite "L4 — the fixture really is what every clause below assumes":
  ## THE POSITIVE CONTROL for this file. If any of these reddens, every
  ## assertion after it is about something other than what it names.

  test "the scratch tree is built, on a real filesystem":
    for root in [projA, projASibling, projB, projNoId, lone]:
      createDir(root)
    writeWorkspace(wsA, WorkspaceProject)
    writeWorkspace(wsB, WorkspaceProject)
    createDir(wsNoId / ".repro")
    writeFile(wsNoId / ".repro" / "workspace.toml", "not valid toml ===\n")
    createDir(store)
    # Identical rendered configuration in the two checkouts; a different
    # one in the sibling project, which is what makes the `derived`
    # halves below differ for a measured reason.
    writeConfigured(projA, "issuer = \"http://localhost:8080\"\n")
    writeConfigured(projB, "issuer = \"http://localhost:8080\"\n")
    writeConfigured(projASibling, "issuer = \"http://localhost:9999\"\n")
    writeConfigured(lone, "issuer = \"http://localhost:8080\"\n")
    for root in [projA, projASibling, projB, projNoId, lone, store]:
      check dirExists(root)
    check fileExists(projA / ConfigPath)

  test "the two checkouts are genuinely at different paths":
    check canonicalRoot(projA) != canonicalRoot(projB)
    check canonicalRoot(wsA) != canonicalRoot(wsB)

  test "the redefinition pairs really do differ in their definitions":
    check svc("ssoStable").args != svc("ssoStableRedefined").args
    check svc("ssoDerived").args != svc("ssoDerivedRedefined").args

  test "and the stable pair really does declare ONE id":
    check svc("ssoStable").identity.kind == sikStable
    check svc("ssoStable").identity.stableId ==
      svc("ssoStableRedefined").identity.stableId

  test "the cosmetic pair differs only in cosmetic fields":
    # Built by editing a COPY of a real lowered record rather than by
    # declaring a second service, and the reason is a property of the
    # feature: two services of one package cannot share a name (L3's
    # export check refuses it, correctly), and the service NAME is in the
    # derived digest -- see `derivedDescribed` below. A differently-named
    # twin would therefore differ for a reason that has nothing to do
    # with what this pair measures. The subject under test is the digest
    # function's field selection, and the record it is given is a real
    # one with two fields changed.
    let described = derivedDescribed()
    check described.description.len > 0
    check svc("ssoDerived").description == ""
    check described.bodyRepr != svc("ssoDerived").bodyRepr
    check described.serviceName == svc("ssoDerived").serviceName
    check described.args == svc("ssoDerived").args
    check described.executableTyped == svc("ssoDerived").executableTyped

suite "L4 §4.2 — a derived identity is a digest of the definition":

  test "identical closures at two roots give ONE identity":
    # §4.2: "Two worktrees that build the same closure share one
    # instance." The two roots are different directories with
    # byte-identical rendered configuration.
    let def = svc("ssoDerived")
    check derivedServiceIdentity(def, renderedOutputDigests(projA, def)) ==
      derivedServiceIdentity(def, renderedOutputDigests(projB, def))

  test "a DIFFERENT rendered configuration gives a different identity":
    # §4.2: "A service with a database … gets a *new, empty* instance the
    # moment any change reaches its rendered configuration." That is the
    # documented hazard of `derived`, so it has to be real.
    let def = svc("ssoDerived")
    check derivedServiceIdentity(def, renderedOutputDigests(projA, def)) !=
      derivedServiceIdentity(def,
        renderedOutputDigests(projASibling, def))

  test "a different ARGUMENT gives a different identity":
    let digests = renderedOutputDigests(projA, svc("ssoDerived"))
    check derivedServiceIdentity(svc("ssoDerived"), digests) !=
      derivedServiceIdentity(svc("ssoDerivedRedefined"), digests)

  test "an UNRENDERED config is not the same as an empty one":
    # The marker, not a skip: without it "the config has not been
    # rendered yet" and "the config rendered to zero bytes" would be one
    # identity, and a consumer resolving before the build would attach to
    # the instance of a service it has not built.
    let def = svc("ssoDerived")
    let emptyRoot = scratch / "rendered-empty"
    writeConfigured(emptyRoot, "")
    let absentRoot = scratch / "rendered-absent"
    createDir(absentRoot)
    check not fileExists(absentRoot / ConfigPath)
    check derivedServiceIdentity(def, renderedOutputDigests(emptyRoot, def)) !=
      derivedServiceIdentity(def, renderedOutputDigests(absentRoot, def))

  test "a cosmetic change does NOT give a different identity":
    # The pair that keeps `derived` from being a fork-on-anything hammer,
    # and the reason `description` and `bodyRepr` are excluded by name.
    # Its control is in the fixture suite above: the two records really
    # do differ in both fields.
    let digests = renderedOutputDigests(projA, svc("ssoDerived"))
    check derivedServiceIdentity(svc("ssoDerived"), digests) ==
      derivedServiceIdentity(derivedDescribed(), digests)

  test "but RENAMING the service does":
    # The service name IS in the digest, although §4.2's list of inputs
    # ("the executable, the rendered configuration outputs, the
    # arguments") does not mention it. Two services of one package with
    # byte-identical definitions are two services the author wrote on
    # purpose, and one instance between them would be wrong. Asserted so
    # the inclusion is a decision and not an accident.
    var renamed = svc("ssoDerived")
    renamed.serviceName = "ssoRenamed"
    let digests = renderedOutputDigests(projA, svc("ssoDerived"))
    check derivedServiceIdentity(svc("ssoDerived"), digests) !=
      derivedServiceIdentity(renamed, digests)

  test "and so does moving it to another package":
    var moved = svc("ssoDerived")
    moved.packageName = "someOtherPackage"
    let digests = renderedOutputDigests(projA, svc("ssoDerived"))
    check derivedServiceIdentity(svc("ssoDerived"), digests) !=
      derivedServiceIdentity(moved, digests)

  test "identical closures at two roots give ONE INSTANCE KEY":
    # The clause as the gate words it -- "two project roots whose
    # `derived` service closures are identical sharing one instance" --
    # rather than only as an identity equality. The two roots are two
    # checkouts of one workspace, so the scope halves agree and the key
    # is whole.
    let def = svc("ssoDerived")
    let keyA = serviceInstanceKey(def, discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, def))
    let keyB = serviceInstanceKey(def, discoverServiceScopeContext(projB),
      renderedOutputDigests(projB, def))
    check keyA == keyB
    check serviceStateRoot(store, keyA) == serviceStateRoot(store, keyB)

  test "and two whose closures DIFFER give two":
    # The other half. `projASibling` renders a different issuer, and it
    # is in the SAME workspace as `projA`, so the scope halves agree and
    # the only thing that can separate the two keys is the closure.
    let def = svc("ssoDerived")
    let keyA = serviceInstanceKey(def, discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, def))
    let keyC = serviceInstanceKey(def,
      discoverServiceScopeContext(projASibling),
      renderedOutputDigests(projASibling, def))
    check keyA.scopeKey == keyC.scopeKey
    check keyA.identity != keyC.identity
    check keyA != keyC
    check serviceStateRoot(store, keyA) != serviceStateRoot(store, keyC)

  test "the identity does not contain either root's path":
    # Path-independence is the property the first case rests on, and
    # equality alone would also hold if both sides were constant.
    let def = svc("ssoDerived")
    let identity = derivedServiceIdentity(def,
      renderedOutputDigests(projA, def))
    check identity.len == 64
    check not identity.contains("checkout")
    check not identity.contains(scratch.extractFilename())

suite "L4 §4.2 — a stable identity is the author's id, untouched":

  test "it is returned verbatim: not hashed, not qualified":
    check serviceIdentity(svc("ssoStable")) == "com.metacraft-labs.sso"

  test "and it does not move when the definition changes":
    check serviceIdentity(svc("ssoStable")) ==
      serviceIdentity(svc("ssoStableRedefined"))

  test "nor when the rendered configuration changes":
    # The output digests are supplied and deliberately ignored for a
    # stable identity. Passing two different tables is the measurement.
    let a = renderedOutputDigests(projA, svc("ssoStable"))
    let b = renderedOutputDigests(projASibling, svc("ssoStable"))
    check a != b
    check serviceIdentity(svc("ssoStable"), a) ==
      serviceIdentity(svc("ssoStable"), b)

suite "L4 §4.1 — scope resolves to WHICH project / workspace / user":

  test "`workspace` scope reads the declared workspace identity":
    let ctx = discoverServiceScopeContext(projA)
    check ctx.workspaceId == WorkspaceProject
    check canonicalRoot(ctx.workspaceRoot) == canonicalRoot(wsA)
    let resolved = resolveServiceScope(sscWorkspace, ctx)
    check resolved.scope == sscWorkspace
    check resolved.key == WorkspaceProject
    check not resolved.degraded

  test "D-SS3: two CHECKOUTS of one workspace resolve to one key":
    # The clause, and its control: the two workspace roots are different
    # directories, so an implementation that keyed on the path would fail
    # here rather than pass by accident.
    let a = discoverServiceScopeContext(projA)
    let b = discoverServiceScopeContext(projB)
    check canonicalRoot(a.workspaceRoot) != canonicalRoot(b.workspaceRoot)
    check resolveServiceScope(sscWorkspace, a).key ==
      resolveServiceScope(sscWorkspace, b).key

  test "two SIBLING projects of one workspace resolve to one key too":
    check resolveServiceScope(sscWorkspace,
        discoverServiceScopeContext(projA)).key ==
      resolveServiceScope(sscWorkspace,
        discoverServiceScopeContext(projASibling)).key

  test "`project` scope keeps the two roots apart, which is its job":
    # Not a defect: §4.1 defines `project` as "one instance per project
    # root". The orthogonality §4 insists on means the two clauses above
    # and this one are all correct at the same time.
    check resolveServiceScope(sscProject,
        discoverServiceScopeContext(projA)).key !=
      resolveServiceScope(sscProject,
        discoverServiceScopeContext(projB)).key

  test "`user` scope is one key regardless of which root asked":
    let a = resolveServiceScope(sscUser, discoverServiceScopeContext(projA))
    let b = resolveServiceScope(sscUser, discoverServiceScopeContext(projB))
    check a.key == b.key
    check a.key == currentOsUser()
    check not a.degraded

  test "`system` scope is one key for the machine":
    let a = resolveServiceScope(sscSystem,
      discoverServiceScopeContext(projA))
    check a.key == SystemScopeKey
    check not a.degraded

  test "only `system` routes to the system daemon":
    # §4.1's routing, over the lease scope Ephemeral-State-Leases.md §4.1
    # already resolved. Derived from the enum so a new scope cannot be
    # added without a decision about where it routes.
    for scope in ServiceScope:
      check routesToSystemDaemon(scope) == (scope == sscSystem)

suite "L4 §4.1 — a scope that cannot be honoured DEGRADES, and says so":

  test "no readable workspace identity: the root path, reported":
    let ctx = discoverServiceScopeContext(projNoId)
    check canonicalRoot(ctx.workspaceRoot) == canonicalRoot(wsNoId)
    check ctx.workspaceId == ""
    let resolved = resolveServiceScope(sscWorkspace, ctx)
    check resolved.scope == sscWorkspace
    check resolved.key == canonicalRoot(wsNoId)
    check resolved.degraded
    check resolved.degradation.contains("fell back to the workspace ROOT")
    check resolved.degradation.contains("D-SS3")
    # And WHY, in the manifest reader's own words. Without this the
    # message is indistinguishable between "the file is malformed" and
    # "the file declares no project", which are different repairs.
    check ctx.workspaceIdUnreadable.len > 0
    check resolved.degradation.contains(ctx.workspaceIdUnreadable)

  test "no workspace at all: `project`, reported as such":
    let ctx = discoverServiceScopeContext(lone)
    check ctx.workspaceRoot == ""
    let resolved = resolveServiceScope(sscWorkspace, ctx)
    check resolved.declaredScope == sscWorkspace
    check resolved.scope == sscProject
    check resolved.key == canonicalRoot(lone)
    check resolved.degraded
    check resolved.degradation.contains("DEGRADED TO `scope project`")
    check resolved.degradation.contains("not shared beyond this project")

  test "no user name: `project`, and narrowing is the safe direction":
    # Constructed rather than produced by unsetting the environment,
    # which would race every other test in this binary. The context is
    # the resolution's only input, which is why it is a value.
    var ctx = discoverServiceScopeContext(projA)
    ctx.user = ""
    let resolved = resolveServiceScope(sscUser, ctx)
    check resolved.scope == sscProject
    check resolved.degraded
    check resolved.degradation.contains("DEGRADED TO `scope project`")

  test "a degradation reaches the instance KEY, not just the resolution":
    # A caller holding only the key must still be able to report it.
    var def = svc("ssoStable")
    def.scope = sscWorkspace
    let key = serviceInstanceKey(def, discoverServiceScopeContext(lone))
    check key.scope == sscProject
    check degradationReport(key).len > 0

  test "an undegraded key reports nothing":
    let key = serviceInstanceKey(svc("ssoStable"),
      discoverServiceScopeContext(projA))
    check degradationReport(key) == ""

suite "L4 — THE PAIR: one stable instance across two worktrees, two derived":
  ## The heart of the milestone. §4.2 / the L4 gate: "a `stable` service
  ## reached from two different worktrees resolving to ONE instance with
  ## ONE state root -- the negative control being the same scenario with
  ## `derived`, which must produce two." Neither half alone proves
  ## anything, so each of the four tests below names its partner.
  ##
  ## The two worktrees carry DIFFERENT definitions (`ssoStable` vs
  ## `ssoStableRedefined`, and the matching `derived` pair), because that
  ## is the realistic case: two checkouts at two revisions. With
  ## identical definitions even `derived` would resolve to one instance,
  ## and the negative control would prove nothing.

  test "STABLE: two worktrees, one instance key":
    let defA = svc("ssoStable")
    let defB = svc("ssoStableRedefined")
    let keyA = serviceInstanceKey(defA,
      discoverServiceScopeContext(projA), renderedOutputDigests(projA, defA))
    let keyB = serviceInstanceKey(defB,
      discoverServiceScopeContext(projB), renderedOutputDigests(projB, defB))
    check keyA.identity == keyB.identity
    check keyA.scope == keyB.scope
    check keyA.scopeKey == keyB.scopeKey
    check keyA == keyB

  test "STABLE: two worktrees, one state root":
    let defA = svc("ssoStable")
    let defB = svc("ssoStableRedefined")
    let rootA = serviceStateRoot(store, serviceInstanceKey(defA,
      discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, defA)))
    let rootB = serviceStateRoot(store, serviceInstanceKey(defB,
      discoverServiceScopeContext(projB),
      renderedOutputDigests(projB, defB)))
    check rootA == rootB

  test "DERIVED: the same scenario gives TWO keys (negative control)":
    # Without this, "STABLE gives one key" would also pass for an
    # implementation that gave one key to everything.
    let defA = svc("ssoDerived")
    let defB = svc("ssoDerivedRedefined")
    let keyA = serviceInstanceKey(defA,
      discoverServiceScopeContext(projA), renderedOutputDigests(projA, defA))
    let keyB = serviceInstanceKey(defB,
      discoverServiceScopeContext(projB), renderedOutputDigests(projB, defB))
    check keyA.identity != keyB.identity
    # And the SCOPE halves still agree: the two instances exist because
    # the identities differ, not because the scope resolution split.
    check keyA.scopeKey == keyB.scopeKey

  test "DERIVED: the same scenario gives TWO state roots":
    let defA = svc("ssoDerived")
    let defB = svc("ssoDerivedRedefined")
    check serviceStateRoot(store, serviceInstanceKey(defA,
        discoverServiceScopeContext(projA),
        renderedOutputDigests(projA, defA))) !=
      serviceStateRoot(store, serviceInstanceKey(defB,
        discoverServiceScopeContext(projB),
        renderedOutputDigests(projB, defB)))

suite "L4 §4.4 — the state root is addressed by identity, never by path":

  test "a stable service's state path NAMES its identity":
    # §4.4 is the claim; this is what makes it legible rather than
    # merely true. The segment encoder is injective and invertible, and a
    # reverse-DNS id is filename-shaped already, so it encodes to itself.
    let root = serviceStateRoot(store, serviceInstanceKey(svc("ssoStable"),
      discoverServiceScopeContext(projA)))
    check root.extractFilename() == "com.metacraft-labs.sso"
    check root.startsWith(store)
    # `DirSep` rather than a literal '/': `serviceStateRoot` joins with
    # `os./`, which is a backslash on Windows, and this repository builds
    # there. A literal would have made these two lines a known-broken
    # assertion on a platform nobody runs this binary on yet.
    check root.contains(DirSep & ServiceStateDirName & DirSep)
    check root.contains(DirSep & "workspace" & DirSep)

  test "and no component of it comes from either consumer's path":
    # The negative half. Equality between two roots would also hold if
    # both happened to embed the same path.
    let root = serviceStateRoot(store, serviceInstanceKey(svc("ssoStable"),
      discoverServiceScopeContext(projA)))
    let tail = root[store.len .. ^1]
    for fragment in ["checkout-a", "checkout-b", "infra",
                     "isonim-platform", "somewhere", "else"]:
      check not tail.contains(fragment)

  test "`user` and `system` scope embed no path either":
    for name in ["ssoPerUser", "ssoPerMachine"]:
      let root = serviceStateRoot(store, serviceInstanceKey(svc(name),
        discoverServiceScopeContext(projA)))
      let tail = root[store.len .. ^1]
      check not tail.contains("checkout-a")
      check not tail.contains("infra")

  test "the four scopes do not collide with one another":
    # One id, four scopes, four distinct state roots -- the instance key
    # is the PAIR, so a service declared at two scopes is two instances.
    var roots: seq[string] = @[]
    for name in ["ssoPerProject", "ssoStable", "ssoPerUser",
                 "ssoPerMachine"]:
      let root = serviceStateRoot(store, serviceInstanceKey(svc(name),
        discoverServiceScopeContext(projA)))
      check root notin roots
      roots.add(root)
    check roots.len == int(high(ServiceScope)) + 1

  test "the store root is never defaulted":
    # A test that forgot to pass a throwaway store would otherwise write
    # into the developer's live state. The refusal is the guardrail.
    expect ServiceIdentityError:
      discard serviceStateRoot("", serviceInstanceKey(svc("ssoStable"),
        discoverServiceScopeContext(projA)))

suite "L4 §4.2 — a stable service's STATE survives a redefinition":
  ## Not "the two paths are equal" -- a real value written into a real
  ## directory before the change and read back from the directory the
  ## CHANGED definition resolves to.

  test "a value written before the change is readable after it":
    let defBefore = svc("ssoStable")
    let defAfter = svc("ssoStableRedefined")
    let before = serviceStateRoot(store, serviceInstanceKey(defBefore,
      discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, defBefore)))
    createDir(before)
    writeFile(before / "users.db", "test-user\n")
    let after = serviceStateRoot(store, serviceInstanceKey(defAfter,
      discoverServiceScopeContext(projB),
      renderedOutputDigests(projB, defAfter)))
    check fileExists(after / "users.db")
    check readFile(after / "users.db") == "test-user\n"

  test "DERIVED: the value is NOT there, and the state FORKED":
    # The negative control, and it is deliberately stronger than "the
    # file is absent": absent would also be true if the state root had
    # simply moved somewhere unusable. §4.2's symptom is "my test user is
    # gone", which is a FORK -- the old directory still holds it.
    let defBefore = svc("ssoDerived")
    let defAfter = svc("ssoDerivedRedefined")
    let before = serviceStateRoot(store, serviceInstanceKey(defBefore,
      discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, defBefore)))
    createDir(before)
    writeFile(before / "users.db", "test-user\n")
    let after = serviceStateRoot(store, serviceInstanceKey(defAfter,
      discoverServiceScopeContext(projB),
      renderedOutputDigests(projB, defAfter)))
    check after != before
    check not fileExists(after / "users.db")
    check readFile(before / "users.db") == "test-user\n"

suite "L4 §4.5 — the key reaches the existing lease lane":
  ## §4.5: "Lifetime is the reference-counted lease that
  ## Ephemeral-State-Leases.md already specifies, so `repro down` in one
  ## project drops a reference rather than stopping an instance another
  ## project is using." That machinery exists; what L4 owes it is an
  ## ADDRESS and a HOLDER ID. The daemon that holds the registry is L7,
  ## and nothing here starts, attaches to or converges on anything.

  test "two consumers take leases on ONE address with TWO holder ids":
    let defA = svc("ssoStable")
    let defB = svc("ssoStableRedefined")
    let addressA = serviceInstanceAddress(serviceInstanceKey(defA,
      discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, defA)))
    let addressB = serviceInstanceAddress(serviceInstanceKey(defB,
      discoverServiceScopeContext(projB),
      renderedOutputDigests(projB, defB)))
    check addressA == addressB
    let holderA = leased(addressA, serviceLeaseHolderId(projA), keep())
    let holderB = leased(addressB, serviceLeaseHolderId(projB), keep())
    check holderA.address == holderB.address
    check holderA.consumerId != holderB.consumerId

  test "the address names the identity and the scope, readably":
    let address = serviceInstanceAddress(serviceInstanceKey(
      svc("ssoStable"), discoverServiceScopeContext(projA)))
    check address.startsWith("service:workspace:")
    check address.endsWith(":stable:com.metacraft-labs.sso")

  test "a derived instance's address says `derived`":
    let def = svc("ssoDerived")
    let address = serviceInstanceAddress(serviceInstanceKey(def,
      discoverServiceScopeContext(projA),
      renderedOutputDigests(projA, def)))
    check address.contains(":derived:")

  test "a holder id needs the consuming project's root":
    expect ServiceIdentityError:
      discard serviceLeaseHolderId("")

suite "L4 — teardown":

  test "the throwaway tree is removed":
    # Explicit rather than a `defer`: this binary's whole scratch tree is
    # under the system temp directory and leaving it behind across runs
    # would make the `dirExists` controls above pass for the wrong
    # reason.
    removeDir(scratch)
    check not dirExists(scratch)
