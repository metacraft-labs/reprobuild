## The shared test-certificate branch policy as DATA: its model, its
## ``[certificate_policy]`` snapshot in ``repro.lock``, the strict reader every
## gate shares, and branch matching.
##
## Test-Certificates.md §"Named certificates and the shared branch policy"
## (TC-9b). A policy is a Nim value written in a shared library package and
## enacted by a repository's ``repro.nim``. No gate compiles Nim, so the
## evaluated policy is recorded in ``repro.lock`` as a declarative table and
## every gate reads it out of the content it judges:
##
## .. code-block:: toml
##
##   [certificate_policy]
##   schema = "reprobuild.certificate-policy.v1"
##   name = "metacraft-default"
##   package = "metacraft-certificate-policy"
##   ci_trust = "advisory"
##   untracked_inputs = "read-set"
##
##   [[certificate_policy.rule]]
##   branches = ["agents", "agents-to-dev-*"]
##   gate_mode = "required"
##   commit_gate = "advisory"
##   requires = [{ certificate = "pre-commit", platforms = ["*"] }]
##
## This module is deliberately pure (``std`` only, no I/O, no git): the DSL
## builds the model at compile time, the lock writer renders it, and the gates
## parse and match it. Keeping all four in one file is what stops them from
## disagreeing about the format.
##
## The reader is STRICT ("the format is checked loudly"): an unknown key, an
## unknown mode, a malformed value, or ``"*"`` mixed with concrete platforms
## raises ``CertificatePolicySnapshotError``. None of them ever resolves to
## ``off``.

import std/[os, strutils]

const
  CertificatePolicySchemaV1* = "reprobuild.certificate-policy.v1"
    ## The ``schema`` value of the snapshot table.
  CertificatePolicyTable* = "certificate_policy"
    ## The snapshot's table name in ``repro.lock``.
  CertificatePolicyRuleTable* = "certificate_policy.rule"
    ## The array-of-tables name of the snapshot's rules.
  DetachedHeadPattern* = "(detached)"
    ## How a ``rule detachedHead:`` is spelled in ``branches``. Not a valid
    ## git branch name (git refuses names containing ``(``), so it cannot
    ## collide with a real branch.
  AnyPlatformMarker* = "*"
    ## ``platforms = anyPlatform`` in the snapshot: the name must be covered
    ## on at least one platform, by that platform's certificates alone.

type
  CertificatePolicySnapshotError* = object of ValueError
    ## A structural error in a policy or its snapshot. Gates must refuse on
    ## it; it never means "no requirement".

  PolicyMode* = enum
    ## ``gate_mode`` (push) and ``commit_gate`` (commit).
    pmOff = "off"
    pmAdvisory = "advisory"
    pmRequired = "required"

  PolicyCiTrust* = enum
    ## ``ci_trust``: what ``repro ci plan`` does with a certified target.
    pctAdvisory = "advisory"
    pctSkip = "skip"

  PolicyUntrackedInputs* = enum
    ## ``untracked_inputs`` (Test-Certificates TC-8d): what issuance does
    ## about untracked, non-ignored files.
    puiReadSet = "read-set"
    puiStrict = "strict"

  PolicyRequirement* = object
    ## ``requires "<certificate>", platforms = [...]``.
    certificate*: string
    platforms*: seq[string]
      ## Each listed platform must be covered, or ``@["*"]``: some platform
      ## must cover the name on its own.

  PolicyRule* = object
    ## One ``rule <patterns>:`` of a policy, with its modes RESOLVED (policy
    ## defaults applied, ``commit_gate`` defaulted to ``gate_mode``).
    branches*: seq[string]
      ## Branch patterns (git wildmatch over short branch names), or
      ## ``DetachedHeadPattern``.
    gateMode*: PolicyMode
    commitGate*: PolicyMode
    requires*: seq[PolicyRequirement]

  BranchCertificatePolicy* = object
    ## A test-certificate branch policy. The DSL's ``certificatePolicy``
    ## builder produces one at compile time (``repro_certificates`` exposes it
    ## as ``CertificatePolicy``); the lock writer renders it; the strict
    ## reader parses it back.
    ##
    ## It is data and nothing else: no procs, no I/O, no host conditions,
    ## which is what lets a gate read it without running Nim.
    name*: string
    package*: string
      ## The package that exports the policy, named as its ``repro.lock``
      ## dependency entry, whose revision is the policy's pin. Filled in by
      ## the lock writer (the DSL does not know the lock's names); empty in
      ## a policy value the DSL built.
    ciTrust*: PolicyCiTrust
    untrackedInputs*: PolicyUntrackedInputs
    rules*: seq[PolicyRule]
    declaredIn*: string
      ## The source file of the ``certificatePolicy`` call, so the lock writer
      ## can tell which locked package holds it. Absolute as the builder
      ## records it; relative to the enacting recipe's directory once enacted
      ## (``withDeclaredInRelativeTo``). Never rendered.

  BranchRefKind* = enum
    ## What a gate is judging.
    brkBranch    ## a branch, by its short name
    brkDetached  ## a detached ``HEAD`` (commit time only)
    brkOther     ## a tag or any other ref: never matches a rule

  BranchRef* = object
    kind*: BranchRefKind
    name*: string
      ## The short branch name for ``brkBranch``, the full ref otherwise.

  PolicyMatch* = object
    ## The rule that applies to a ``BranchRef``, if any.
    matched*: bool
    ruleIndex*: int          ## 0-based index into ``rules``; -1 when none
    pattern*: string         ## the pattern that matched
    rule*: PolicyRule
    reason*: string
      ## Why no rule applies (``matched == false``), in words a gate can print.

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

