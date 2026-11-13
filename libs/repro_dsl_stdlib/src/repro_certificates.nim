## ``repro_certificates`` — the test-certificate branch policy builder.
##
## Test-Certificates.md §"The policy declaration" (TC-9b). A policy says which
## named certificates (``certificate "<name>", <node>`` in ``repro.nim``) a
## commit to which branch needs. It is written once, in a shared library
## package, and each repository that adopts it imports it and enacts it:
##
## .. code-block:: nim
##
##   # policy/metacraft_certificate_policy.nim, in the shared package
##   import repro_certificates
##
##   const metacraftPolicy* = certificatePolicy "metacraft-default":
##     ciTrust advisory                 # default for the whole policy
##     rule "agents", "agents-to-dev-*":
##       gateMode required              # push: client pre-push and gateway
##       commitGate advisory            # pre-commit; omitted means = gateMode
##       requires "pre-commit", platforms = anyPlatform
##     rule "dev", "stable", "live":
##       gateMode required
##       requires "pre-commit", platforms = anyPlatform
##       requires "unit-suite", platforms = ["linux/amd64", "macos/arm64"]
##     rule detachedHead:
##       gateMode off
##     rule "**":
##       gateMode advisory
##       requires "unit-suite"          # the rule's `platforms`, else any
##
## The shared package's own ``repro.nim`` re-exports that module:
##
## .. code-block:: nim
##
##   import repro_project_dsl
##   import ./policy/metacraft_certificate_policy
##   export metacraft_certificate_policy
##   package metacraft_policy:           # checked out as ../metacraft_policy
##     ...
##
## and each adopting repository names the package in ``uses:``, which imports
## the package's ``repro.nim`` (and so the policy) and pins its revision in
## ``repro.lock``:
##
## .. code-block:: nim
##
##   import repro_project_dsl
##
##   package codetracer:
##     uses:
##       "metacraft_policy"
##     enactCertificatePolicy metacraftPolicy
##     build:
##       ...
##
## A bare ``import metacraft_certificate_policy`` of a module in the package's
## ``src/`` does not compile yet: a nested ``uses: "<pkg>"`` does not put that
## directory on the recipe compile path.
##
## The vocabulary, in full. Anything else inside the blocks is a compile
## error naming what is accepted:
##
## * policy level: ``ciTrust advisory|skip`` (default ``advisory``),
##   ``untrackedInputs readSet|strict`` (default ``readSet``), and the
##   defaults ``gateMode <mode>`` / ``commitGate <mode>`` that rules without
##   their own setting inherit;
## * ``rule <pattern>, ...:`` — branch patterns are git wildmatch over SHORT
##   branch names (``*`` within a path component, ``**`` across them), and
##   ``detachedHead`` names a detached ``HEAD``; rules are tried in order and
##   the first match wins;
## * inside a rule: ``gateMode off|advisory|required`` (push; default
##   ``off``), ``commitGate off|advisory|required`` (commit; default the
##   rule's ``gateMode``), ``platforms <list>`` (default platforms for the
##   rule's ``requires``) and ``requires "<name>"[, platforms = <list>]``;
## * a platform list is any ``openArray[string]`` expression, or
##   ``anyPlatform``: covered on at least one platform, by that platform's
##   certificates alone. ``anyPlatform`` cannot be mixed with concrete
##   platforms. A ``requires`` with no list, in a rule with none, means
##   ``anyPlatform``.
##
## A policy is DATA: the builder evaluates at compile time into a
## ``CertificatePolicy`` (no procs, no I/O, no host conditions), which is what
## lets ``repro.lock`` carry it as a declarative snapshot that gates read
## without compiling anything. Use ``const``; a ``let`` policy is refused by
## ``enactCertificatePolicy``.
##
## ``withRule`` derives a stricter policy from a shared one. It only adds: the
## new rule goes LAST, so it applies to branches no earlier rule matches. (A
## rule placed after a catch-all ``**`` never matches; a repository that needs
## to override a shared rule writes its own policy.)

import std/[macros, os, sequtils, strutils]
import repro_lock/certificate_policy

export certificate_policy

type
  CertificatePolicy* = BranchCertificatePolicy
    ## The policy value. The model, the snapshot renderer and the strict
    ## reader live in ``repro_lock/certificate_policy`` (exported here), where
    ## the lock writer and the gates use the same definitions.

