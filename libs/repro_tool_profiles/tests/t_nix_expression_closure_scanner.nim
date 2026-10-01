## ``t_nix_expression_closure_scanner`` -- ReproOS-Campaign-Completion M7,
## siblings (6) and (7), at the unit level: the Nix path-reference scanner
## and closure (``nix_expression_closure``) and the executable stat evidence
## (``executable_evidence``), without the CLI.
##
## The scanner is a lexer modelled on Nix's ``lexer.l``. Each case below
## pins one of its rules the way Nix applies it -- string and indented-string
## escapes, comments, longest match between identifiers, numbers, paths,
## search paths and URIs, interpolated and trailing-slash paths, brace
## balance -- and one classification rule that turns a construct into a
## refusal (uncacheable) rather than a dropped reference. The closure cases
## pin what is bound (files, directories hashed whole, absence) and what is
## refused (escapes, links, no root). The evidence cases pin which stat
## fields are compared and the racy window.
##
## Windows only when written (the fixtures are portable; the POSIX stat
## branch and the executable bit are not exercised here).

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, times,
  unittest]

import repro_tool_profiles/executable_evidence
import repro_tool_profiles/nix_expression_closure

const NoRefs: seq[string] = @[]

proc refs(src: string): seq[string] =
  result = scanNix(src).refs.mapIt(it.text)
  result.sort()

proc refused(src: string): string =
  ## The first refusal, or "".
  let scan = scanNix(src)
  if scan.refusals.len > 0: scan.refusals[0] else: ""

template checkRefused(src, needle: string) =
  let why = refused(src)
  if needle notin why:
    checkpoint("source: " & src & "\n  refusal: " & why)
  check needle in why

template checkClean(src: string; expected: seq[string]) =
  let scan = scanNix(src)
  if scan.refusals.len > 0:
    checkpoint("source: " & src & "\n  refused: " & scan.refusals.join("; "))
  check scan.refusals.len == 0
  check refs(src) == expected

proc writeText(path, text: string) =
  createDir(parentDir(path))
  writeFile(path, text)

proc makeRoot(): string =
  result = createTempDir("repro-nix-scan-", "")
  createDir(result / ".git")

suite "nix scanner: strings and comments add no reference and hide none":

  test "double-quoted strings: escapes, $${ and ${":
    checkClean("\"./a.nix\"", NoRefs)
    checkClean("\"\\\"./a.nix\"", NoRefs)
    checkClean("\"\\${./a.nix}\"", NoRefs)            # \$ escapes the dollar
    checkClean("\"$${./a.nix}\"", NoRefs)             # $$ is literal
    checkClean("\"${./a.nix}\"", @["./a.nix"])
    checkClean("\"x\\\\${./a.nix}\"", @["./a.nix"]) # \\ then a real ${
    checkClean("\"$\\n${./a.nix}\"", @["./a.nix"])
    checkClean("\"a$\"", NoRefs)                      # a trailing lone $
    checkClean("\"${\"${./a.nix}\"}\"", @["./a.nix"])

  test "indented strings: ''$, ''', ''\\, $${ and ${":
    checkClean("''./a.nix''", NoRefs)
    checkClean("''''${./a.nix}''", NoRefs)             # ''$ escapes
    checkClean("''$${./a.nix}''", NoRefs)
    checkClean("'''''${./a.nix}''", @["./a.nix"])   # ''' is '' then ${
    checkClean("''''\\${./a.nix}''", NoRefs)           # ''\ escapes $
    checkClean("''${./a.nix}''", @["./a.nix"])
    checkClean("''it's ${./a.nix}''", @["./a.nix"])
    checkClean("''$'${./a.nix}''", @["./a.nix"])

  test "comments":
    checkClean("# ./a.nix\n./b.nix", @["./b.nix"])
    checkClean("/* ./a.nix */ ./b.nix", @["./b.nix"])
    checkClean("/* ** ./a.nix **/ ./b.nix", @["./b.nix"])
    checkClean("\"# not a comment\" ./b.nix", @["./b.nix"])
    checkClean("\"a /* not a comment\" ./b.nix", @["./b.nix"])
    checkClean("\"a */ ./c.nix\" ./b.nix", @["./b.nix"])
    checkClean("''# ${./b.nix}''", @["./b.nix"])
    checkRefused("/* ./a.nix", "unterminated block comment")
    # Block comments do NOT nest (the first ``*/`` closes), and a ``#``
    # comment ends at a lone CR as well as at LF -- both as ``lexer.l``.
    checkClean("/* a /* b */ ./c.nix /* d */", @["./c.nix"])
    checkClean("/* a */ ./c.nix /* b */ ./d.nix", @["./c.nix", "./d.nix"])
    checkClean("# a\r./c.nix", @["./c.nix"])

  test "non-ASCII and control bytes are refused outside strings and comments":
    checkClean("# caf\xC3\xA9\n\"caf\xC3\xA9\" ''\xE2\x80\x94''", NoRefs)
    checkRefused("caf\xC3\xA9", "byte 0xC3 outside a string or comment")
    checkRefused("a \x01 b", "byte 0x01 outside a string or comment")