proc policyError(msg: string) {.noreturn.} =
  raise newException(CertificatePolicySnapshotError, msg)

proc validatePlatforms(platforms: openArray[string]; where: string) =
  if platforms.len == 0:
    policyError(where & ": platforms must not be empty (use anyPlatform, " &
      "\"*\" in the snapshot, for any one platform)")
  var seen: seq[string] = @[]
  for p in platforms:
    if p.len == 0:
      policyError(where & ": a platform must not be empty")
    for ch in p:
      if ch in Whitespace or ch in {'"', '\\', ',', '[', ']', '{', '}', '='}:
        policyError(where & ": platform '" & p & "' contains '" & $ch & "'")
    if p in seen:
      policyError(where & ": platform '" & p & "' is listed twice")
    seen.add(p)
  if AnyPlatformMarker in platforms and platforms.len != 1:
    policyError(where & ": \"*\" (anyPlatform) cannot be mixed with " &
      "concrete platforms " & $platforms)

proc validatePattern(pattern: string; where: string) =
  if pattern.len == 0:
    policyError(where & ": a branch pattern must not be empty")
  if pattern == DetachedHeadPattern:
    return
  if pattern.startsWith("refs/"):
    policyError(where & ": branch pattern '" & pattern & "' names a full " &
      "ref; patterns match SHORT branch names (write '" &
      pattern.replace("refs/heads/", "") & "')")
  for ch in pattern:
    if ch in Whitespace or ch == '"' or ord(ch) < 0x20:
      policyError(where & ": branch pattern '" & pattern &
        "' contains whitespace, a control character or a quote")

proc validatePolicy*(policy: BranchCertificatePolicy) =
  ## Raise ``CertificatePolicySnapshotError`` on the first structural error.
  ## The DSL calls it at compile time; the strict reader calls it on what it
  ## parsed, so a policy that cannot be written cannot be read either.
  if policy.name.len == 0:
    policyError("a certificate policy needs a name")
  for i, rule in policy.rules:
    let where = "rule " & $(i + 1) & " of certificate policy '" &
      policy.name & "'"
    if rule.branches.len == 0:
      policyError(where & ": a rule needs at least one branch pattern")
    var seenPatterns: seq[string] = @[]
    for pattern in rule.branches:
      validatePattern(pattern, where)
      if pattern in seenPatterns:
        policyError(where & ": branch pattern '" & pattern &
          "' is listed twice")
      seenPatterns.add(pattern)
    var seenNames: seq[string] = @[]
    for req in rule.requires:
      if req.certificate.len == 0:
        policyError(where & ": requires names an empty certificate")
      if req.certificate in seenNames:
        policyError(where & ": certificate '" & req.certificate &
          "' is required twice")
      seenNames.add(req.certificate)
      validatePlatforms(req.platforms, where & ", requires '" &
        req.certificate & "'")

proc withDeclaredInRelativeTo*(policy: BranchCertificatePolicy;
                               recipeDir: string): BranchCertificatePolicy =
  ## ``policy`` with ``declaredIn`` made relative to the enacting recipe's
  ## directory. Called at compile time by ``enactCertificatePolicy``.
  ##
  ## Recipe compiles are cached location-independently: one compiled provider
  ## serves every copy of an identical recipe tree, wherever it lies. An
  ## absolute path baked into it would name the checkout that happened to be
  ## compiled first, and the lock writer would look for the policy package
  ## there. Relative to the recipe, the path means the same thing in every
  ## copy. The lock writer resolves it against the project directory.
  result = policy
  if policy.declaredIn.len > 0 and recipeDir.len > 0 and
      policy.declaredIn.isAbsolute:
    result.declaredIn = relativePath(policy.declaredIn, recipeDir).replace('\\', '/')

proc ruleLabel*(policy: BranchCertificatePolicy; index: int): string =
  ## ``rule "agents", "agents-to-dev-*"`` — how diagnostics name a rule.
  if index < 0 or index >= policy.rules.len:
    return "no rule"
  var parts: seq[string] = @[]
  for p in policy.rules[index].branches:
    if p == DetachedHeadPattern: parts.add("detachedHead")
    else: parts.add("\"" & p & "\"")
  "rule " & parts.join(", ")

