## The post-extraction step of a tarball provisioning edge.
##
## Some tool prefixes are not just an unpacked archive: an SDK whose
## extension modules have to be compiled against the prefix's own runtime, or
## an installer whose payload is laid out by running a program. Such a step
## runs INSIDE the tarball edge, on the staging prefix, after the archive and
## its closure are unpacked and before the prefix is checked, sealed and
## published:
##
##   1. derive the prefix's cache identity and try to substitute it from the
##      shared binary cache; a hit ends the edge before any download;
##   2. fetch and verify the archive and its closure, unpack them;
##   3. run the post-extraction step (this module's hook);
##   4. apply the step's declared prunes, check the staging tree for its own
##      path, seal;
##   5. publish.
##
## The step's identity is part of the prefix's cache identity: its kind and
## contract version, the digest of its manifest, its build configuration, the
## digests of the files it reads, its declared prunes and rewrites, the
## normalisation contract, and the complete cache identity of every
## provisioned tool it runs with (one ``buildInputs`` option, not
## ``depClosure``: a consumer does not fetch the tools that built a prefix).
## When any of those tools has
## no complete identity, the prefix's identity is incomplete and the prefix is
## realized locally but neither substituted nor published.
##
## The step's IMPLEMENTATION is registered by kind (``registerPostExtractStep``)
## by the module that owns that kind of step, so this edge knows nothing
## about any particular ecosystem.
##
## **Graph outputs never enter a tool prefix.** A step reads only pinned
## files (each declared with its SHA-256) and provisioned tools. A file the
## build graph produces is cached by the action cache under its own action
## identity, so a change to it re-runs the actions that consume it; copied
## into a tool prefix it would be served under the prefix's identity and a
## change would go unnoticed. ``validatePostExtractStepDecl`` refuses such a
## declaration before any edge runs.

import std/[os, strutils, tables]

import repro_interface_artifacts
from repro_core/paths import extendedPath

const
  DefaultNormalisationContract* = "tool-prefix-normalisation-v1"
    ## The rules every post-extraction step's output is held to before it is
    ## sealed: the step's declared prunes are applied, and the staging tree
    ## must not contain its own absolute path. A change to those rules is a
    ## new version, because it changes which bytes a sealed prefix can hold.

type
  PostExtractStepInputFile* = object
    ## A file the step reads, pinned by its content.
    path*: string
      ## Absolute, or relative to the directory the declaration was read
      ## from (the plan's ``closureManifestRoot``).
    sha256*: string
      ## Lowercase hex SHA-256 of the file. Required: the file's content is
      ## what keys the prefix, never its path.

  PostExtractStepExternalInput* = object
    ## A tool or library the step runs with that was realized OUTSIDE this
    ## provisioning subgraph, by a caller that knows its identity.
    role*: string
    prefix*: string
      ## Its realized location, handed to the step.
    cacheKey*: string
      ## Its complete cache-entry key; "" when ``incomplete`` is set.
    incomplete*: string
      ## Why it has no complete identity (a library built by a source recipe
      ## whose identity is not yet bound, say).

  PostExtractStepDecl* = object
    ## What a tarball arm declares about its post-extraction step. The zero
    ## value (empty ``kind``) means the arm has none.
    kind*: string
      ## The registered step implementation, for example ``gem-closure``.
    contractVersion*: string
      ## The version of the step's behaviour contract (its command,
      ## environment and output rules), for example ``gem-closure-v1``.
    manifestDigest*: string
      ## Digest of the step's own manifest content, canonicalised by the
      ## declaring module.
    buildConfig*: seq[string]
      ## Canonical per-package build configuration lines.
    stepData*: seq[string]
      ## The step's own declaration content in the form its runner reads (a
      ## gem closure's lines in install order, say). Carried with the plan,
      ## and deliberately NOT a separate identity option: everything in it
      ## must already be keyed by ``manifestDigest`` and ``buildConfig``,
      ## which the declaring module derives from the same content.
    normalisationContract*: string
      ## Defaults to ``DefaultNormalisationContract``.
    prunePaths*: seq[string]
      ## Prefix-relative paths deleted after the step.
    rewrittenFiles*: seq[string]
      ## Prefix-relative files the step rewrites to remove host-specific
      ## content (an absolute interpreter path in a script, say).
    inputFiles*: seq[PostExtractStepInputFile]
    declarationFiles*: seq[string]
      ## Files the declaration itself was read from on the declaring host
      ## (a manifest whose parsed content is ``manifestDigest``). They are
      ## not keyed by path or bytes -- their content already is the
      ## manifest digest -- but one that lies under an output of the build
      ## graph is refused like an input file (``validatePostExtractStepDecl``).
    dependencies*: seq[InterfaceToolUse]
      ## Provisioned packages the step runs with, each realized by its own
      ## provisioning edge before this one.
    externalInputs*: seq[PostExtractStepExternalInput]

  PostExtractStepTool* = object
    ## A realized tool handed to the step.
    role*: string
    prefix*: string
    executable*: string

  PostExtractStepContext* = object
    ## Everything a step implementation may use. The step writes only under
    ## ``stagingPrefix`` and ``scratchDir``.
    packageSelector*: string
    stagingPrefix*: string
      ## The unsealed prefix the archive and closure were unpacked into.
    finalPrefix*: string
      ## Where the prefix will live once sealed. A step must not write it
      ## into the prefix (it differs between hosts); it is here for
      ## diagnostics only.
    scratchDir*: string
      ## An empty directory outside the prefix, removed after the step.
    storeRoot*: string
    decl*: PostExtractStepDecl
    tools*: seq[PostExtractStepTool]
    inputFiles*: seq[string]
      ## The verified ``decl.inputFiles``, resolved, in declaration order.
    placeFile*: proc(entry: ClosureEntry; destination: string) {.gcsafe,
                                                                 closure.}
      ## Fetch a whole-file closure entry (``ClosureFileKind``) through the
      ## edge's verified, cached download and copy it to
      ## ``destination / entry.path``. A digest mismatch raises; nothing
      ## else on the host can satisfy the fetch. For a step whose payloads
      ## are pinned files named by its own manifest (a gem closure).

  PostExtractStepRunner* = proc(ctx: PostExtractStepContext) {.gcsafe, closure.}
    ## Runs the step. Raises to fail the edge; the staging prefix is then
    ## discarded and nothing is sealed or published.

  ToolPrefixDeclarationError* = object of ValueError
    ## A provisioning declaration that cannot be realized as a tool prefix,
    ## refused before any edge runs.

  PostExtractDeclProvider* = proc(use: InterfaceToolUse;
                                  record: InterfaceTarballProvisioning):
      PostExtractStepDecl {.gcsafe, closure.}
    ## Reads the post-extraction step a selected tarball record declares, in
    ## the declaring module's own terms, and returns it as a declaration; the
    ## zero value when the record declares none of that module's steps.

