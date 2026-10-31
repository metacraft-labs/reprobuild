{.define: reproDaemonParentPrewarmTest.}
# For ``warmToolIdentityCountForTest`` (the warm table is module-private).

## ``t_nix_expression_closure_keys`` -- a Nix ``expressionFile`` tool use is
## NEVER served from a cache.
##
## ## History
##
## ReproOS-Campaign-Completion M7, sibling (6), first pinned that an
## ``expressionFile`` was keyed by its PATH in the CLI tool-identity key and
## by the top-level file's bytes alone in the Nix materialization key, so a
## nixpkgs-pin bump or an edit of an imported ``.nix`` file was served the
## stale realization. The campaign closed that with an expression-closure
## SCANNER (``nix_expression_closure``), which predicted what the Nix
## evaluator reads. The owner decided on 2026-10-14, at the reprobuild
## landing of the campaign, to DROP that scanner before its replacement --
## the ``nix-eval`` / ``nix-realise`` edges of campaign M19
## (Edge-Derived-Identities.md §5) -- exists. So that dropping it does not
## reopen the false accept, every Nix tool use with an ``expressionFile`` is
## now UNCACHEABLE, exactly as the scanner already treated an expression it
## could not key: the tool-identity key (v7) and the Nix materialization key
## (v3) carry a fresh nonce, no keyed cache file is written, no warm entry
## is kept, and the identity is re-resolved on every call.
##
## ## What is asserted
##
##   * every key -- the tool-identity key in every provisioning mode, the
##     lowered-graph key and the Nix materialization key -- is uncacheable
##     and never equals itself recomputed, whatever the expression holds:
##     the four stdlib expressions, and the adversarial shapes the scanner
##     catalogued (search paths, impure builtins, computed paths, fetchers);
##   * the identity is re-resolved on every call, warm or cold, and nothing
##     is written or kept under a nonce;
##   * a remote selector-only use (no ``expressionFile``) stays cacheable and is
##     keyed deterministically -- the same key every call -- and its key
##     moves with the selector and the nixpkgs pin it names.
##
## No Nix realization is run (none is possible on the Windows host this was
## written on): the keys are measured directly, and the identity is resolved
## in path mode, which reaches the tool through ``$PATH`` on any host while
## the use still carries the Nix expression.

import std/[algorithm, json, os, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
import repro_core/nix_evaluation_policy
import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles
import repro_dsl_stdlib/packages/appimage_runtime
import repro_dsl_stdlib/packages/appimagetool
import repro_dsl_stdlib/packages/python3_with_modules
import repro_dsl_stdlib/packages/stylus

const AllModes = [tpmPathOnly, tpmNix, tpmTarball, tpmScoop, tpmFromSource]

proc writeText(path, text: string) =
  createDir(parentDir(path))
  writeFile(path, text)

const
  NixpkgsText = """
import (builtins.fetchTarball {
  url = "https://example.invalid/nixpkgs.tar.gz";
  sha256 = "0000000000000000000000000000000000000000000000000000";
}) {}
"""
  ToolText = """
let
  pkgs = import ../nixpkgs.nix;
in pkgs.buildNpmPackage {
  pname = "expr-tool";
  version = "1.0.0";
  src = ./.;
  npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
}
"""
  # The shapes the dropped scanner catalogued as what the evaluator really
  # reads (Edge-Derived-Identities.md §7.2, "what the deleted test suites
  # leave behind"). Uncacheable now regardless of shape.
  AdversarialTexts = [
    "import <nixpkgs> {}\n",
    "let x = builtins.getEnv \"HOME\"; in import (x + \"/a.nix\")\n",
    "import (./. + \"/computed.nix\")\n",
    "builtins.readFile ./data.txt\n",
    "import (builtins.fetchTarball \"https://example.invalid/x.tar.gz\")\n",
    "{ }\n"]

proc makeProject(): string =
  ## A project root (``.git``) holding ``nix/nixpkgs.nix`` and the tool
  ## expression ``nix/tool/default.nix`` (imports ``../nixpkgs.nix``,
  ## ``src = ./.``) with its lock files.
  result = createTempDir("repro-nix-uncacheable-", "")
  createDir(result / ".git")
  writeText(result / "nix" / "nixpkgs.nix", NixpkgsText)
  writeText(result / "nix" / "tool" / "default.nix", ToolText)
  writeText(result / "nix" / "tool" / "package.json", "{\"name\": \"t\"}\n")
  writeText(result / "nix" / "tool" / "package-lock.json",
    "{\"lockfileVersion\": 3}\n")

proc toolExpr(project: string): string =
  project / "nix" / "tool" / "default.nix"

proc exprUse(expr: string; selector = "reprobuild-test-expr-tool";
             nixpkgsRev = ""): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: "exprTool", packageSelector: "exprTool",
    executableName: "expr-tool",
    nixProvisioning: @[InterfaceNixProvisioning(packageName: "exprTool",
      selector: selector, executablePath: "bin/expr-tool",
      expressionFile: expr, nixpkgsRev: nixpkgsRev)])