proc undeclaredRequirement*(policy: BranchCertificatePolicy;
                            declared: openArray[string];
                            deferred: openArray[string] = []): string =
  ## The diagnostic for the first requirement that names a certificate
  ## ``declared`` does not contain, or "" when every name is declared. Names
  ## in ``deferred`` are skipped: they cannot be decided yet (the implicit
  ## ``test`` marking, a name computed in the body) and are checked again
  ## when the body has run.
  ##
  ## A requirement nobody can satisfy would wedge every push to its branch,
  ## so the provider compile refuses it, naming the rule, the branch pattern
  ## and the missing name (Test-Certificates.md §"The policy declaration").
  for i, rule in policy.rules:
    for req in rule.requires:
      if req.certificate in declared or req.certificate in deferred:
        continue
      let pattern =
        if rule.branches.len > 0:
          (if rule.branches[0] == DetachedHeadPattern: "detachedHead"
           else: "\"" & rule.branches[0] & "\"")
        else: "(none)"
      return "certificate policy '" & policy.name & "', " &
        ruleLabel(policy, i) & " (branch pattern " & pattern &
        "): requires certificate '" & req.certificate &
        "', which this package does not declare; declare it with " &
        "`certificate \"" & req.certificate & "\", <node>` in `build:` " &
        "or remove the requirement"
  ""

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc quoted(s: string): string =
  ## A TOML basic string. Policy text is validated to carry no quote,
  ## backslash or control character in patterns and platforms; names and
  ## packages are escaped anyway.
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)
  result.add('"')

proc stringArray(items: openArray[string]): string =
  var parts: seq[string] = @[]
  for item in items: parts.add(quoted(item))
  "[" & parts.join(", ") & "]"

proc renderCertificatePolicySnapshot*(policy: BranchCertificatePolicy): string =
  ## The canonical ``[certificate_policy]`` text, ending in a newline.
  ##
  ## Deterministic: fixed key order, rules and requirements in declaration
  ## order, so an unchanged policy renders byte-identically and the lock
  ## writer writes nothing. ``commit_gate`` is written only when it differs
  ## from ``gate_mode`` (D7: it defaults to ``gate_mode``), so the reader's
  ## default and the writer's omission are the same rule.
  validatePolicy(policy)
  result = "[" & CertificatePolicyTable & "]\n"
  result.add("schema = " & quoted(CertificatePolicySchemaV1) & "\n")
  result.add("name = " & quoted(policy.name) & "\n")
  result.add("package = " & quoted(policy.package) & "\n")
  result.add("ci_trust = " & quoted($policy.ciTrust) & "\n")
  result.add("untracked_inputs = " & quoted($policy.untrackedInputs) & "\n")
  for rule in policy.rules:
    result.add("\n[[" & CertificatePolicyRuleTable & "]]\n")
    result.add("branches = " & stringArray(rule.branches) & "\n")
    result.add("gate_mode = " & quoted($rule.gateMode) & "\n")
    if rule.commitGate != rule.gateMode:
      result.add("commit_gate = " & quoted($rule.commitGate) & "\n")
    if rule.requires.len > 0:
      var parts: seq[string] = @[]
      for req in rule.requires:
        parts.add("{ certificate = " & quoted(req.certificate) &
          ", platforms = " & stringArray(req.platforms) & " }")
      result.add("requires = [" & parts.join(", ") & "]\n")

# ---------------------------------------------------------------------------
# Locating the snapshot inside a lock document
# ---------------------------------------------------------------------------

proc isPolicyHeader*(line: string): bool =
  ## Whether a (stripped) line opens a table that belongs to the snapshot:
  ## ``[certificate_policy]``, ``[[certificate_policy.rule]]``, or any other
  ## ``certificate_policy`` table, which the strict reader then rejects as
  ## unknown rather than letting a lock reader take its keys.
  var s = line.strip()
  if not s.startsWith("["):
    return false
  s = s.strip(chars = {'[', ']', ' ', '\t'})
  s == CertificatePolicyTable or s.startsWith(CertificatePolicyTable & ".")

proc splitCertificatePolicySection*(lockText: string):
    tuple[lockPart, policySection: string] =
  ## Split a lock document into the lines that belong to the policy
  ## snapshot and everything else. A snapshot table runs from its header to
  ## the next header that is not a snapshot header. ``policySection`` is the
  ## snapshot verbatim, with trailing blank lines dropped and one final
  ## newline, or "" when the lock carries none.
  ##
  ## The lock readers use ``lockPart`` so a snapshot key (``schema``,
  ## ``name``) can never be mistaken for a lock key; the lock writer re-emits
  ## ``policySection`` verbatim, so a writer that does not evaluate the
  ## provider (the commit-time hook) carries the snapshot through untouched.
  var inPolicy = false
  var lockLines, policyLines: seq[string] = @[]
  for raw in lockText.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inPolicy = isPolicyHeader(line)
    if inPolicy: policyLines.add(raw)
    else: lockLines.add(raw)
  while policyLines.len > 0 and policyLines[^1].strip().len == 0:
    policyLines.setLen(policyLines.len - 1)
  result.lockPart = lockLines.join("\n")
  if policyLines.len > 0:
    result.policySection = policyLines.join("\n") & "\n"

