## The closed capability vocabulary, its scope grammars, and which grant
## each operation needs (spec §"Capabilities", §"Plan").
##
## This module is pure: it decides what an operation requires; the host
## decides whether a session holds it.

import std/[strutils, unicode]

import ./types

type
  ScopeGrammar = enum
    sgNone        ## the kind takes no scope
    sgPackage     ## a package name
    sgAbsPath     ## a canonical absolute path (context.file only)
    sgIdentifier  ## a host-assigned id (screenshot, allowlist, credential)
    sgGeneration  ## stage / activate / rollback
    sgPublish     ## private / export / marketplace

const
  GenerationScopes* = ["stage", "activate", "rollback"]
  PublishScopes* = ["private", "export", "marketplace"]
  ActiveAppTarget* = "active-app"

proc grammarOf(kind: CapabilityKind): ScopeGrammar =
  case kind
  of ckContextActiveApp, ckContextSelection: sgNone
  of ckContextPackage, ckWorkspaceCreate, ckSourceRead, ckSourceWrite,
     ckBuildRun, ckTestRun, ckDebugAttach, ckPreviewRun, ckDesktopAutomate:
    sgPackage
  of ckContextFile: sgAbsPath
  of ckContextScreenshot, ckNetworkEgress, ckCredentialsUse: sgIdentifier
  of ckSystemGeneration: sgGeneration
  of ckRemixPublish: sgPublish

proc isPackageName*(s: string): bool =
  ## Package names as the catalogs spell them: an ASCII letter or digit,
  ## then letters, digits, `.`, `_`, `+` or `-`; at most 128 bytes. No
  ## separator can appear, so a package scope can never name a path.
  if s.len == 0 or s.len > 128 or not (s[0] in {'a'..'z', 'A'..'Z', '0'..'9'}):
    return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '+', '-'}:
      return false
  true

proc isIdentifier*(s: string): bool =
  ## Host-assigned identifiers: 1..128 bytes of `[A-Za-z0-9._:-]`.
  if s.len == 0 or s.len > 128:
    return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', ':', '-'}:
      return false
  true

proc isCanonicalRelPath*(p: string): bool =
  ## §"Path safety": UTF-8, `/`-separated, non-empty, no `.`/`..`/empty
  ## component, no leading `/`, no NUL or backslash, bounded. A path that
  ## is not already canonical is refused, never repaired.
  if p.len == 0 or p.len > MaxPathBytes or p[0] == '/':
    return false
  if '\0' in p or '\\' in p:
    return false
  if p.validateUtf8() != -1:
    return false
  for comp in p.split('/'):
    if comp.len == 0 or comp == "." or comp == ".." or
        comp.len > MaxPathComponentBytes:
      return false
  true

proc isCanonicalAbsPath*(p: string): bool =
  p.len > 1 and p[0] == '/' and isCanonicalRelPath(p[1 .. ^1])

proc validateGrant*(g: Grant) =
  ## Refuse a grant whose scope does not parse under its kind's grammar.
  if g.scope.len > MaxScopeBytes:
    refuse(arBoundsExceeded, "scope of " & $g.kind)
  let ok =
    case grammarOf(g.kind)
    of sgNone: g.scope.len == 0
    of sgPackage: isPackageName(g.scope)
    of sgAbsPath: isCanonicalAbsPath(g.scope)
    of sgIdentifier: isIdentifier(g.scope)
    of sgGeneration: g.scope in GenerationScopes
    of sgPublish: g.scope in PublishScopes
  if not ok:
    refuse(arBadScope, $g.kind & " does not take scope " & g.scope.escape)

proc isApprovalOnly*(g: Grant): bool =
  ## Grants a session can never hold: they are conferred per plan by an
  ## approval. `remix.publish:private` is the one publication a session may
  ## hold, because a private Remix leaves nothing outside the machine.
  case g.kind
  of ckNetworkEgress, ckCredentialsUse, ckSystemGeneration: true
  of ckRemixPublish: g.scope != "private"
  else: false