var postExtractSteps: Table[string, PostExtractStepRunner]
  ## Registered implementations by kind. Written at module initialisation of
  ## the owning modules (and by tests), read by the tarball edge executor.

proc registerPostExtractStep*(kind: string; runner: PostExtractStepRunner) =
  ## Install the implementation of ``kind``, replacing any earlier one.
  {.cast(gcsafe).}:
    postExtractSteps[kind] = runner

proc postExtractStepRunner*(kind: string): PostExtractStepRunner =
  ## The implementation of ``kind``; raises when none is registered.
  {.cast(gcsafe).}:
    if not postExtractSteps.hasKey(kind):
      raise newException(ToolPrefixDeclarationError,
        "tool-resolution failed: no post-extraction step implementation " &
        "is registered for kind \"" & kind & "\"")
    postExtractSteps[kind]

proc hasPostExtractStep*(decl: PostExtractStepDecl): bool =
  decl.kind.len > 0

var postExtractDeclProviders: seq[tuple[name: string;
                                        provider: PostExtractDeclProvider]]
  ## Declaration readers by owner name, consulted in registration order.

proc registerPostExtractDeclProvider*(name: string;
                                      provider: PostExtractDeclProvider) =
  ## Install the module ``name``'s declaration reader, replacing an earlier
  ## one of the same name. The tarball planner asks every reader about the
  ## record it selected, so a record field owned by one module becomes a
  ## step without this edge knowing the field.
  {.cast(gcsafe).}:
    for item in postExtractDeclProviders.mitems:
      if item.name == name:
        item.provider = provider
        return
    postExtractDeclProviders.add((name: name, provider: provider))

proc unregisterPostExtractDeclProvider*(name: string) =
  {.cast(gcsafe).}:
    var kept: seq[tuple[name: string; provider: PostExtractDeclProvider]]
    for item in postExtractDeclProviders:
      if item.name != name:
        kept.add(item)
    postExtractDeclProviders = kept

proc postExtractStepDeclFor*(use: InterfaceToolUse;
                             record: InterfaceTarballProvisioning):
    PostExtractStepDecl =
  ## The post-extraction step ``record`` declares, from whichever registered
  ## reader recognises it; the zero value when none does. Two readers
  ## claiming one record is a declaration error: a prefix has one step.
  var owner = ""
  {.cast(gcsafe).}:
    for item in postExtractDeclProviders:
      let decl = item.provider(use, record)
      if not hasPostExtractStep(decl):
        continue
      if owner.len > 0:
        raise newException(ToolPrefixDeclarationError,
          "tool-resolution failed: the tarball record of " &
          use.packageSelector & " declares two post-extraction steps (" &
          owner & " and " & item.name & "); a prefix has at most one")
      owner = item.name
      result = decl

proc effectiveNormalisationContract*(decl: PostExtractStepDecl): string =
  if decl.normalisationContract.len > 0: decl.normalisationContract
  else: DefaultNormalisationContract

proc resolvedInputFilePath*(input: PostExtractStepInputFile;
                            declarationRoot: string): string =
  if input.path.isAbsolute or declarationRoot.len == 0:
    absolutePath(input.path)
  else:
    absolutePath(declarationRoot / input.path)