# ---------------------------------------------------------------------------
# The strict reader
# ---------------------------------------------------------------------------

type
  ValueKind = enum vkString, vkStringArray, vkRequires
  ParsedValue = object
    kind: ValueKind
    str: string
    strs: seq[string]
    reqs: seq[PolicyRequirement]

  Cursor = object
    s: string
    i: int
    line: int

proc fail(c: Cursor; msg: string) {.noreturn.} =
  policyError("[certificate_policy] line " & $c.line & ": " & msg)

proc skipSpaces(c: var Cursor) =
  while c.i < c.s.len and c.s[c.i] in {' ', '\t'}: inc c.i

proc parseBasicString(c: var Cursor): string =
  if c.i >= c.s.len or c.s[c.i] != '"':
    c.fail("expected a quoted string")
  inc c.i
  while true:
    if c.i >= c.s.len:
      c.fail("unterminated string")
    let ch = c.s[c.i]
    if ch == '"':
      inc c.i
      return
    if ch == '\\':
      if c.i + 1 >= c.s.len: c.fail("unterminated escape")
      case c.s[c.i + 1]
      of '\\': result.add('\\')
      of '"': result.add('"')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      else: c.fail("unsupported escape \\" & $c.s[c.i + 1])
      c.i += 2
    else:
      result.add(ch)
      inc c.i

proc parseStringArray(c: var Cursor): seq[string] =
  if c.i >= c.s.len or c.s[c.i] != '[':
    c.fail("expected an array of strings")
  inc c.i
  c.skipSpaces()
  if c.i < c.s.len and c.s[c.i] == ']':
    inc c.i
    return
  while true:
    c.skipSpaces()
    result.add(c.parseBasicString())
    c.skipSpaces()
    if c.i >= c.s.len: c.fail("unterminated array")
    if c.s[c.i] == ',':
      inc c.i
      continue
    if c.s[c.i] == ']':
      inc c.i
      return
    c.fail("expected ',' or ']' in an array")

proc parseRequirement(c: var Cursor): PolicyRequirement =
  if c.i >= c.s.len or c.s[c.i] != '{':
    c.fail("expected '{' opening a requirement")
  inc c.i
  var sawCertificate, sawPlatforms = false
  while true:
    c.skipSpaces()
    if c.i >= c.s.len: c.fail("unterminated requirement")
    if c.s[c.i] == '}':
      inc c.i
      break
    var key = ""
    while c.i < c.s.len and c.s[c.i] in {'a'..'z', 'A'..'Z', '0'..'9', '_',
        '-'}:
      key.add(c.s[c.i])
      inc c.i
    c.skipSpaces()
    if c.i >= c.s.len or c.s[c.i] != '=':
      c.fail("expected '=' after requirement key '" & key & "'")
    inc c.i
    c.skipSpaces()
    case key
    of "certificate":
      if sawCertificate: c.fail("requirement key 'certificate' given twice")
      sawCertificate = true
      result.certificate = c.parseBasicString()
    of "platforms":
      if sawPlatforms: c.fail("requirement key 'platforms' given twice")
      sawPlatforms = true
      result.platforms = c.parseStringArray()
    else:
      c.fail("unknown requirement key '" & key &
        "' (expected certificate, platforms)")
    c.skipSpaces()
    if c.i < c.s.len and c.s[c.i] == ',':
      inc c.i
  if not sawCertificate: c.fail("a requirement needs 'certificate'")
  if not sawPlatforms: c.fail("a requirement needs 'platforms'")

proc parseRequires(c: var Cursor): seq[PolicyRequirement] =
  if c.i >= c.s.len or c.s[c.i] != '[':
    c.fail("expected an array of requirements")
  inc c.i
  c.skipSpaces()
  if c.i < c.s.len and c.s[c.i] == ']':
    inc c.i
    return
  while true:
    c.skipSpaces()
    result.add(c.parseRequirement())
    c.skipSpaces()
    if c.i >= c.s.len: c.fail("unterminated requires array")
    if c.s[c.i] == ',':
      inc c.i
      continue
    if c.s[c.i] == ']':
      inc c.i
      return
    c.fail("expected ',' or ']' in requires")

proc parseMode(value, key: string; line: int): PolicyMode =
  for m in PolicyMode:
    if $m == value: return m
  policyError("[certificate_policy] line " & $line & ": unknown " & key &
    " '" & value & "' (expected off, advisory, required)")