proc grant*(kind: CapabilityKind; scope = ""): Grant =
  Grant(kind: kind, scope: scope)

proc parseGrant*(s: string): Grant =
  ## `kind` or `kind:scope`, as `$Grant` prints it. Validated.
  let colon = s.find(':')
  let (k, scope) =
    if colon < 0: (s, "")
    else: (s[0 ..< colon], s[colon + 1 .. ^1])
  result = Grant(kind: parseEnumStrict[CapabilityKind](k, arUnknownCapability),
                 scope: scope)
  validateGrant(result)
  # One grant has one spelling: `kind:` with an empty scope is refused
  # rather than read as the scopeless grant.
  if $result != s:
    refuse(arBadScope, "non-canonical grant spelling " & s.escape)

proc usesWorkspaceTarget*(kind: OperationKind): bool =
  ## Operations whose target is a session workspace id.
  kind in {okSourceRead, okSourceWrite, okSourceList, okSourceDiff,
           okBuildRun, okTestRun,
           okPreviewStart, okPreviewStop, okGenerationStage, okRemixCapture,
           okRemixExport, okRemixSubmit}

proc usesPathArg*(kind: OperationKind): bool =
  kind in {okSourceRead, okSourceWrite, okSourceList}

proc familyOf*(kind: OperationKind): Family =
  case kind
  of okOwnershipResolve: fOwnership
  of okCheckoutCreate, okCheckoutReapply: fCheckout
  of okSourceRead, okSourceWrite, okSourceList, okSourceDiff: fSource
  of okBuildRun: fBuild
  of okTestRun: fTest
  of okPreviewStart, okPreviewStop: fPreview
  of okGenerationStage, okGenerationActivate, okGenerationRollback:
    fGeneration
  of okRemixCapture, okRemixExport, okRemixSubmit, okRemixCompose: fRemix

proc requiredGrants*(op: Operation; packageOfTarget: string): seq[Grant] =
  ## Every grant `op` exercises. `packageOfTarget` is the package of the
  ## workspace `op` targets (ignored for operations that do not target a
  ## workspace). The caller has already checked that the workspace belongs
  ## to the session.
  let pkg = packageOfTarget
  case op.kind
  of okOwnershipResolve:
    if op.target == ActiveAppTarget:
      result.add grant(ckContextActiveApp)
    else:
      result.add grant(ckContextPackage, op.target)
  of okCheckoutCreate, okCheckoutReapply:
    result.add grant(ckWorkspaceCreate, op.target)
  of okSourceRead, okSourceList, okSourceDiff:
    result.add grant(ckSourceRead, pkg)
  of okSourceWrite:
    result.add grant(ckSourceWrite, pkg)
  of okBuildRun, okTestRun:
    result.add grant(if op.kind == okBuildRun: ckBuildRun else: ckTestRun, pkg)
    if op.hasArg("network"):
      result.add grant(ckNetworkEgress, op.arg("network"))
  of okPreviewStart, okPreviewStop:
    result.add grant(ckPreviewRun, pkg)
    if op.arg("automate") == "1":
      result.add grant(ckDesktopAutomate, pkg)
    if op.arg("debug") == "1":
      result.add grant(ckDebugAttach, pkg)
  of okGenerationStage:
    result.add grant(ckSystemGeneration, "stage")
  of okGenerationActivate:
    result.add grant(ckSystemGeneration, "activate")
  of okGenerationRollback:
    result.add grant(ckSystemGeneration, "rollback")
  of okRemixCapture:
    result.add grant(ckRemixPublish, "private")
  of okRemixExport:
    result.add grant(ckRemixPublish, "export")
  of okRemixSubmit:
    result.add grant(ckRemixPublish, "marketplace")
    result.add grant(ckCredentialsUse, op.arg("credential"))
  of okRemixCompose:
    # Composing local Remixes produces a workspace for the target package.
    result.add grant(ckWorkspaceCreate, op.target)
  for g in result:
    validateGrant(g)
