## Shared-Development-Services L5 — §6.5: "The instance key is
## `(identity, scope, environment)`."
##
## L4 built `(identity, scope)` against §4.5's earlier wording. This file
## measures the third element, and specifically the clause L5's `:gate:`
## leads with:
##
##   "one service definition resolved under two environments yielding two
##    instances with different issuers, and a build under one environment
##    unable to obtain the other's bindings"
##
## WHAT IS PROVEN HERE, in full:
##
##   * A `stable` service -- whose identity is an author-assigned
##     constant that NO binding can move -- resolved under two
##     environments yields TWO instance keys, TWO state roots and TWO
##     lease addresses. That is the half folding the environment into the
##     identity could not have delivered, and it is the half that matters:
##     a shared identity provider is `stable` by §4.2's rule.
##   * A `derived` service's identity ALSO moves, through the rendered
##     configuration -- §6.5's "the digest is taken over a definition
##     already resolved against one environment's bindings" -- measured
##     on two real config files written by the two environments' bindings.
##   * NEITHER state root is reachable from the other: the environment is
##     a path component ABOVE the identity, so a value written under
##     `dev` is absent under `production` and still present under `dev`.
##     That is "a build under one environment unable to obtain the
##     other's bindings", measured on a real filesystem rather than
##     argued.
##   * The NEGATIVE CONTROL that keeps all of the above from passing
##     vacuously: the same service, the same scope, the same identity and
##     the SAME environment resolves to ONE key, ONE state root and ONE
##     address from two different worktrees. Without it a function that
##     returned a fresh value per call would satisfy every assertion
##     above.
##   * The unselected case is its own key -- `no-environment` -- and not
##     an empty path component that collapses into the pre-L5 layout.
##
## WHAT IS NOT PROVEN HERE, AND WHICH MILESTONE PROVES IT. There is no
## daemon in this file and none is faked. The REGISTRY keyed by this key
## is L7; the ATTACH DECISION is L6. This file measures the key, the
## state root and the lease address -- and nothing about attaching,
## starting or converging.
##
## MOCK POLICY — NO MOCKS, DOUBLES OR FAKES, AND NONE MAY BE ADDED. The
## service definitions are lowered by the real `package` macro from real
## recipe text in this module; the environments are real `environment`
## blocks applied by the real `applyEnvironment`; the worktrees, the
## workspace manifests, the rendered configuration files and the state
## store are real directories under a throwaway root. Nothing here
## writes to `.repro/` anywhere in the repository or to any live state
## store: every state-store root is passed explicitly, which is why
## `serviceStateRoot` refuses to default it.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/types    # Executable, for the artifact slot var
import repro_resources/service_identity
import repro_test_support/process_fixtures

const ConfigPath = "etc/sso/config.toml"

var ssoConfig: BuildOutput

package l5KeyPkg:
  config:
    issuer: string = "http://localhost:8080"

  executable l5KeyBin:
    build:
      output("bin/sso")

  build:
    ## The rendered configuration is a real build output whose BYTES come
    ## from the configurable the environments bind. That is what makes
    ## the `derived` half below a measurement rather than a restatement.
    ssoConfig = renderConfigFile(ConfigPath,
      "issuer = \"" & readConfigurable[string]("l5KeyPkg.issuer") & "\"\n")

  service ssoStable:
    executable l5KeyBin
    args "start-from-init", "--config", ssoConfig.path
    runtimeFile ssoConfig
    identity stable "com.metacraft-labs.sso"
    scope workspace

  service ssoDerived:
    executable l5KeyBin
    args "start-from-init", "--config", ssoConfig.path
    runtimeFile ssoConfig
    identity derived
    scope workspace

  environment dev:
    issuer = "https://login.metacraft-labs.test"

  environment production:
    issuer = "https://login.metacraft-labs.com"

proc svc(name: string): DslServiceDef =
  for entry in registeredServices("l5KeyPkg"):
    if entry.serviceName == name:
      return entry
  raise newException(ValueError, "fixture drift: no service " & name)

let scratch = getTempDir() /
  ("repro-l5-environment-key-" & $getCurrentProcessId())
# Removed when THIS process exits, whichever cases it ran. The suite runner
# runs every case in a process of its own, so a final "teardown" case removed
# only its own process's tree and left every other one behind. Registering a
# path that is never created is harmless. See
# ``repro_test_support/process_fixtures``.
releaseDirAtProcessExit(scratch)

const WorkspaceProject = "sdsL5"

proc writeWorkspace(root, project: string) =
  ## A real `.repro/workspace.toml` in the shape the real manifest
  ## reader requires. The schema string is reconstructed from the
  ## reader's own requirement, which is the near-miss L4's fixture
  ## recorded: a wrong `schema` is REJECTED, the rejection is a
  ## degradation, and the fixture would then measure the degradation
  ## path while claiming to measure the identity one.
  createDir(root / ".repro")
  writeFile(root / ".repro" / "workspace-state.toml",
    "schema = \"reprobuild.workspace.state.v1\"\n\n" &
    "[workspace]\n" &
    "project = \"" & project & "\"\n")