proc parseCertificatePolicySnapshot*(section: string; requirePackage = true):
    BranchCertificatePolicy =
  ## Parse a ``[certificate_policy]`` snapshot (as
  ## ``splitCertificatePolicySection`` returns it) strictly. Raises
  ## ``CertificatePolicySnapshotError`` on any unknown table or key, any
  ## unknown mode, a missing or wrong ``schema``, a malformed value, and
  ## every error ``validatePolicy`` reports.
  ##
  ## Absent optional keys take the documented defaults: ``ci_trust`` is
  ## ``advisory``, ``untracked_inputs`` is ``read-set``, a rule's
  ## ``gate_mode`` is ``off``, its ``commit_gate`` is its ``gate_mode``, and
  ## ``requires`` is empty.
  type Context = enum cxNone, cxPolicy, cxRule
  var ctx = cxNone
  var sawPolicyTable = false
  var schema = ""
  var seenKeys: seq[string] = @[]
  var ruleCommitGateSet = false
  var lineNo = 0
  template finishRule() =
    if ctx == cxRule and not ruleCommitGateSet:
      result.rules[^1].commitGate = result.rules[^1].gateMode
  for raw in section.splitLines():
    inc lineNo
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("["):
      finishRule()
      if line == "[" & CertificatePolicyTable & "]":
        if sawPolicyTable:
          policyError("[certificate_policy] line " & $lineNo &
            ": the [certificate_policy] table appears twice")
        if result.rules.len > 0:
          policyError("[certificate_policy] line " & $lineNo &
            ": [certificate_policy] must precede its rules")
        sawPolicyTable = true
        ctx = cxPolicy
      elif line == "[[" & CertificatePolicyRuleTable & "]]":
        if not sawPolicyTable:
          policyError("[certificate_policy] line " & $lineNo &
            ": a rule appears before the [certificate_policy] table")
        result.rules.add(PolicyRule(gateMode: pmOff))
        ruleCommitGateSet = false
        ctx = cxRule
      else:
        policyError("[certificate_policy] line " & $lineNo &
          ": unknown table " & line)
      seenKeys = @[]
      continue
    if ctx == cxNone:
      policyError("[certificate_policy] line " & $lineNo &
        ": a key outside the [certificate_policy] table")
    let eq = line.find('=')
    if eq <= 0:
      policyError("[certificate_policy] line " & $lineNo &
        ": expected 'key = value'")
    let key = line[0 ..< eq].strip()
    if key in seenKeys:
      policyError("[certificate_policy] line " & $lineNo & ": key '" & key &
        "' given twice")
    seenKeys.add(key)
    var c = Cursor(s: line, i: eq + 1, line: lineNo)
    c.skipSpaces()
    var value: ParsedValue
    case ctx
    of cxPolicy:
      case key
      of "schema", "name", "package", "ci_trust", "untracked_inputs":
        value = ParsedValue(kind: vkString, str: c.parseBasicString())
      else:
        policyError("[certificate_policy] line " & $lineNo &
          ": unknown key '" & key & "' (expected schema, name, package, " &
          "ci_trust, untracked_inputs)")
    of cxRule:
      case key
      of "branches":
        value = ParsedValue(kind: vkStringArray, strs: c.parseStringArray())
      of "gate_mode", "commit_gate":
        value = ParsedValue(kind: vkString, str: c.parseBasicString())
      of "requires":
        value = ParsedValue(kind: vkRequires, reqs: c.parseRequires())
      else:
        policyError("[certificate_policy] line " & $lineNo &
          ": unknown rule key '" & key & "' (expected branches, gate_mode, " &
          "commit_gate, requires)")
    of cxNone: discard
    c.skipSpaces()
    if c.i < c.s.len and c.s[c.i] != '#':
      c.fail("unexpected text after the value of '" & key & "'")
    case ctx
    of cxPolicy:
      case key
      of "schema": schema = value.str
      of "name": result.name = value.str
      of "package": result.package = value.str
      of "ci_trust":
        var found = false
        for t in PolicyCiTrust:
          if $t == value.str:
            result.ciTrust = t
            found = true
        if not found:
          policyError("[certificate_policy] line " & $lineNo &
            ": unknown ci_trust '" & value.str & "' (expected advisory, skip)")
      of "untracked_inputs":
        var found = false
        for t in PolicyUntrackedInputs:
          if $t == value.str:
            result.untrackedInputs = t
            found = true
        if not found:
          policyError("[certificate_policy] line " & $lineNo &
            ": unknown untracked_inputs '" & value.str &
            "' (expected read-set, strict)")
      else: discard
    of cxRule:
      case key
      of "branches": result.rules[^1].branches = value.strs
      of "gate_mode":
        result.rules[^1].gateMode = parseMode(value.str, key, lineNo)
      of "commit_gate":
        result.rules[^1].commitGate = parseMode(value.str, key, lineNo)
        ruleCommitGateSet = true
      of "requires": result.rules[^1].requires = value.reqs
      else: discard
    of cxNone: discard
  finishRule()
  if not sawPolicyTable:
    policyError("no [certificate_policy] table")
  if schema != CertificatePolicySchemaV1:
    policyError("[certificate_policy] schema '" & schema &
      "' is not supported (expected " & CertificatePolicySchemaV1 & ")")
  if requirePackage and result.package.len == 0:
    policyError("[certificate_policy] needs 'package', the locked package " &
      "that exports the policy")
  validatePolicy(result)