suite "nix scanner: longest match, as Nix lexes":

  test "paths, identifiers, numbers, URIs and search paths":
    checkClean("a/b", @["a/b"])
    checkClean("x.y", NoRefs)
    checkClean("x.y/z", @["x.y/z"])
    checkClean("1/2", @["1/2"])
    checkClean("1.5/x", @["1.5/x"])
    checkClean("a-b/c", @["a-b/c"])
    checkClean("a+/b", @["a+/b"])
    checkClean("a // b", NoRefs)
    checkClean("a/ b", NoRefs)
    checkClean("./.", @["./."])
    checkClean("../x/../y", @["../x/../y"])
    checkClean("/x/y", @["/x/y"])
    checkClean("https://example.invalid/a/b.nix", NoRefs)
    checkClean("x:y/z.nix", NoRefs)                   # a URI, not a path
    checkClean("x: y/z.nix", @["y/z.nix"])         # a lambda
    checkClean("a < b", NoRefs)
    checkClean("a <= b/c", @["b/c"])
    checkRefused("a <b> c", "search-path lookup <b>")
    checkRefused("<nixpkgs/lib>", "search-path lookup <nixpkgs/lib>")

  test "interpolated, home-relative and trailing-slash paths":
    checkRefused("./a/${x}", "interpolated path")
    checkRefused("./a${x}", "interpolated path")
    checkRefused("./${x}", "interpolated path")
    checkRefused("a/${x}", "interpolated path")
    checkRefused("~/${x}", "home-relative path")
    checkRefused("~/a", "home-relative path ~/a")
    checkRefused("./a/", "path has a trailing slash")

  test "brace balance and termination":
    checkRefused("}", "unbalanced '}'")
    checkRefused("{ a = \"x\"; }}", "unbalanced '}'")
    checkRefused("\"abc", "unterminated string")
    checkRefused("''abc", "unterminated indented string")
    checkRefused("\"${ ./a.nix \"", "unterminated")
    checkRefused("{ a = 1;", "unterminated brace or interpolation")
    checkClean("{ a = { b = ${c}; }; }", NoRefs)

