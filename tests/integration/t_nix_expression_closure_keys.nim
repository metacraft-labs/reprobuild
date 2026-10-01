{.define: reproDaemonParentPrewarmTest.}
# For ``warmToolIdentityCountForTest`` (the warm table is module-private).

## ``t_nix_expression_closure_keys`` -- ReproOS-Campaign-Completion M7,
## sibling (6): a Nix ``expressionFile`` is keyed by its CONTENT CLOSURE.
##
## ## The defect this pins
##
## A tool use whose Nix realization names an ``expressionFile`` was keyed by
## the file's PATH in the CLI tool-identity key (v5, through the codec
## bytes) and by the top-level file's bytes only in the Nix materialization
## key. Every stdlib expression imports ``../nixpkgs.nix`` and ``stylus``
## builds ``src = ./.``, so a nixpkgs-pin bump or a lock-file edit moved
## neither key and the stale realization was served.
##
## ## What is asserted
##
##   * editing the top-level expression, the ``../nixpkgs.nix`` it imports,
##     or a file under the ``src = ./.`` it copies (edit, add, delete) moves
##     the tool-identity key in every provisioning mode, the lowered-graph
##     key and the Nix materialization key; an unrelated sibling outside the
##     closure moves none of them;
##   * search-path lookups, ``getEnv`` (and the other impure builtins), an
##     interpolated or home-relative path, a fetcher without a literal fixed
##     hash, a string that may be coerced to an absolute path, an escape from
##     the project root, a junction/link on a reference's path or inside a
##     hashed directory, no project root, and a lexer error each make the
##     expression UNCACHEABLE: both keys carry a fresh nonce (never equal to
##     any other key, including themselves recomputed) and the CLI cache is
##     neither read nor written -- a path-mode identity is re-resolved on
##     every call;
##   * comments and strings containing path-like text add no reference and
##     hide none; ``$${`` and ``''${`` escapes are not interpolations;
##   * a reference to a file that does not exist is bound as absent:
##     cacheable, and creating the file moves both keys;
##   * every ``expressionFile`` the stdlib declares is cacheable and its
##     closure is exactly the files it names (the oracle is the list below,
##     read off the expressions by hand), and the DSL resolves each to the
##     same file; the daemon fixture expression is uncacheable (getFlake).
##
## No Nix realization is run (none is possible on the Windows host this was
## written on): everything is measured at the key and plan level with real
## expression files on disk.

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
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

proc makeProject(): string =
  ## A project root (``.git``) holding ``nix/nixpkgs.nix``, the tool
  ## expression ``nix/tool/default.nix`` (imports ``../nixpkgs.nix``,
  ## ``src = ./.``) with its lock files, and unrelated siblings.
  result = createTempDir("repro-nix-closure-", "")
  createDir(result / ".git")
  writeText(result / "nix" / "nixpkgs.nix", NixpkgsText)
  writeText(result / "nix" / "tool" / "default.nix", ToolText)
  writeText(result / "nix" / "tool" / "package.json", "{\"name\": \"t\"}\n")
  writeText(result / "nix" / "tool" / "package-lock.json",
    "{\"lockfileVersion\": 3}\n")
  writeText(result / "nix" / "other" / "default.nix", "{ }\n")
  writeText(result / "nix" / "README.md", "unrelated\n")
  writeText(result / "unrelated.txt", "unrelated\n")

proc toolExpr(project: string): string =
  project / "nix" / "tool" / "default.nix"

proc exprUse(expr: string): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: "exprTool", packageSelector: "exprTool",
    executableName: "expr-tool",
    nixProvisioning: @[InterfaceNixProvisioning(packageName: "exprTool",
      selector: "reprobuild-test-expr-tool", executablePath: "bin/expr-tool",
      expressionFile: expr)])

proc consumer(expr: string): ProjectInterfaceArtifact =
  artifactFor(ProjectInterface(projectName: "closureConsumer",
    packageName: "closureConsumer", defaultToolProvisioning: "nix",
    toolUses: @[exprUse(expr)]))

proc materializationKey(expr: string): NixMaterializationKey =
  let useDef = exprUse(expr)
  nixMaterializationCacheKey(useDef, nixAcquisitionPlan(useDef))

proc allKeys(expr: string): seq[string] =
  ## The tool-identity key in every mode, the lowered-graph key, then the
  ## Nix materialization key.
  let artifact = consumer(expr)
  for mode in AllModes:
    result.add(toolIdentityCacheKey(artifact, mode, pathValue = ""))
  result.add(loweredGraphCacheKey(artifact, tpmNix, "provider-artifact", "",
    ""))
  result.add(materializationKey(expr).key)