proc replaceCertificatePolicySection*(lockText, section: string): string =
  ## ``lockText`` with its snapshot replaced by ``section`` (removed when
  ## ``section`` is ""), every other byte kept. The result has the layout
  ## ``repro_lock.serializeLockedDependencies`` writes: the lock, one blank
  ## line, the snapshot. So a lock this produces and one the full writer
  ## produces from the same content are byte-identical, and the two writers
  ## (``repro lock refresh`` and the lock-update node) cannot disagree about
  ## whether anything changed.
  let split = splitCertificatePolicySection(lockText)
  var lockPart = split.lockPart
  while lockPart.len > 0 and lockPart[^1] in {'\n', '\r', ' ', '\t'}:
    lockPart.setLen(lockPart.len - 1)
  result = lockPart & "\n"
  if section.len > 0:
    result.add("\n")
    result.add(section)
    if not section.endsWith("\n"):
      result.add("\n")

proc readCertificatePolicySnapshot*(lockText: string):
    tuple[present: bool; policy: BranchCertificatePolicy] =
  ## The snapshot a lock document carries, read strictly. ``present`` is
  ## false when the lock has no ``[certificate_policy]`` table: there is no
  ## requirement on any branch. A malformed snapshot raises.
  let split = splitCertificatePolicySection(lockText)
  if split.policySection.len == 0:
    return
  result.present = true
  result.policy = parseCertificatePolicySnapshot(split.policySection)

# ---------------------------------------------------------------------------
# Branch matching
# ---------------------------------------------------------------------------

proc classMatch(pattern: string; pi: var int; ch: char): tuple[ok, matched: bool] =
  ## A ``[...]`` class at ``pattern[pi]`` (the ``[``). Advances ``pi`` past
  ## the closing ``]``. ``ok`` is false for an unterminated class, which then
  ## matches only a literal ``[``.
  var i = pi + 1
  var negate = false
  if i < pattern.len and pattern[i] in {'!', '^'}:
    negate = true
    inc i
  var first = true
  var hit = false
  while i < pattern.len and (first or pattern[i] != ']'):
    first = false
    var lo = pattern[i]
    if lo == '\\' and i + 1 < pattern.len:
      inc i
      lo = pattern[i]
    var hi = lo
    if i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']':
      hi = pattern[i + 2]
      if hi == '\\' and i + 3 < pattern.len:
        inc i
        hi = pattern[i + 2]
      i += 2
    if ch >= lo and ch <= hi: hit = true
    inc i
  if i >= pattern.len:
    return (ok: false, matched: false)
  pi = i + 1
  (ok: true, matched: (hit xor negate) and ch != '/')

proc wildmatchFrom(pattern: string; pi: int; text: string; ti: int): bool =
  var p = pi
  var t = ti
  while p < pattern.len:
    let pc = pattern[p]
    case pc
    of '*':
      if p + 1 < pattern.len and pattern[p + 1] == '*':
        var q = p + 2
        while q < pattern.len and pattern[q] == '*': inc q
        # ``**`` crosses '/' only as a whole component (git's wildmatch.c
        # under WM_PATHNAME): preceded by the start or '/', and followed by
        # the end or '/'. Anywhere else (``agents-**``) it is a plain ``*``.
        if (p == 0 or pattern[p - 1] == '/') and
            (q == pattern.len or pattern[q] == '/'):
          # ``**/`` also matches zero directories.
          if q < pattern.len and wildmatchFrom(pattern, q + 1, text, t):
            return true
          for k in t .. text.len:
            if wildmatchFrom(pattern, q, text, k):
              return true
          return false
        var k = t
        while true:
          if wildmatchFrom(pattern, q, text, k):
            return true
          if k >= text.len or text[k] == '/':
            return false
          inc k
      # ``*``: anything within one path component.
      var k = t
      while true:
        if wildmatchFrom(pattern, p + 1, text, k):
          return true
        if k >= text.len or text[k] == '/':
          return false
        inc k
    of '?':
      if t >= text.len or text[t] == '/':
        return false
      inc p
      inc t
    of '[':
      if t >= text.len:
        return false
      var np = p
      let r = classMatch(pattern, np, text[t])
      if not r.ok:
        if text[t] != '[': return false
        inc p
        inc t
      else:
        if not r.matched: return false
        p = np
        inc t
    of '\\':
      if p + 1 < pattern.len:
        if t >= text.len or text[t] != pattern[p + 1]:
          return false
        p += 2
        inc t
      else:
        if t >= text.len or text[t] != '\\':
          return false
        inc p
        inc t
    else:
      if t >= text.len or text[t] != pc:
        return false
      inc p
      inc t
  t == text.len