suite "nix scanner: classification":

  test "impure builtins, in either spelling and on any occurrence":
    for name in ["getEnv", "currentTime", "nixPath", "findFile", "getFlake",
                 "storePath", "fetchClosure", "toPath", "exec",
                 "importNative", "nixVersion", "langVersion", "storeDir",
                 "currentSystem", "curPos", "unsafeGetAttrPos"]:
      checkRefused("builtins." & name, "impure builtin " & name)
      checkRefused("__" & name, "impure builtin __" & name)
      checkRefused("inherit (builtins) " & name & ";", "impure builtin " & name)
    # nixpkgs ``lib`` wrappers of ``getEnv``, named in the text.
    checkRefused("pkgs.lib.maybeEnv \"X\" \"d\"", "impure builtin maybeEnv")
    checkRefused("lib.inNixShell", "impure builtin inNixShell")
    # Derivation attributes that take the build out of the sandbox.
    for name in ["__impure", "__noChroot", "__sandboxProfile",
                 "sandboxProfile", "propagatedSandboxProfile",
                 "__impureHostDeps", "impureHostDeps",
                 "__propagatedImpureHostDeps", "__darwinAllowLocalNetworking"]:
      checkRefused("derivation { " & name & " = true; }",
        "derivation attribute " & name)
    checkClean("\"getEnv\"", NoRefs)
    checkRefused("builtins.${\"getEnv\"}", "dynamic attribute access on builtins")
    checkRefused("builtins.\"getEnv\"", "dynamic attribute access on builtins")

  test "fetchers: only a direct call with a literal fixed hash or commit":
    for attr in ["sha256", "sha512", "sha1", "md5", "hash", "narHash",
                 "outputHash"]:
      checkClean("fetchurl { url = \"u\"; " & attr & " = \"x\"; }", NoRefs)
    checkClean("fetchGit { url = \"u\"; rev = \"" & repeat('a', 40) & "\"; }", NoRefs)
    checkClean("fetchGit { url = \"u\"; rev = \"" & repeat('A', 64) & "\"; }", NoRefs)
    checkRefused("fetchGit { url = \"u\"; rev = \"" & repeat('a', 39) & "\"; }",
      "without a literal fixed hash")
    checkRefused("fetchGit { url = \"u\"; rev = \"" & repeat('g', 40) & "\"; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; }", "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; sha256 = \"  \"; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; sha256 = \"${x}\"; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; sha256 = x; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; inherit sha256; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; meta = { sha256 = \"x\"; }; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; a.sha256 = \"x\"; }",
      "without a literal fixed hash")
    # A hash bound INSIDE a nested set is not the fetcher's hash, even when
    # the nested set's own bindings end in ``;`` like the fetcher's do.
    checkRefused("fetchurl { url = \"u\"; meta = { x = 1; sha256 = \"x\"; }; }",
      "without a literal fixed hash")
    checkRefused("fetchurl { url = \"u\"; meta = [ { sha256 = \"x\"; } ]; }",
      "without a literal fixed hash")
    checkRefused("fetchurl rec { url = \"u\"; sha256 = \"x\"; }",
      "not called with a literal attribute set")
    checkRefused("fetchurl \"u\"", "not called with a literal attribute set")
    checkRefused("fetchurl (x)", "not called with a literal attribute set")
    checkRefused("pkgs.fetchurl.override", "not called with a literal attribute set")
    checkRefused("[ fetchurl ]", "not called with a literal attribute set")
    checkRefused("fetchurl", "not called with a literal attribute set")
    checkRefused("__fetchurl \"u\"", "fetcher __fetchurl")
    checkRefused("fetchFromGitHub { owner = \"o\"; repo = \"r\"; rev = \"v1\"; }",
      "fetcher fetchFromGitHub without a literal fixed hash")
    # Not calls: formals, definitions, lambda arguments, inherits.
    checkClean("{ fetchurl, fetchgit ? null }: 1", NoRefs)
    checkClean("{ fetchurl = 1; }", NoRefs)
    checkClean("fetchurl: 1", NoRefs)
    checkClean("let inherit fetchurl; inherit (pkgs) fetchzip fetchgit; in 1", NoRefs)

  test "path arithmetic, and builtins reached by a computed name":
    checkRefused("dirOf ./.", "path-deriving builtin dirOf")
    checkRefused("builtins.dirOf ./.", "path-deriving builtin dirOf")
    checkRefused("__dirOf ./.", "path-deriving builtin __dirOf")
    checkRefused("toString ./.", "path-deriving builtin toString")
    checkRefused("builtins.toString ./.", "path-deriving builtin toString")
    checkRefused("./. + \"-other/x.nix\"", "'+' after an operand that may be a path")
    checkRefused("let d = ./.; in d + \"-x\"", "'+' after an operand")
    checkRefused("(./.) + \"x\"", "'+' after an operand")
    checkRefused("a.b + \"x\"", "'+' after an operand")
    checkRefused("a+b", "'+' after an operand")
    checkClean("\"a\" + \"b\"", NoRefs)
    checkClean("\"a\" + b", NoRefs)
    checkClean("''a'' + \"b\"", NoRefs)
    checkClean("https://e.invalid/x + \"b\"", NoRefs)
    checkClean("1 + 2", NoRefs)
    checkClean("1.5 + 2", NoRefs)
    checkClean("a ++ b", NoRefs)
    checkClean("a // b", NoRefs)
    checkRefused("builtins.getAttr \"getEnv\" builtins", "builtins used as a value")
    checkRefused("let b = builtins; in b.x", "builtins used as a value")
    checkRefused("(builtins)", "builtins used as a value")
    checkRefused("builtins", "builtins used as a value")
    checkClean("with builtins; length [ ]", NoRefs)
    checkClean("let inherit (builtins) length; in 1", NoRefs)
    checkClean("builtins.length [ ]", NoRefs)
    checkClean("builtins.builtins.length [ ]", NoRefs)

  test "a string that may be coerced to an absolute path":
    checkRefused("import \"/etc/x.nix\"", "string literal beginning with '/'")
    checkRefused("\"\\/etc\"", "string literal beginning with '/'")
    checkRefused("''\n   /etc/x''", "string literal beginning with '/'")
    checkRefused("''   \n\t/etc/x''", "string literal beginning with '/'")
    checkClean("\" /etc\"", NoRefs)
    checkClean("''mkdir /etc''", NoRefs)
    checkClean("\"${x}/etc\"", NoRefs)

  test "evaluating callers mark their path argument":
    let scan = scanNix("import ./a; callPackage ./c {}; " &
      "callPackages ./d {}; readFile ./e; import (./g)")
    check scan.refusals.len == 0
    var evaluated: seq[string] = @[]
    for r in scan.refs:
      if r.evaluated:
        evaluated.add(r.text)
    check evaluated == @["./a", "./c", "./d", "./g"]
    check scan.refs.len == 5

  test "an evaluating caller whose target is not a literal is refused":
    # Each of these evaluates ``./h`` -- a file the closure would HASH but,
    # having no ``.nix`` name and no literal caller, never SCAN, so an impure
    # builtin or a reference inside it would go unseen.
    for src in ["let p = ./h; in import p", "let i = import; in i ./h",
                "map import [ ./h ]", "let i = builtins.import; in i ./h",
                "rec { a = ./h; b = import a; }",
                "import (if c then ./a.nix else ./h)",
                "import \"${./d}/h\"", "pkgs.callPackage p { }"]:
      checkRefused(src, "of a computed target")
    checkRefused("scopedImport { } ./h", "scopedImport")
    checkRefused("(x: x.import ./h) { inherit (builtins) import; }",
      "import placed in an attribute set by inherit")
    # A literal target, a fixed fetch, or (callPackage) a function literal.
    checkClean("import (builtins.fetchTarball { url = \"u\"; sha256 = \"x\"; }) { }",
      NoRefs)
    checkClean("import (fetchTarball { url = \"u\"; sha256 = \"x\"; })", NoRefs)
    checkClean("pkgs.callPackage ({ stdenv }: stdenv) { }", NoRefs)
    checkClean("{ import ? null }: 1", NoRefs)

  test "a fetcher escaping as a value: a formal default, a set inherit":
    checkRefused("{ f ? fetchTarball }: f \"u\"",
      "not called with a literal attribute set")
    checkRefused("{ f ? builtins.fetchTarball, x ? 1 }: f \"u\"",
      "not called with a literal attribute set")
    checkRefused("builtins.mapAttrs (n: f: f \"u\") { inherit (builtins) fetchurl; }",
      "fetchurl placed in an attribute set by inherit")
    checkRefused("let s = { inherit (builtins) fetchurl; }; in s.${n} \"u\"",
      "fetchurl placed in an attribute set by inherit")
    checkRefused("\"${builtins.fetchurl}\"", "not called with a literal attribute set")
    # ``fetchTree``'s ``rev`` pins only a git-like input.
    checkRefused("fetchTree { type = \"tarball\"; url = \"u\"; rev = \"" &
      repeat('a', 40) & "\"; }", "without a literal fixed hash")
    checkRefused("fetchTree { url = \"u\"; rev = \"" & repeat('a', 40) & "\"; }",
      "without a literal fixed hash")
    checkClean("fetchTree { type = \"github\"; owner = \"o\"; repo = \"r\"; rev = \"" &
      repeat('a', 40) & "\"; }", NoRefs)