template checkAllMove(before, after: seq[string]; label: string) =
  check before.len == after.len
  for i in 0 ..< min(before.len, after.len):
    if before[i] == after[i]:
      checkpoint(label & ": key " & $i & " did not move")
    check before[i] != after[i]

template checkNoneMove(before, after: seq[string]; label: string) =
  check before.len == after.len
  for i in 0 ..< min(before.len, after.len):
    if before[i] != after[i]:
      checkpoint(label & ": key " & $i & " moved")
    check before[i] == after[i]

template checkUncacheable(expr, needle: string) =
  let closure = nixExpressionClosure(expr)
  check not closure.cacheable
  if needle notin closure.reason:
    checkpoint("reason was: " & closure.reason)
  check needle in closure.reason
  check closure.digest.len == 0
  let artifact = consumer(expr)
  check not toolIdentityCacheKeyInfo(artifact, tpmNix, pathValue = "").cacheable
  for mode in AllModes:
    # A fresh nonce every time: never equal to any other key, itself
    # included, so no lookup can ever hit.
    check toolIdentityCacheKey(artifact, mode, pathValue = "") !=
      toolIdentityCacheKey(artifact, mode, pathValue = "")
  check loweredGraphCacheKey(artifact, tpmNix, "p", "", "") !=
    loweredGraphCacheKey(artifact, tpmNix, "p", "", "")
  let m1 = materializationKey(expr)
  let m2 = materializationKey(expr)
  check not m1.cacheable
  check m1.key != m2.key

proc makeDirLink(link, target: string): bool =
  ## A junction on Windows (no privilege needed), a symlink elsewhere.
  when defined(windows):
    let res = execCmdEx("cmd /c mklink /J " & quoteShell(link.replace('/', '\\')) &
      " " & quoteShell(target.replace('/', '\\')))
    res.exitCode == 0 and dirExists(link)
  else:
    try:
      createSymlink(target, link)
      true
    except OSError:
      false

proc removeDirLink(link: string) =
  when defined(windows):
    discard execCmdEx("cmd /c rmdir " & quoteShell(link.replace('/', '\\')))
  else:
    removeFile(link)

proc sortedRefs(src: string): seq[string] =
  result = scanNix(src).refs.mapIt(it.text)
  result.sort()