proc consumer(expr: string; selector = "reprobuild-test-expr-tool";
              nixpkgsRev = ""): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(projectName: "uncacheableConsumer",
    packageName: "uncacheableConsumer", defaultToolProvisioning: "nix",
    toolUses: @[exprUse(expr, selector, nixpkgsRev)]))

proc planOf(useDef: InterfaceToolUse): NixAcquisitionPlan =
  ## The plan's key-relevant fields, built directly: ``nixAcquisitionPlan``
  ## refuses a Nix realization for a Windows host, and the key is what is
  ## under test, not the selection.
  let entry = useDef.nixProvisioning[0]
  NixAcquisitionPlan(packageSelector: useDef.packageSelector,
    packageId: entry.selector, nixSelector: entry.selector,
    declaredExecutablePath: entry.executablePath,
    nixExpressionFile: entry.expressionFile, nixpkgsRev: entry.nixpkgsRev,
    lockIdentity: entry.selector)

proc materializationKey(expr: string; selector = "reprobuild-test-expr-tool";
                        nixpkgsRev = ""): NixMaterializationKey =
  let useDef = exprUse(expr, selector, nixpkgsRev)
  nixMaterializationCacheKey(useDef, planOf(useDef))

template checkNeverServed(expr: string; selector: string = "reprobuild-test-expr-tool") =
  ## Every key that could serve an identity or a realization for ``expr``
  ## is uncacheable and never equals itself recomputed.
  let artifact = consumer(expr, selector)
  for mode in AllModes:
    checkpoint("mode " & $mode)
    let first = toolIdentityCacheKeyInfo(artifact, mode, pathValue = "")
    let second = toolIdentityCacheKeyInfo(artifact, mode, pathValue = "")
    check not first.cacheable
    check not second.cacheable
    check first.key != second.key
  check loweredGraphCacheKey(artifact, tpmNix, "p", "", "") !=
    loweredGraphCacheKey(artifact, tpmNix, "p", "", "")
  let m1 = materializationKey(expr, selector)
  let m2 = materializationKey(expr, selector)
  check not m1.cacheable
  check not m2.cacheable
  check m1.key != m2.key