suite "nix closure: what is bound, what is refused":

  test "files, a directory hashed whole, and absences are bound; siblings are not":
    let root = makeRoot()
    defer: removeDir(root)
    writeText(root / "nix" / "pin.nix", "{ }\n")
    writeText(root / "nix" / "t" / "default.nix",
      "let p = import ../pin.nix; o = ./absent.nix; in { src = ./src; }\n")
    writeText(root / "nix" / "t" / "src" / "a.txt", "a\n")
    writeText(root / "nix" / "t" / "src" / "sub" / "b.txt", "b\n")
    writeText(root / "nix" / "sibling.nix", "{ }\n")
    let expr = root / "nix" / "t" / "default.nix"
    let c0 = nixExpressionClosure(expr)
    check c0.cacheable
    check c0.entries.mapIt((it.relativePath, it.kind)) == @[
      ("nix/pin.nix", nceFile), ("nix/t/absent.nix", nceMissing),
      ("nix/t/default.nix", nceFile), ("nix/t/src", nceDirectory)]
    check c0.digest.len == 64
    template moves(body: untyped) =
      let before = nixExpressionClosure(expr).digest
      body
      let after = nixExpressionClosure(expr).digest
      check before != after
    template stays(body: untyped) =
      let before = nixExpressionClosure(expr).digest
      body
      check nixExpressionClosure(expr).digest == before
    moves: writeText(root / "nix" / "pin.nix", "{ a = 1; }\n")
    moves: writeText(root / "nix" / "t" / "src" / "sub" / "b.txt", "B\n")
    moves: writeText(root / "nix" / "t" / "src" / "sub" / "c.txt", "")
    moves: createDir(root / "nix" / "t" / "src" / "empty")
    moves: moveFile(root / "nix" / "t" / "src" / "a.txt",
      root / "nix" / "t" / "src" / "a2.txt")
    moves: writeText(root / "nix" / "t" / "absent.nix", "{ }\n")
    moves: writeText(expr, readFile(expr) & "\n")
    stays: writeText(root / "nix" / "sibling.nix", "{ b = 1; }\n")
    stays: writeText(root / "other.txt", "x\n")
    stays: writeText(root / "nix" / "t" / "unreferenced.txt", "x\n")
    # The key is ``closure-v1:<digest>`` when cacheable, stable.
    check nixExpressionClosureKey(expr) == nixExpressionClosureKey(expr)
    check nixExpressionClosureKey(expr).startsWith("closure-v1:")

  test "a .nix file inside a hashed directory, and an evaluated non-.nix file, are scanned":
    let root = makeRoot()
    defer: removeDir(root)
    let expr = root / "t" / "default.nix"
    writeText(expr, "{ src = ./.; }\n")
    writeText(root / "t" / "inner.nix", "import ../far.nix\n")
    writeText(root / "far.nix", "{ }\n")
    let c = nixExpressionClosure(expr)
    check c.cacheable
    check c.entries.anyIt(it.relativePath == "far.nix")
    writeText(expr, "import ./code.txt\n")
    writeText(root / "t" / "code.txt", "import <nixpkgs>\n")
    check "t/code.txt:1:8: search-path lookup" in nixExpressionClosure(expr).reason
    # Not evaluated, not .nix: bound by content, not scanned.
    writeText(expr, "builtins.readFile ./code.txt\n")
    check nixExpressionClosure(expr).cacheable

  test "a directory expression evaluates its default.nix":
    let root = makeRoot()
    defer: removeDir(root)
    writeText(root / "t" / "default.nix", "import <nixpkgs>\n")
    let c = nixExpressionClosure(root / "t")
    check not c.cacheable
    check "t/default.nix:1:8: search-path lookup" in c.reason

  test "escapes, absolute literals, missing roots and links are refused":
    let root = makeRoot()
    defer: removeDir(root)
    let expr = root / "a" / "default.nix"
    writeText(expr, "import ../../x.nix\n")
    check "escapes the project root" in nixExpressionClosure(expr).reason
    writeText(expr, "import ../x.nix\n")
    check nixExpressionClosure(expr).cacheable
    writeText(expr, "import ../.\n")
    check nixExpressionClosure(expr).cacheable        # the root itself is inside
    writeText(expr, "import ../..\n")
    check "escapes the project root" in nixExpressionClosure(expr).reason
    when defined(windows):
      writeText(expr, "import /x.nix\n")
      check "absolute path literal /x.nix" in nixExpressionClosure(expr).reason
    writeText(expr, "{ }\n")
    removeDir(root / ".git")
    check "no project root (.git)" in nixExpressionClosure(expr).reason
    createDir(root / ".git")
    when defined(windows):
      createDir(root / "target")
      let made = execCmdEx("cmd /c mklink /J " &
        quoteShell(root / "a" / "j") & " " & quoteShell(root / "target"))
      check made.exitCode == 0
      writeText(expr, "import ./j\n")
      check "link or junction on the path of a/j" in
        nixExpressionClosure(expr).reason
      writeText(expr, "{ src = ./.; }\n")
      check "link inside a hashed directory: a/j" in
        nixExpressionClosure(expr).reason
      discard execCmdEx("cmd /c rmdir " & quoteShell(root / "a" / "j"))
      check nixExpressionClosure(expr).cacheable

  test "an uncacheable key is a fresh nonce every time":
    let root = makeRoot()
    defer: removeDir(root)
    let expr = root / "default.nix"
    writeText(expr, "import <nixpkgs>\n")
    let a = nixExpressionClosureKey(expr)
    let b = nixExpressionClosureKey(expr)
    check a.startsWith("uncacheable:")
    check a != b
    check nixExpressionClosure(expr).digest.len == 0