suite "M7 sibling (6): a Nix expressionFile is keyed by its content closure":

  test "editing the top-level expression moves every key":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    let before = allKeys(expr)
    writeText(expr, ToolText & "# edited\n")
    checkAllMove(before, allKeys(expr), "top-level edit")
    # Back to the original bytes: the original keys again (the digest is a
    # function of the content, nothing else).
    writeText(expr, ToolText)
    checkNoneMove(before, allKeys(expr), "restored")

  test "editing the imported ../nixpkgs.nix moves every key":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    let before = allKeys(expr)
    writeText(project / "nix" / "nixpkgs.nix",
      NixpkgsText.replace("0000000000000000000000000000000000000000000000000000",
        "1111111111111111111111111111111111111111111111111111"))
    checkAllMove(before, allKeys(expr), "nixpkgs pin bump")

  test "editing, adding or deleting a file under src = ./. moves every key":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    let k0 = allKeys(expr)
    writeText(project / "nix" / "tool" / "package-lock.json",
      "{\"lockfileVersion\": 3, \"edited\": true}\n")
    let k1 = allKeys(expr)
    checkAllMove(k0, k1, "lock file edit")
    writeText(project / "nix" / "tool" / "patches" / "fix.patch", "--- a\n")
    let k2 = allKeys(expr)
    checkAllMove(k1, k2, "file added under src")
    removeFile(project / "nix" / "tool" / "package.json")
    checkAllMove(k2, allKeys(expr), "file deleted under src")

  test "an unrelated sibling outside the closure moves no key":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    let before = allKeys(expr)
    writeText(project / "nix" / "other" / "default.nix", "{ edited = 1; }\n")
    writeText(project / "nix" / "README.md", "edited\n")
    writeText(project / "unrelated.txt", "edited\n")
    writeText(project / "nix" / "new-sibling.nix", "{ }\n")
    checkNoneMove(before, allKeys(expr), "unrelated siblings")
    let closure = nixExpressionClosure(expr)
    check closure.cacheable
    check closure.entries.mapIt(it.relativePath) ==
      @["nix/nixpkgs.nix", "nix/tool", "nix/tool/default.nix"]

  test "search paths, impure builtins, interpolated paths and unhashed fetchers are uncacheable":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    let cases = [
      ("import <nixpkgs> {}", "search-path lookup <nixpkgs>"),
      ("builtins.getEnv \"HOME\"", "impure builtin getEnv"),
      ("__getEnv \"HOME\"", "impure builtin __getEnv"),
      ("builtins.currentTime", "impure builtin currentTime"),
      ("builtins.nixPath", "impure builtin nixPath"),
      ("builtins.getFlake \"x\"", "impure builtin getFlake"),
      ("builtins.storePath \"x\"", "impure builtin storePath"),
      ("builtins.${\"get\" + \"Env\"} \"HOME\"",
        "dynamic attribute access on builtins"),
      ("let x = \"a\"; in ./dir/${x}", "interpolated path"),
      ("let x = \"a\"; in ./${x}", "interpolated path"),
      ("let x = \"a\"; in ./dir${x}", "interpolated path"),
      ("import ~/overlay.nix", "home-relative path"),
      ("builtins.fetchTarball { url = \"https://e.invalid/x.tgz\"; }",
        "fetcher fetchTarball without a literal fixed hash"),
      ("builtins.fetchTarball \"https://e.invalid/x.tgz\"",
        "fetcher fetchTarball not called with a literal attribute set"),
      ("let h = \"sha256-A=\"; in pkgs.fetchurl { url = \"u\"; hash = h; }",
        "fetcher fetchurl without a literal fixed hash"),
      ("builtins.fetchGit { url = \"u\"; ref = \"main\"; }",
        "fetcher fetchGit without a literal fixed hash"),
      ("builtins.fetchGit { url = \"u\"; rev = \"main\"; }",
        "fetcher fetchGit without a literal fixed hash"),
      ("builtins.fetchurl { url = \"u\"; sha256 = \"\"; }",
        "fetcher fetchurl without a literal fixed hash"),
      ("let f = pkgs.fetchurl; in f { url = \"u\"; }",
        "fetcher fetchurl not called with a literal attribute set"),
      ("map fetchurl srcs", "fetcher fetchurl not called"),
      ("{ src = ./. + \"-sibling\"; }", "'+' after an operand that may be a path"),
      ("import (dirOf ./. + \"/x.nix\")", "path-deriving builtin dirOf"),
      ("import (toString ./. + \"x.nix\")", "path-deriving builtin toString"),
      ("builtins.getAttr \"getEnv\" builtins \"HOME\"", "builtins used as a value"),
      ("import \"/etc/nixos/x.nix\"", "string literal beginning with '/'"),
      ("import ''\n  /etc/nixos/x.nix\n''", "string literal beginning with '/'"),
      ("import ../../../../../../../../../../../../outside.nix",
        "escapes the project root"),
      ("import ../../../outside.nix", "escapes the project root"),
      ("\"unterminated", "unterminated string"),
      ("/* unterminated", "unterminated block comment"),
      ("''unterminated", "unterminated indented string"),
      ("{ a = 1; }}", "unbalanced '}'"),
      ("./trailing/", "trailing slash"),
    ]
    for (text, needle) in cases:
      checkpoint("expression: " & text)
      writeText(expr, text & "\n")
      checkUncacheable(expr, needle)
    when defined(windows):
      writeText(expr, "import /etc/x.nix\n")
      checkUncacheable(expr, "absolute path literal")

  test "a referenced file carrying an uncacheable construct makes the whole closure uncacheable":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    writeText(project / "nix" / "nixpkgs.nix", "import <nixpkgs> {}\n")
    checkUncacheable(expr, "nix/nixpkgs.nix:1:8: search-path lookup")
    # ... and inside a .nix file that only sits in a hashed directory.
    writeText(project / "nix" / "nixpkgs.nix", NixpkgsText)
    writeText(project / "nix" / "tool" / "overlay.nix",
      "builtins.getEnv \"X\"\n")
    checkUncacheable(expr, "nix/tool/overlay.nix:1:10: impure builtin getEnv")

  test "fixed-hash fetchers, formals and inherits stay cacheable (no over-refusal)":
    let fine = [
      "pkgs.fetchurl { url = \"u\"; hash = \"sha256-AAAA\"; }",
      "pkgs.fetchurl { url = \"u\"; sha256 = ''abcd''; }",
      "builtins.fetchGit { url = \"u\"; rev = \"" & repeat('a', 40) & "\"; }",
      "builtins.fetchTree { type = \"git\"; url = \"u\"; narHash = \"sha256-A\"; }",
      "{ stdenv, fetchurl ? null, fetchFromGitHub }: stdenv",
      "let inherit (pkgs) fetchurl fetchzip; in 1",
      "{ fetchurl = x: x; }",
      "fetchurl: fetchurl { url = \"u\"; hash = \"sha256-A\"; }",
      "\"<nixpkgs> builtins.getEnv ~/x ./a/${\"b\"}\"",
      "# import <nixpkgs> builtins.getEnv \"/etc\"\n1",
      "/* <nixpkgs> getEnv fetchTarball \"x\" ~/y */ 1",
      "\"https://example.invalid/a\"",
      "''\n  mkdir -p $out/bin\n  cp /etc/x $out\n''",
    ]
    for text in fine:
      checkpoint("expression: " & text)
      let scan = scanNix(text)
      if scan.refusals.len > 0:
        checkpoint("refused: " & scan.refusals.join("; "))
      check scan.refusals.len == 0

  test "comments and strings add no reference and hide none":
    let src = """
# import ./commented.nix
/* ../../../escape.nix <nixpkgs> ./block-commented.nix */
let
  a = "./in-string.nix";
  b = ''../in-ind-string.nix'';
  c = "$${./dollar-escaped.nix}";
  d = ''$${./ind-dollar.nix}'';
  e = ''''${./ind-escaped.nix}'';
  f = "${./real-in-interp.nix}";
  g = ''${./real-in-ind-interp.nix}'';
  h = "#" + "${./real-after-hash-string.nix}";
  i = /* c */ ./real-after-comment.nix;
  j = "a\"${./real-after-escaped-quote.nix}";
  k = x: x/real-division-is-a-path.nix;
in {}
"""
    check sortedRefs(src) == @["./real-after-comment.nix",
      "./real-after-escaped-quote.nix", "./real-after-hash-string.nix",
      "./real-in-ind-interp.nix", "./real-in-interp.nix",
      "x/real-division-is-a-path.nix"]
    check scanNix(src).refusals.len == 0
    # The same at the key level: a commented or quoted file is not in the
    # closure (editing it moves nothing), a real one is.
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    writeText(expr, src)
    let toolDir = project / "nix" / "tool"
    # Files at exactly the paths the comments and strings spell, resolved as
    # Nix would resolve them had they been path literals.
    let quoted = [toolDir / "commented.nix", toolDir / "block-commented.nix",
      toolDir / "in-string.nix", project / "nix" / "in-ind-string.nix",
      toolDir / "dollar-escaped.nix", toolDir / "ind-dollar.nix",
      toolDir / "ind-escaped.nix"]
    for path in quoted:
      writeText(path, "{ }\n")
    let before = allKeys(expr)
    for path in quoted:
      writeText(path, "{ edited = 1; }\n")
    checkNoneMove(before, allKeys(expr), "commented / quoted names")
    # The real references are absent files: bound as absent, so creating
    # one moves every key.
    let closure = nixExpressionClosure(expr)
    check closure.cacheable
    check closure.entries.filterIt(it.kind == nceMissing).len == 6
    writeText(toolDir / "real-after-comment.nix", "{ }\n")
    checkAllMove(before, allKeys(expr), "real reference created")

  test "a missing referenced file is bound as absent; creating it moves every key":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    writeText(expr, "let o = if builtins.pathExists ./optional.nix " &
      "then import ./optional.nix else {}; in o\n")
    let closure = nixExpressionClosure(expr)
    check closure.cacheable
    check closure.entries.anyIt(it.relativePath == "nix/tool/optional.nix" and
      it.kind == nceMissing)
    let before = allKeys(expr)
    checkNoneMove(before, allKeys(expr), "recomputed")
    writeText(project / "nix" / "tool" / "optional.nix", "{ }\n")
    checkAllMove(before, allKeys(expr), "optional file created")

  test "a junction or link inside the closure is uncacheable":
    let project = makeProject()
    defer:
      removeDirLink(project / "nix" / "tool" / "lnk")
      removeDirLink(project / "nix" / "lnk2")
      removeDir(project)
    let expr = toolExpr(project)
    writeText(project / "nix" / "target" / "x.nix", "{ }\n")
    # A link INSIDE a hashed directory (``src = ./.``).
    check makeDirLink(project / "nix" / "tool" / "lnk",
      project / "nix" / "target")
    checkUncacheable(expr, "link inside a hashed directory: nix/tool/lnk")
    removeDirLink(project / "nix" / "tool" / "lnk")
    check nixExpressionClosure(expr).cacheable
    # A link AS a reference, and as a component of one.
    check makeDirLink(project / "nix" / "lnk2", project / "nix" / "target")
    writeText(expr, "import ../lnk2\n")
    checkUncacheable(expr, "link or junction on the path of nix/lnk2")
    writeText(expr, "import ../lnk2/x.nix\n")
    checkUncacheable(expr, "link or junction on the path of nix/lnk2/x.nix")

  test "no project root, and a reference escaping it, are uncacheable":
    let project = makeProject()
    defer: removeDir(project)
    let expr = toolExpr(project)
    removeDir(project / ".git")
    let closure = nixExpressionClosure(expr)
    check not closure.cacheable
    check "no project root (.git)" in closure.reason
    # A worktree / submodule marks its root with a ``.git`` FILE.
    writeText(project / ".git", "gitdir: elsewhere\n")
    check nixExpressionClosure(expr).cacheable
    writeText(project / "nix" / "tool" / "default.nix",
      "import ../../../escape.nix\n")
    checkUncacheable(expr, "escapes the project root")

  test "the key is taken ONCE per resolution and uncacheable identities are never reused":
    # Path mode resolves the tool from $PATH, so this runs on any host; the
    # use still carries an uncacheable Nix expression, so the identity must
    # be re-resolved on every call and no keyed cache file is written.
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
    # Cacheable first: the second call is a warm hit.
    let r0 = warmBuildCacheCounters.toolIdentityResolves
    discard warmResolveAndWriteIdentity(artifact, outDir, tpmPathOnly)
    discard warmResolveAndWriteIdentity(artifact, outDir, tpmPathOnly)
    check warmBuildCacheCounters.toolIdentityResolves - r0 == 1
    check toSeq(walkFiles(outDir / "tool-identity-cache" / "*.rbtp")).len == 1
    # Uncacheable: every call resolves, warm or cold, and nothing is added
    # under a (nonce) key.
    writeText(expr, "import <nixpkgs> {}\n")
    let r1 = warmBuildCacheCounters.toolIdentityResolves
    discard warmResolveAndWriteIdentity(artifact, outDir, tpmPathOnly)
    discard warmResolveAndWriteIdentity(artifact, outDir, tpmPathOnly)
    # ...and nothing is KEPT in the warm table either: the cacheable entry
    # is dropped with the file it described, and no nonce-keyed entry is
    # added (before, a long-lived process -- the Windows daemon builds
    # in-process -- grew by one identity per build).
    check warmToolIdentityCountForTest() == 0
    forgetWarmBuildCaches()
    discard warmResolveAndWriteIdentity(artifact, outDir, tpmPathOnly)
    check warmBuildCacheCounters.toolIdentityResolves - r1 == 3
    check warmToolIdentityCountForTest() == 0
    check toSeq(walkFiles(outDir / "tool-identity-cache" / "*.rbtp")).len == 1