const anyPlatform* = [AnyPlatformMarker]
  ## ``platforms = anyPlatform``: the certificate must be covered on at least
  ## one platform, by that platform's certificates alone.

type
  PendingRequirement = object
    certificate: string
    platforms: seq[string]
    platformsSet: bool

  PendingRule = object
    branches: seq[string]
    gateMode, commitGate: PolicyMode
    gateSet, commitSet: bool
    platforms: seq[string]
    platformsSet: bool
    requires: seq[PendingRequirement]
    label: string

  CertificatePolicyBuilder* = object
    ## What the ``certificatePolicy`` / ``withRule`` macros lower to. Settings
    ## are recorded with "was it given" flags and resolved by ``finish``, so
    ## a policy-level default written after a rule still applies to it.
    policy: BranchCertificatePolicy
    defaultGate, defaultCommit: PolicyMode
    defaultGateSet, defaultCommitSet: bool
    ciTrustSet, untrackedSet: bool
    pending: seq[PendingRule]

proc builderError(msg: string) {.noreturn.} =
  raise newException(CertificatePolicySnapshotError, msg)

proc initCertificatePolicyBuilder*(name, declaredIn: string):
    CertificatePolicyBuilder =
  result.policy = BranchCertificatePolicy(name: name, declaredIn: declaredIn,
    ciTrust: pctAdvisory, untrackedInputs: puiReadSet)

proc certificatePolicyBuilderFrom*(base: BranchCertificatePolicy):
    CertificatePolicyBuilder =
  ## A builder that starts from ``base``: its rules stay, resolved, in
  ## front of anything added.
  result.policy = base

proc setCiTrust*(b: var CertificatePolicyBuilder; value: PolicyCiTrust) =
  if b.ciTrustSet:
    builderError("certificate policy '" & b.policy.name &
      "': ciTrust is set twice")
  b.policy.ciTrust = value
  b.ciTrustSet = true

proc setUntrackedInputs*(b: var CertificatePolicyBuilder;
                         value: PolicyUntrackedInputs) =
  if b.untrackedSet:
    builderError("certificate policy '" & b.policy.name &
      "': untrackedInputs is set twice")
  b.policy.untrackedInputs = value
  b.untrackedSet = true

proc setDefaultGateMode*(b: var CertificatePolicyBuilder; mode: PolicyMode) =
  if b.defaultGateSet:
    builderError("certificate policy '" & b.policy.name &
      "': the default gateMode is set twice")
  b.defaultGate = mode
  b.defaultGateSet = true

proc setDefaultCommitGate*(b: var CertificatePolicyBuilder; mode: PolicyMode) =
  if b.defaultCommitSet:
    builderError("certificate policy '" & b.policy.name &
      "': the default commitGate is set twice")
  b.defaultCommit = mode
  b.defaultCommitSet = true

proc beginRule*(b: var CertificatePolicyBuilder; branches: openArray[string];
                label: string) =
  b.pending.add(PendingRule(branches: @branches, label: label))

proc requireRule(b: CertificatePolicyBuilder; what: string) =
  if b.pending.len == 0:
    builderError("certificate policy '" & b.policy.name & "': " & what &
      " outside a rule")

proc ruleGateMode*(b: var CertificatePolicyBuilder; mode: PolicyMode) =
  b.requireRule("gateMode")
  if b.pending[^1].gateSet:
    builderError(b.pending[^1].label & ": gateMode is set twice")
  b.pending[^1].gateMode = mode
  b.pending[^1].gateSet = true

proc ruleCommitGate*(b: var CertificatePolicyBuilder; mode: PolicyMode) =
  b.requireRule("commitGate")
  if b.pending[^1].commitSet:
    builderError(b.pending[^1].label & ": commitGate is set twice")
  b.pending[^1].commitGate = mode
  b.pending[^1].commitSet = true

proc rulePlatforms*(b: var CertificatePolicyBuilder;
                    platforms: openArray[string]) =
  b.requireRule("platforms")
  if b.pending[^1].platformsSet:
    builderError(b.pending[^1].label & ": platforms is set twice")
  b.pending[^1].platforms = @platforms
  b.pending[^1].platformsSet = true

proc ruleRequires*(b: var CertificatePolicyBuilder; certificate: string) =
  b.requireRule("requires")
  b.pending[^1].requires.add(PendingRequirement(certificate: certificate))