proc wildmatch*(pattern, name: string): bool =
  ## git's wildmatch with ``WM_PATHNAME`` (the ``git for-each-ref`` /
  ## refspec flavour): ``*`` and ``?`` and ``[...]`` stay within one path
  ## component, ``**`` matches across components, and ``**/`` also matches
  ## zero components. See https://git-scm.com/docs/gitignore#_pattern_format
  ## for the ``**`` rules this follows.
  wildmatchFrom(pattern, 0, name, 0)

proc branchRefFromRef*(refName: string): BranchRef =
  ## A ref as a gate receives it: ``refs/heads/x`` is branch ``x``; any
  ## other ``refs/...`` (a tag, a note, a remote-tracking ref) is
  ## ``brkOther`` and never matches; a bare name is taken to be a short
  ## branch name.
  if refName.startsWith("refs/heads/"):
    BranchRef(kind: brkBranch, name: refName["refs/heads/".len .. ^1])
  elif refName.startsWith("refs/"):
    BranchRef(kind: brkOther, name: refName)
  else:
    BranchRef(kind: brkBranch, name: refName)

proc commitTimeBranch*(headRef, upstreamMerge: string): BranchRef =
  ## The branch a commit is judged as (Test-Certificates.md §"Branch
  ## matching"): the upstream's branch name (``branch.<b>.merge``) when one
  ## is configured, otherwise the current branch's own name. ``headRef`` is
  ## what ``HEAD`` points at (``refs/heads/<b>``), empty for a detached
  ## ``HEAD``.
  if headRef.len == 0:
    return BranchRef(kind: brkDetached)
  let current = branchRefFromRef(headRef)
  if current.kind != brkBranch:
    return current
  if upstreamMerge.len > 0:
    let upstream = branchRefFromRef(upstreamMerge)
    if upstream.kind == brkBranch:
      return upstream
  current

proc matchPolicy*(policy: BranchCertificatePolicy; target: BranchRef):
    PolicyMatch =
  ## The first rule whose pattern matches ``target``, in declaration order.
  ## A branch no rule matches has no requirement. A detached ``HEAD``
  ## matches only a ``detachedHead`` rule, never ``**``. A tag or any other
  ## ref never matches.
  result.ruleIndex = -1
  case target.kind
  of brkOther:
    result.reason = target.name & " is not a branch; only branches are gated"
    return
  of brkDetached:
    for i, rule in policy.rules:
      if DetachedHeadPattern in rule.branches:
        return PolicyMatch(matched: true, ruleIndex: i,
          pattern: DetachedHeadPattern, rule: rule)
    result.reason = "detached HEAD: no branch rule applies"
  of brkBranch:
    for i, rule in policy.rules:
      for pattern in rule.branches:
        if pattern == DetachedHeadPattern:
          continue
        if wildmatch(pattern, target.name):
          return PolicyMatch(matched: true, ruleIndex: i, pattern: pattern,
            rule: rule)
    result.reason = "branch '" & target.name & "' matches no rule: " &
      "no requirement"

# ---------------------------------------------------------------------------
# What a gate takes from a matched rule (Test-Certificates TC-9c)
# ---------------------------------------------------------------------------

type
  CertificateGateKind* = enum
    ## Which gate is asking. The commit gate reads ``commit_gate``; the
    ## client pre-push gate and the gateway read ``gate_mode``
    ## (Test-Certificates.md §"Modes").
    cgkCommit = "commit"
    cgkPush = "push"

proc modeFor*(rule: PolicyRule; gate: CertificateGateKind): PolicyMode =
  ## The rule's mode for ``gate``. ``commitGate`` already carries the
  ## ``gate_mode`` default (operator decision D7): the reader and the DSL
  ## both resolve it, so a gate never re-applies the default.
  case gate
  of cgkCommit: rule.commitGate
  of cgkPush: rule.gateMode

proc stricterMode*(a, b: PolicyMode): PolicyMode =
  ## The stricter of two modes (``off`` < ``advisory`` < ``required``). The
  ## gateway's ratchet takes the stricter of the pushed snapshot's and the
  ## anchor's ``gate_mode`` (Push-Gateway-Wiring-And-Policy §4.2).
  if ord(a) >= ord(b): a else: b

proc platformsLabel*(platforms: openArray[string]): string =
  ## ``any platform`` for ``["*"]``, the platforms joined otherwise.
  if platforms.len == 1 and platforms[0] == AnyPlatformMarker:
    "any platform"
  else:
    @platforms.join(", ")

proc requirementLabel*(req: PolicyRequirement): string =
  ## ``pre-commit (any platform)``, ``unit-suite (linux/amd64)``.
  req.certificate & " (" & platformsLabel(req.platforms) & ")"

proc requirementsLabel*(requires: openArray[PolicyRequirement]): string =
  ## Every requirement, comma-separated; ``nothing required`` when none.
  var parts: seq[string] = @[]
  for req in requires:
    parts.add(requirementLabel(req))
  if parts.len == 0: "nothing required" else: parts.join(", ")