suite "M7 sibling (6): every workspace expressionFile, classified":

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

  test "the four stdlib expressions are cacheable and bind exactly what they name":
    let exprs = stdlibExpressionFiles()
    check exprs.len == 4
    # The oracle: what each expression names, read off the files by hand.
    #   every one: its own file, and ``import ../nixpkgs.nix``;
    #   stylus additionally ``src = ./.`` (its directory, which holds
    #   ``package.json`` and ``package-lock.json``).
    for expr in exprs:
      let closure = nixExpressionClosure(expr)
      checkpoint(expr & ": " & closure.reason)
      check closure.cacheable
      let dirName = expr.parentDir.extractFilename
      let base = "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/nix/"
      var expected = @[base & "nixpkgs.nix", base & dirName & "/default.nix"]
      if dirName == "stylus-0.64.0":
        expected.add(base & dirName)
      expected.sort()
      check closure.entries.mapIt(it.relativePath) == expected
      check closure.entries.allIt(it.kind != nceMissing)
      check closure.root.toLowerAscii ==
        norm(currentSourcePath().parentDir.parentDir.parentDir)
    check exprs.mapIt(it.parentDir.extractFilename) == @[
      "appimage-runtime-20251108", "appimagetool-1.9.1",
      "python3-with-modules-1.0.0", "stylus-0.64.0"]

  test "the DSL resolves each stdlib expressionFile to the same file":
    var declared: seq[string] = @[]
    for pkg in registeredPackages():
      for nix in pkg.nixProvisioning:
        if nix.expressionFile.len > 0:
          declared.add(norm(nix.expressionFile))
    declared.sort()
    check declared == stdlibExpressionFiles().mapIt(norm(it))

  test "the daemon fixture expression (passed to the daemon directly) is uncacheable":
    let fixture = currentSourcePath().parentDir.parentDir / "fixtures" /
      "nix-daemon-local-flake" / "default.nix"
    check fileExists(fixture)
    let closure = nixExpressionClosure(fixture)
    check not closure.cacheable
    check "impure builtin getFlake" in closure.reason