proc ruleRequires*(b: var CertificatePolicyBuilder; certificate: string;
                   platforms: openArray[string]) =
  b.requireRule("requires")
  b.pending[^1].requires.add(PendingRequirement(certificate: certificate,
    platforms: @platforms, platformsSet: true))

proc finish*(b: CertificatePolicyBuilder): BranchCertificatePolicy =
  ## Resolve the defaults and validate. Raises
  ## ``CertificatePolicySnapshotError`` (a compile error, in a ``const``).
  result = b.policy
  for pending in b.pending:
    var rule = PolicyRule(branches: pending.branches)
    rule.gateMode =
      if pending.gateSet: pending.gateMode
      elif b.defaultGateSet: b.defaultGate
      else: pmOff
    rule.commitGate =
      if pending.commitSet: pending.commitGate
      elif b.defaultCommitSet: b.defaultCommit
      else: rule.gateMode
    for req in pending.requires:
      rule.requires.add(PolicyRequirement(certificate: req.certificate,
        platforms:
          if req.platformsSet: req.platforms
          elif pending.platformsSet: pending.platforms
          else: @[AnyPlatformMarker]))
    result.rules.add(rule)
  validatePolicy(result)

# ---------------------------------------------------------------------------
# The macros
# ---------------------------------------------------------------------------

proc modeValue(node: NimNode; setting: string): NimNode =
  ## ``off`` / ``advisory`` / ``required`` as the enum value.
  if node.kind in {nnkIdent, nnkSym}:
    case node.strVal.normalize
    of "off": return bindSym"pmOff"
    of "advisory": return bindSym"pmAdvisory"
    of "required": return bindSym"pmRequired"
    else: discard
  error(setting & ": unknown mode '" & node.repr &
    "' (expected off, advisory, required)", node)

proc ciTrustValue(node: NimNode): NimNode =
  if node.kind in {nnkIdent, nnkSym}:
    case node.strVal.normalize
    of "advisory": return bindSym"pctAdvisory"
    of "skip": return bindSym"pctSkip"
    else: discard
  error("ciTrust: unknown value '" & node.repr &
    "' (expected advisory, skip)", node)

proc untrackedValue(node: NimNode): NimNode =
  if node.kind in {nnkIdent, nnkSym}:
    case node.strVal.normalize
    of "readset": return bindSym"puiReadSet"
    of "strict": return bindSym"puiStrict"
    else: discard
  error("untrackedInputs: unknown value '" & node.repr &
    "' (expected readSet, strict)", node)

proc singleArg(stmt: NimNode; setting: string): NimNode =
  if stmt.kind notin {nnkCommand, nnkCall} or stmt.len != 2:
    error(setting & " takes exactly one value", stmt)
  result = stmt[1]
  if result.kind == nnkStmtList and result.len == 1:
    result = result[0]

proc platformList(node: NimNode): NimNode =
  ## A platform list as a ``seq[string]`` expression.
  if node.kind in {nnkIdent, nnkSym} and node.eqIdent("anyPlatform"):
    return newCall(bindSym"@", newTree(nnkBracket,
      newLit(AnyPlatformMarker)))
  if node.kind == nnkBracket:
    return newCall(bindSym"@", node)
  newCall(bindSym"@", node)

proc patternValue(node: NimNode): NimNode =
  if node.kind in {nnkIdent, nnkSym} and node.eqIdent("detachedHead"):
    return newLit(DetachedHeadPattern)
  node

proc lowerRuleBody(builder, body: NimNode; label: string;
                   output: NimNode) =
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    if stmt.kind notin {nnkCommand, nnkCall} or stmt.len < 1 or
        stmt[0].kind notin {nnkIdent, nnkSym}:
      error("inside a rule: expected gateMode, commitGate, platforms or " &
        "requires; got '" & stmt.repr & "'", stmt)
    let head = stmt[0].strVal.normalize
    case head
    of "gatemode":
      output.add(newCall(bindSym"ruleGateMode", builder,
        modeValue(singleArg(stmt, "gateMode"), "gateMode")))
    of "commitgate":
      output.add(newCall(bindSym"ruleCommitGate", builder,
        modeValue(singleArg(stmt, "commitGate"), "commitGate")))
    of "platforms":
      output.add(newCall(bindSym"rulePlatforms", builder,
        platformList(singleArg(stmt, "platforms"))))
    of "requires":
      if stmt.len < 2 or stmt.len > 3:
        error("requires \"<certificate>\"[, platforms = <list>]", stmt)
      if stmt.len == 2:
        output.add(newCall(bindSym"ruleRequires", builder, stmt[1]))
      else:
        let named = stmt[2]
        if named.kind != nnkExprEqExpr or not named[0].eqIdent("platforms"):
          error("requires: the only option is `platforms = <list>`; got '" &
            named.repr & "'", named)
        output.add(newCall(bindSym"ruleRequires", builder, stmt[1],
          platformList(named[1])))
    else:
      error("inside a rule: unknown setting '" & stmt[0].strVal &
        "' (expected gateMode, commitGate, platforms, requires)", stmt)