proc branchPatternsLabel*(rule: PolicyRule): string =
  ## A rule's patterns as ``ensure`` prints them; ``detached HEAD`` for the
  ## ``detachedHead`` rule.
  var parts: seq[string] = @[]
  for p in rule.branches:
    parts.add(if p == DetachedHeadPattern: "detached HEAD" else: p)
  parts.join(", ")

proc ruleGateLine*(rule: PolicyRule): string =
  ## One line per rule, as ``repro hooks ensure --vcs`` reports the gates it
  ## generated (Test-Certificates.md §"Generated gates"), for example
  ## ``certificate gate: agents, agents-to-dev-* -> pre-commit (any
  ## platform); commit advisory, push required``.
  "certificate gate: " & branchPatternsLabel(rule) & " -> " &
    requirementsLabel(rule.requires) &
    "; commit " & $rule.commitGate & ", push " & $rule.gateMode

proc groupRequirementsByPlatforms*(requires: openArray[PolicyRequirement]):
    seq[tuple[platforms: seq[string]; names: seq[string]]] =
  ## The requirements grouped by their platform set, in first-appearance
  ## order. A coverage evaluator judges one platform set at a time: each
  ## listed platform's union must hold every name of its group, and the
  ## ``["*"]`` group must be held by one platform's union on its own
  ## (Test-Certificates.md §"How a gate computes coverage", step 4).
  for req in requires:
    var placed = false
    for group in result.mitems:
      if group.platforms == req.platforms:
        if req.certificate notin group.names:
          group.names.add(req.certificate)
        placed = true
        break
    if not placed:
      result.add((platforms: req.platforms, names: @[req.certificate]))

# ---------------------------------------------------------------------------
# The provider's emission: how an evaluated policy leaves the recipe process
# ---------------------------------------------------------------------------

const
  CertificatePolicyEmitEnvVar* = "REPRO_EMIT_CERTIFICATE_POLICY"
    ## When this names a writable path, a compiled provider writes the policy
    ## its main package enacts there at module initialisation (the same
    ## channel ``REPRO_EMIT_SOLVER_INPUTS`` and ``REPRO_EMIT_LOCK_FILES`` use).
    ## ``repro lock refresh`` and the staleness checks read it.
  CertificatePolicyEmissionHeader* =
    "# reprobuild certificate policy emission v1"
    ## First line of an emission, so a reader refuses a format it does not
    ## know rather than misreading one.
  CertificatePolicyGraphStableName* = "reprobuild.certificate-policy.v1"
    ## The stable name of the provider-graph metadata node that carries the
    ## same emission, for readers that already hold the evaluated graph (the
    ## certifying run's lock-update node).

type
  CertificatePolicyEmission* = object
    ## An enacted policy as the provider reports it: the policy, the package
    ## that enacted it, and the file that declares it. The lock writer turns
    ## ``declaredIn`` into the ``package`` the snapshot names.
    policy*: BranchCertificatePolicy
    enactedBy*: string
    declaredIn*: string

proc renderCertificatePolicyEmission*(policy: BranchCertificatePolicy;
                                      enactedBy: string): string =
  ## The emission text: the header, the two provenance keys, and the
  ## snapshot rendered with an empty ``package`` (the provider does not know
  ## the lock's dependency names; the lock writer fills it in).
  var p = policy
  p.package = ""
  result = CertificatePolicyEmissionHeader & "\n"
  result.add("enacted_by = " & quoted(enactedBy) & "\n")
  result.add("declared_in = " & quoted(policy.declaredIn) & "\n")
  result.add(renderCertificatePolicySnapshot(p))

proc parseCertificatePolicyEmission*(text: string): CertificatePolicyEmission =
  ## Read ``renderCertificatePolicyEmission``'s output back, strictly.
  let split = splitCertificatePolicySection(text)
  var sawHeader = false
  for raw in split.lockPart.splitLines():
    let line = raw.strip()
    if line.len == 0: continue
    if line == CertificatePolicyEmissionHeader:
      sawHeader = true
      continue
    let eq = line.find('=')
    if eq <= 0:
      policyError("certificate policy emission: unexpected line '" & line &
        "'")
    let key = line[0 ..< eq].strip()
    var c = Cursor(s: line, i: eq + 1, line: 0)
    c.skipSpaces()
    let value = c.parseBasicString()
    case key
    of "enacted_by": result.enactedBy = value
    of "declared_in": result.declaredIn = value
    else:
      policyError("certificate policy emission: unknown key '" & key & "'")
  if not sawHeader:
    policyError("certificate policy emission: missing the '" &
      CertificatePolicyEmissionHeader & "' header")
  # The emission's snapshot carries no package yet: the lock writer names it.
  result.policy = parseCertificatePolicySnapshot(split.policySection,
    requirePackage = false)
  result.policy.package = ""
  result.policy.declaredIn = result.declaredIn