proc isUnder(path, root: string): bool =
  let p = normalizedPath(absolutePath(path))
  let r = normalizedPath(absolutePath(root))
  when defined(windows):
    let (pp, rr) = (p.toLowerAscii, r.toLowerAscii)
  else:
    let (pp, rr) = (p, r)
  pp == rr or pp.startsWith(rr & DirSep)

proc isRelativeInside(path: string): bool =
  path.len > 0 and not path.isAbsolute and ".." notin path.split({'/', '\\'})

proc validatePostExtractStepDecl*(decl: PostExtractStepDecl;
                                  packageSelector, declarationRoot: string;
                                  graphOutputs: openArray[string] = []) =
  ## Refuse a step declaration that cannot be realized into a shareable tool
  ## prefix. ``graphOutputs`` are the paths the build graph declares as
  ## action outputs; a step input at or under one of them is refused, because
  ## a graph output must stay under the action cache (see the module
  ## comment). Every input file must carry a SHA-256, which is also what
  ## keeps an unpinned file from slipping into the prefix's identity as a
  ## path.
  if not hasPostExtractStep(decl):
    return
  let label = "the post-extraction step (" & decl.kind & ") of " &
    packageSelector
  if decl.contractVersion.len == 0:
    raise newException(ToolPrefixDeclarationError,
      "tool-resolution failed: " & label & " declares no contract version")
  for path in decl.prunePaths & decl.rewrittenFiles:
    if not isRelativeInside(path):
      raise newException(ToolPrefixDeclarationError,
        "tool-resolution failed: " & label & " names \"" & path &
        "\", which is not a relative path inside the prefix")
  for file in decl.declarationFiles:
    let resolved = resolvedInputFilePath(PostExtractStepInputFile(path: file),
      declarationRoot)
    for output in graphOutputs:
      if output.len > 0 and (isUnder(resolved, output) or
          isUnder(output, resolved)):
        raise newException(ToolPrefixDeclarationError,
          "tool-resolution failed: " & label & " is declared by " &
          resolved & ", which is an output of the build graph (" & output &
          "). A step's declaration is a committed file, never a graph " &
          "output: a graph output is cached by the action cache under its " &
          "own action identity, not inside a tool prefix.")
  for input in decl.inputFiles:
    let resolved = resolvedInputFilePath(input, declarationRoot)
    for output in graphOutputs:
      if output.len > 0 and (isUnder(resolved, output) or
          isUnder(output, resolved)):
        raise newException(ToolPrefixDeclarationError,
          "tool-resolution failed: " & label & " reads " & resolved &
          ", which is an output of the build graph (" & output & "). A " &
          "graph output is never placed in a tool prefix: it is cached by " &
          "the action cache under its own action identity, so that a " &
          "change to it re-runs its consumers. Consume it from the action " &
          "that produces it instead.")
    let digest = input.sha256.toLowerAscii
    if digest.len != 64 or not digest.allCharsInSet({'0' .. '9', 'a' .. 'f'}):
      raise newException(ToolPrefixDeclarationError,
        "tool-resolution failed: " & label & " reads " & resolved &
        " without a SHA-256 pin; every file a step reads into a tool " &
        "prefix is pinned by its content")
  for external in decl.externalInputs:
    let key = external.cacheKey.toLowerAscii
    if external.incomplete.len == 0 and (key.len != 64 or
        not key.allCharsInSet({'0' .. '9', 'a' .. 'f'})):
      raise newException(ToolPrefixDeclarationError,
        "tool-resolution failed: " & label & " runs with " & external.role &
        " but states neither its complete cache key (64 hex digits) nor " &
        "why it has none")

proc postExtractStepIdentityOptions*(decl: PostExtractStepDecl):
    seq[tuple[name: string; value: string]] =
  ## The step's contribution to the prefix's cache-entry options, excluding
  ## the tools it runs with (the caller adds their keys as ``buildInputs``).
  ## Every value is a digest or a declared, host-independent string: no
  ## path.
  if not hasPostExtractStep(decl):
    return
  result.add((name: "postExtractStep",
    value: decl.kind & "@" & decl.contractVersion))
  result.add((name: "postExtractManifest", value: decl.manifestDigest))
  result.add((name: "postExtractBuildConfig",
    value: decl.buildConfig.join("\n")))
  # In declaration order, NOT sorted: the step receives its input files as
  # an ordered list (``PostExtractStepContext.inputFiles``), so two
  # declarations naming the same files in a different order can produce
  # different bytes and must not share a key.
  var digests: seq[string]
  for input in decl.inputFiles:
    digests.add(input.sha256.toLowerAscii)
  result.add((name: "postExtractInputs", value: digests.join("\n")))
  if decl.prunePaths.len > 0:
    result.add((name: "postExtractPrunes", value: decl.prunePaths.join("\n")))
  if decl.rewrittenFiles.len > 0:
    result.add((name: "postExtractRewrites",
      value: decl.rewrittenFiles.join("\n")))
  result.add((name: "normalisation",
    value: effectiveNormalisationContract(decl)))