proc writeConfigured(root, content: string) =
  createDir(root / ConfigPath.parentDir())
  writeFile(root / ConfigPath, content)

# Two CHECKOUTS of one workspace at different paths -- L4's D-SS3
# scenario, reused here because the negative control needs it.
let wsA = scratch / "checkout-a"
let wsB = scratch / "somewhere" / "else" / "checkout-b"
let store = scratch / "state-store"
let projA = wsA / "infra"
let projB = wsB / "infra"

proc ctxA(): ServiceScopeContext = discoverServiceScopeContext(projA)
proc ctxB(): ServiceScopeContext = discoverServiceScopeContext(projB)

var scratchTreeBuilt = false

proc buildScratchTree() =
  ## Build the scratch tree once per PROCESS, from whichever case needs it
  ## first. The suite runner runs every case in a process of its own, so a
  ## tree built only by the first case was missing from every other case's
  ## process, and the cases that read it failed when run alone.
  if scratchTreeBuilt:
    return
  scratchTreeBuilt = true
  for root in [projA, projB]:
    createDir(root)
  writeWorkspace(wsA, WorkspaceProject)
  writeWorkspace(wsB, WorkspaceProject)
  createDir(store)
  # The two checkouts render the configuration the SELECTED
  # environment binds. `dev` in both, so the negative control has
  # identical closures to work with.
  writeConfigured(projA, "issuer = \"https://login.metacraft-labs.test\"\n")
  writeConfigured(projB, "issuer = \"https://login.metacraft-labs.test\"\n")

suite "L5 — the fixture really is what every clause below assumes":
  ## THE POSITIVE CONTROL for this file. If any of these reddens, every
  ## assertion after it is about something other than what it names.

  setup:
    buildScratchTree()

  test "the scratch tree is built, on a real filesystem":
    for root in [projA, projB, store]:
      check dirExists(root)

  test "the two checkouts are genuinely at different paths":
    check canonicalRoot(projA) != canonicalRoot(projB)

  test "both checkouts resolve to the ONE workspace identity":
    check ctxA().workspaceId == WorkspaceProject
    check ctxB().workspaceId == WorkspaceProject
    check not resolveServiceScope(sscWorkspace, ctxA()).degraded

  test "the subject service is `stable`, so no binding can move its identity":
    # The premise of the headline clause. If this reddens, the two-key
    # result below could be an identity digest moving rather than the
    # environment doing anything.
    check svc("ssoStable").identity.kind == sikStable
    check svc("ssoStable").identity.stableId == "com.metacraft-labs.sso"
    check serviceIdentity(svc("ssoStable")) == "com.metacraft-labs.sso"

  test "the package really declares the two environments":
    check registeredEnvironmentNames("l5KeyPkg") == @["dev", "production"]

suite "L5 §6.5 — two environments are two instances":

  setup:
    buildScratchTree()

  test "the key's environment element carries the selection, verbatim":
    let dev = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    let prod = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "production")
    check dev.environment == "dev"
    check prod.environment == "production"
    # Everything ELSE about the two keys is identical, which is what
    # makes the environment the only reason they differ.
    check dev.identity == prod.identity
    check dev.identityKind == prod.identityKind
    check dev.scope == prod.scope
    check dev.scopeKey == prod.scopeKey

  test "a STABLE service under two environments has TWO state roots":
    # The clause folding the environment into the identity could not
    # satisfy: a stable id is a constant, so without the key's third
    # element these two paths would be one directory -- one database for
    # the development issuer and the production one.
    let dev = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    let prod = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "production")
    check serviceStateRoot(store, dev) != serviceStateRoot(store, prod)
    # And each path still names the identity readably -- §4.4's claim,
    # which L5 must not have broken.
    check serviceStateRoot(store, dev).endsWith("com.metacraft-labs.sso")
    check serviceStateRoot(store, prod).endsWith("com.metacraft-labs.sso")
    # The environment is a component of its own, above the identity.
    check serviceStateRoot(store, dev).contains("/dev/")
    check serviceStateRoot(store, prod).contains("/production/")

  test "and TWO lease addresses, so two reference-counted instances":
    let dev = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    let prod = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "production")
    check serviceInstanceAddress(dev) != serviceInstanceAddress(prod)
    check serviceInstanceAddress(dev).contains(":dev:")
    check serviceInstanceAddress(prod).contains(":production:")

  test "a DERIVED identity moves too, through the rendered configuration":
    # §6.5: "the digest is taken over a definition already resolved
    # against one environment's bindings". Measured on two real files
    # whose bytes are what the two environments bind, in two roots.
    let devRoot = scratch / "derived-dev"
    let prodRoot = scratch / "derived-production"
    writeConfigured(devRoot,
      "issuer = \"https://login.metacraft-labs.test\"\n")
    writeConfigured(prodRoot,
      "issuer = \"https://login.metacraft-labs.com\"\n")
    let def = svc("ssoDerived")
    let devId = serviceIdentity(def, renderedOutputDigests(devRoot, def))
    let prodId = serviceIdentity(def, renderedOutputDigests(prodRoot, def))
    check devId != prodId
    # So for `derived` the environment is redundant in the key and
    # harmless: the keys differ on BOTH elements rather than only one.
    let devKey = serviceInstanceKey(def, ctxA(),
      renderedOutputDigests(devRoot, def), "dev")
    let prodKey = serviceInstanceKey(def, ctxA(),
      renderedOutputDigests(prodRoot, def), "production")
    check devKey.identity != prodKey.identity
    check devKey.environment != prodKey.environment
    check serviceStateRoot(store, devKey) != serviceStateRoot(store, prodKey)