suite "executable evidence":

  test "size, mtime, change time and file identity are recorded and compared":
    let dir = createTempDir("repro-evidence-", "")
    defer: removeDir(dir)
    let path = dir / "tool.bin"
    writeFile(path, repeat('a', 100))
    let e0 = statExecutable(path)
    check e0.ok
    check e0.evidence.recorded
    check e0.evidence.size == 100
    check e0.evidence.mtimeNs > 0
    check e0.evidence.fileIdLow != 0 or e0.evidence.fileIdHigh != 0
    when defined(windows):
      check e0.evidence.ctimeNs > 0
      check e0.evidence.volume != 0
    check sameFileState(e0.evidence, statExecutable(path).evidence)
    check not statExecutable(dir / "absent").ok
    check not sameFileState(ExecutableEvidence(), ExecutableEvidence())
    # Each field alone breaks the sameness.
    for field in 0 .. 5:
      var other = e0.evidence
      case field
      of 0: other.size += 1
      of 1: other.mtimeNs += 1
      of 2: other.ctimeNs += 1
      of 3: other.volume += 1
      of 4: other.fileIdHigh += 1
      else: other.fileIdLow += 1
      check not sameFileState(e0.evidence, other)
    var stamped = e0.evidence
    stamped.recordedAtNs = 12345
    check sameFileState(e0.evidence, stamped)   # not a file field
    # An in-place rewrite with the mtime put back moves the change time.
    let mtime = getLastModificationTime(path)
    sleep(20)
    writeFile(path, repeat('b', 100))
    setLastModificationTime(path, mtime)
    let e1 = statExecutable(path).evidence
    check e1.mtimeNs == e0.evidence.mtimeNs
    check e1.size == e0.evidence.size
    check (e1.fileIdLow, e1.fileIdHigh) == (e0.evidence.fileIdLow,
      e0.evidence.fileIdHigh)
    when defined(windows):
      check e1.ctimeNs != e0.evidence.ctimeNs
    check not sameFileState(e0.evidence, e1)
    # A replacement moves the file identity.
    removeFile(path)
    writeFile(path, repeat('b', 100))
    setLastModificationTime(path, mtime)
    let e2 = statExecutable(path).evidence
    check (e2.fileIdLow, e2.fileIdHigh) != (e1.fileIdLow, e1.fileIdHigh)

  test "the racy window is measured from the later of mtime and change time":
    var e = ExecutableEvidence(recorded: true, mtimeNs: 10_000_000_000,
      ctimeNs: 5_000_000_000)
    e.recordedAtNs = 10_000_000_000 + RacyWindowNs - 1
    check e.racy
    e.recordedAtNs = 10_000_000_000 + RacyWindowNs
    check not e.racy
    e.mtimeNs = 1_000_000_000
    e.ctimeNs = 10_000_000_000
    e.recordedAtNs = 10_000_000_000 + RacyWindowNs - 1
    check e.racy
    e.recordedAtNs = 9_000_000_000     # file times in the future
    check e.racy
    check RacyWindowNs == 2_000_000_000