suite "a Nix expressionFile tool use is never served from a cache":

  test "local selectors share the helper policy and never reuse predicted keys":
    let corpus = currentSourcePath().parentDir.parentDir / "fixtures" /
      "nix-evaluation-policy.json"
    for item in parseFile(corpus):
      let selector = item["selector"].getStr()
      check isMutableLocalNixSelector(selector) == item["local"].getBool()
      if item["local"].getBool():
        checkNeverServed("", selector)

  test "every key carries a nonce, in every mode, whatever the expression":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    check fileExists(expr)
    checkNeverServed(expr)
    for text in AdversarialTexts:
      checkpoint(text)
      writeText(expr, text)
      checkNeverServed(expr)
    # A path that does not exist is no different: there is nothing to key.
    checkNeverServed(project / "nix" / "absent" / "default.nix")

  test "the identity is re-resolved on every call and nothing is kept under a nonce":
    # Path mode resolves the tool from $PATH, so this runs on any host; the
    # use still carries a Nix expression, so the identity must be
    # re-resolved on every call and no keyed cache file is written.
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    let binDir = project / "bin"
    createDir(binDir)
    when defined(windows):
      writeFile(binDir / "expr-tool.exe", "fake executable\n")
    else:
      writeFile(binDir / "expr-tool", "#!/bin/sh\n")
      setFilePermissions(binDir / "expr-tool", {fpUserRead, fpUserExec})
    let savedPath = getEnv("PATH")
    putEnv("PATH", binDir)
    defer: putEnv("PATH", savedPath)
    let outDir = project / "out"
    forgetWarmBuildCaches()
    let artifact = consumer(expr)
    let r0 = warmBuildCacheCounters.toolIdentityResolves
    for round in 1 .. 3:
      let resolved = warmResolveAndWriteIdentity(artifact, outDir,
        tpmPathOnly)
      check resolved.identity.profiles.len == 1
      check warmBuildCacheCounters.toolIdentityResolves - r0 == round
      check warmToolIdentityCountForTest() == 0
    forgetWarmBuildCaches()
    discard warmResolveAndWriteIdentity(artifact, outDir, tpmPathOnly)
    check warmBuildCacheCounters.toolIdentityResolves - r0 == 4
    check warmToolIdentityCountForTest() == 0
    check toSeq(walkFiles(outDir / "tool-identity-cache" / "*.rbtp")).len == 0
    check toSeq(walkFiles(outDir / "tool-identity-cache" /
      "*.inspect.json")).len == 0

  test "a remote selector-only use stays cacheable, keyed by what it names":
    # The control: without an expressionFile the keys are deterministic, so
    # the nonce above is the expressionFile's doing, not the fixture's.
    let artifact = consumer("")
    for mode in AllModes:
      checkpoint("mode " & $mode)
      let first = toolIdentityCacheKeyInfo(artifact, mode, pathValue = "")
      check first.cacheable
      check first.key == toolIdentityCacheKeyInfo(artifact, mode,
        pathValue = "").key
    check loweredGraphCacheKey(artifact, tpmNix, "p", "", "") ==
      loweredGraphCacheKey(artifact, tpmNix, "p", "", "")
    let m1 = materializationKey("")
    check m1.cacheable
    check m1.key == materializationKey("").key
    check materializationKey("", selector = "nixpkgs#other").key != m1.key
    check materializationKey("", nixpkgsRev = repeat('a', 40)).key != m1.key
    check toolIdentityCacheKey(consumer("", selector = "nixpkgs#other"),
      tpmNix, pathValue = "") != toolIdentityCacheKey(artifact, tpmNix,
        pathValue = "")

  when not defined(windows):
    # ``nixAcquisitionPlan`` plans Nix only for a host Nix runs on.
    test "the Nix tool provision edge is never cacheable for an expressionFile":
      # ``agents``' provisioning edge (``nixToolProvisioningEdges``) declares
      # the top-level expression and the flake files as its only inputs, and
      # the evaluation runs in the helper, outside the monitor: a recorded
      # result would be served after an edit of a file the expression
      # imports. A remote selector-only use stays cacheable (the control).
      let project = makeProject()
      defer: removeDir(project)
      let store = project / "store"
      let withExpression = nixToolProvisioningEdges(
        exprUse(toolExpr(project)), store, project)
      check withExpression.actions.len == 1
      check not withExpression.actions[0].cacheable
      let selectorOnly = nixToolProvisioningEdges(
        exprUse("", selector = "nixpkgs#hello"), store, project)
      check selectorOnly.actions.len == 1
      check selectorOnly.actions[0].cacheable

suite "every workspace expressionFile is uncacheable":

  proc stdlibExpressionFiles(): seq[string] =
    ## Every ``expressionFile = "..."`` literal in the stdlib package
    ## sources, resolved the way the DSL macro resolves it (against the
    ## declaring file's directory). Read from the SOURCE, independently of
    ## the macro.
    let packagesDir = currentSourcePath().parentDir.parentDir.parentDir /
      "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" / "packages"
    for path in walkFiles(packagesDir / "*.nim"):
      for line in readFile(path).splitLines:
        let stripped = line.strip()
        if stripped.startsWith("expressionFile = \""):
          let value = stripped["expressionFile = \"".len .. ^1].split('"')[0]
          result.add(absolutePath(parentDir(path) / value))
    result.sort()

  proc norm(path: string): string =
    absolutePath(path).replace('\\', '/').toLowerAscii

  test "the four stdlib expressions are never served from a cache":
    let exprs = stdlibExpressionFiles()
    check exprs.mapIt(it.parentDir.extractFilename) == @[
      "appimage-runtime-20251108", "appimagetool-1.9.1",
      "python3-with-modules-1.0.0", "stylus-0.64.0"]
    for expr in exprs:
      checkpoint(expr)
      check fileExists(expr)
      checkNeverServed(expr)

  test "the DSL resolves each stdlib expressionFile to the same file":
    var declared: seq[string] = @[]
    for pkg in registeredPackages():
      for nix in pkg.nixProvisioning:
        if nix.expressionFile.len > 0:
          declared.add(norm(nix.expressionFile))
    declared.sort()
    check declared == stdlibExpressionFiles().mapIt(norm(it))