proc lowerRule(builder, stmt: NimNode; output: NimNode) =
  ## ``rule <pattern>, ...: <body>``.
  if stmt.len < 3 or stmt[^1].kind != nnkStmtList:
    error("rule <branch pattern>, ...: <settings>", stmt)
  var patterns = newTree(nnkBracket)
  for i in 1 ..< stmt.len - 1:
    patterns.add(patternValue(stmt[i]))
  let label = "rule " & stmt[1 ..< stmt.len - 1].mapIt(it.repr).join(", ")
  let site = stmt.lineInfoObj
  output.add(newCall(bindSym"beginRule", builder, patterns,
    newLit(label & " (" & site.filename.extractFilename & ":" &
      $site.line & ")")))
  lowerRuleBody(builder, stmt[^1], label, output)

proc lowerPolicyBody(builder, body: NimNode; output: NimNode) =
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    if stmt.kind notin {nnkCommand, nnkCall} or stmt.len < 1 or
        stmt[0].kind notin {nnkIdent, nnkSym}:
      error("inside a certificatePolicy: expected rule, ciTrust, " &
        "untrackedInputs, gateMode or commitGate; got '" & stmt.repr & "'",
        stmt)
    case stmt[0].strVal.normalize
    of "rule":
      lowerRule(builder, stmt, output)
    of "citrust":
      output.add(newCall(bindSym"setCiTrust", builder,
        ciTrustValue(singleArg(stmt, "ciTrust"))))
    of "untrackedinputs":
      output.add(newCall(bindSym"setUntrackedInputs", builder,
        untrackedValue(singleArg(stmt, "untrackedInputs"))))
    of "gatemode":
      output.add(newCall(bindSym"setDefaultGateMode", builder,
        modeValue(singleArg(stmt, "gateMode"), "gateMode")))
    of "commitgate":
      output.add(newCall(bindSym"setDefaultCommitGate", builder,
        modeValue(singleArg(stmt, "commitGate"), "commitGate")))
    else:
      error("inside a certificatePolicy: unknown setting '" &
        stmt[0].strVal & "' (expected rule, ciTrust, untrackedInputs, " &
        "gateMode, commitGate)", stmt)

macro certificatePolicy*(name: string; body: untyped): CertificatePolicy =
  ## Build a ``CertificatePolicy`` (see the module documentation for the
  ## vocabulary). Evaluate it in a ``const``.
  let builder = genSym(nskVar, "reproPolicyBuilder")
  let output = newStmtList()
  output.add(newVarStmt(builder, newCall(bindSym"initCertificatePolicyBuilder",
    name, newLit(body.lineInfoObj.filename))))
  lowerPolicyBody(builder, body, output)
  output.add(newCall(bindSym"finish", builder))
  result = newBlockStmt(output)

macro withRule*(base: CertificatePolicy; args: varargs[untyped]):
    CertificatePolicy =
  ## ``basePolicy.withRule("<pattern>", ...): <settings>`` — ``base`` with one
  ## more rule, LAST. It never removes or relaxes a rule ``base`` has.
  if args.len < 2 or args[^1].kind != nnkStmtList:
    error("withRule(<branch pattern>, ...): <settings>", base)
  let builder = genSym(nskVar, "reproPolicyBuilder")
  let output = newStmtList()
  output.add(newVarStmt(builder,
    newCall(bindSym"certificatePolicyBuilderFrom", base)))
  var patterns = newTree(nnkBracket)
  var labels: seq[string]
  for i in 0 ..< args.len - 1:
    patterns.add(patternValue(args[i]))
    labels.add(args[i].repr)
  let label = "rule " & labels.join(", ")
  output.add(newCall(bindSym"beginRule", builder, patterns, newLit(label)))
  lowerRuleBody(builder, args[^1], label, output)
  output.add(newCall(bindSym"finish", builder))
  result = newBlockStmt(output)