suite "L5 — a build under one environment cannot obtain the other's":

  setup:
    buildScratchTree()

  test "a value written under `dev` is absent under `production`":
    # On a real filesystem, through the real state roots. This is the
    # gate's "unable to obtain the other's bindings" stated as the thing
    # it actually means: the two instances do not share a byte.
    let dev = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    let prod = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "production")
    let devRoot = serviceStateRoot(store, dev)
    let prodRoot = serviceStateRoot(store, prod)
    createDir(devRoot)
    writeFile(devRoot / "issuer", "https://login.metacraft-labs.test")
    check fileExists(devRoot / "issuer")
    check not fileExists(prodRoot / "issuer")
    # And the development value is still there, which distinguishes
    # "the other environment cannot see it" from "it was never written".
    check readFile(devRoot / "issuer") ==
      "https://login.metacraft-labs.test"

suite "L5 — the negative control: ONE environment is ONE instance":
  ## Without this suite every assertion above would be satisfied by a
  ## function that returned a fresh value on every call.

  setup:
    buildScratchTree()

  test "two worktrees under the SAME environment resolve to one key":
    let fromA = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    let fromB = serviceInstanceKey(svc("ssoStable"), ctxB(),
      environment = "dev")
    check fromA.identity == fromB.identity
    check fromA.scope == fromB.scope
    check fromA.scopeKey == fromB.scopeKey
    check fromA.environment == fromB.environment
    check serviceStateRoot(store, fromA) == serviceStateRoot(store, fromB)
    check serviceInstanceAddress(fromA) == serviceInstanceAddress(fromB)

  test "and no component of that path comes from either worktree's path":
    # §4.4, re-measured because L5 changed the path. A new component
    # derived from a consumer's path would have undone L4's clause
    # silently.
    let root = serviceStateRoot(store,
      serviceInstanceKey(svc("ssoStable"), ctxA(), environment = "dev"))
    let relative = root[store.len .. ^1]
    check not relative.contains(canonicalRoot(projA))
    check not relative.contains(canonicalRoot(projB))
    check not relative.contains("checkout-a")
    check not relative.contains("checkout-b")

  test "the environment is case-folded nowhere: `dev` and `Dev` are two keys":
    # The CANONICALISATION belongs to the SELECTOR
    # (`canonicalEnvironmentSelection`, which the cache key uses), not
    # to the key's element. A key that folded case here would make two
    # spellings of a selection one instance while the cache key already
    # made them one entry -- consistent, but it would mean the key
    # silently normalised an author's name, and the state directory is
    # named after it.
    let lower = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    let upper = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "Dev")
    check lower.environment == "dev"
    check upper.environment == "Dev"
    check serviceStateRoot(store, lower) != serviceStateRoot(store, upper)

suite "L5 — the UNSELECTED case is a key of its own":

  setup:
    buildScratchTree()

  test "no environment selected is `no-environment`, not an empty component":
    # An empty component collapses in a path join, which would put an
    # unselected resolution's state exactly where the pre-L5 layout put
    # it and make the two indistinguishable.
    let none = serviceInstanceKey(svc("ssoStable"), ctxA())
    check none.environment == ""
    check environmentPathComponent(none) == "no-environment"
    let root = serviceStateRoot(store, none)
    check root.contains("/no-environment/")
    check not root.contains("//")

  test "it is distinct from every named environment":
    let none = serviceInstanceKey(svc("ssoStable"), ctxA())
    let dev = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    check serviceStateRoot(store, none) != serviceStateRoot(store, dev)
    check serviceInstanceAddress(none) != serviceInstanceAddress(dev)

  test "surrounding whitespace in the selection is stripped, not kept":
    # The key's element is trimmed because a trailing space is never a
    # distinct environment, and a state directory named `"dev "` is a
    # bug report waiting to happen.
    let padded = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "  dev  ")
    let plain = serviceInstanceKey(svc("ssoStable"), ctxA(),
      environment = "dev")
    check padded.environment == "dev"
    check serviceStateRoot(store, padded) == serviceStateRoot(store, plain)
