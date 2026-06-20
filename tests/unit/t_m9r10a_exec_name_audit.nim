## DSL-port M9.R.10a — exec-name audit.
##
## Asserts every ``nativeBuildDeps`` / ``buildDeps`` entry across the
## source-recipe corpus resolves to either (a) a sibling source recipe
## at ``recipes/packages/source/<name>/repro.nim`` OR (b) a stdlib
## package at ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/``
## that declares a ``package <name>:`` header.
##
## This regression test surfaces exec-name mismatches the M9.R.9 / R.10a
## smokes hit at run time: e.g. the meson recipe declaring
## ``"python >=3.8"`` while the stdlib registers the package as
## ``python3``. The audit walks the file system at test time so future
## recipe additions are covered without re-touching this file.
##
## On failure the test prints a list of ``(recipe, dep)`` tuples that
## did not resolve. Two remediation paths:
##
##   * Rename the recipe's dep entry to match the canonical stdlib /
##     sibling-recipe name (e.g. ``"python"`` → ``"python3"``).
##   * Add a stub stdlib package at
##     ``libs/repro_dsl_stdlib/.../packages/<name>.nim`` registering the
##     name + a provisioning channel.

import std/[algorithm, os, sets, strutils, tables, unittest]

const ReproBuildRoot {.strdefine.} = ""

proc reproRoot(): string =
  if ReproBuildRoot.len > 0:
    return ReproBuildRoot
  # Walk up from the test source directory until we see ``recipes/``.
  var dir = currentSourcePath().parentDir
  for _ in 0 .. 8:
    if dirExists(dir / "recipes" / "packages" / "source"):
      return dir
    dir = dir.parentDir
  # Fallback to cwd.
  result = getCurrentDir()

proc walkStdlibPackages(dirpath: string; sink: var HashSet[string]) =
  for kind, path in walkDir(dirpath):
    case kind
    of pcDir, pcLinkToDir:
      walkStdlibPackages(path, sink)
    of pcFile, pcLinkToFile:
      if not path.endsWith(".nim"):
        continue
      var content = ""
      try:
        content = readFile(path)
      except IOError, OSError:
        continue
      # Parse ``^\s*package\s+(?:`name`|name)\s*:`` headers across the
      # whole file. Nim doesn't ship a regex stdlib by default so we
      # walk lines + handle the two header shapes by hand.
      for line in content.splitLines():
        let stripped = line.strip(leading = true, trailing = false)
        if not stripped.startsWith("package "):
          continue
        var rest = stripped[len("package ") .. ^1].strip()
        if rest.len == 0:
          continue
        var name = ""
        if rest[0] == '`':
          let close = rest.find('`', 1)
          if close < 0:
            continue
          name = rest[1 ..< close]
          rest = rest[close + 1 .. ^1].strip()
        else:
          var idx = 0
          while idx < rest.len and
              (rest[idx].isAlphaNumeric or rest[idx] == '_'):
            inc idx
          name = rest[0 ..< idx]
          rest = rest[idx .. ^1].strip()
        if rest.len > 0 and rest[0] == ':':
          if name.len > 0:
            sink.incl(name)

proc collectSiblingRecipes(root: string): HashSet[string] =
  result = initHashSet[string]()
  let srcDir = root / "recipes" / "packages" / "source"
  for kind, path in walkDir(srcDir):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    if fileExists(path / "repro.nim"):
      result.incl(extractFilename(path))

type DepEntry = tuple[recipe, kind, name: string]

proc collectRecipeDeps(root: string): seq[DepEntry] =
  result = @[]
  let srcDir = root / "recipes" / "packages" / "source"
  for kind, path in walkDir(srcDir):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let recipe = extractFilename(path)
    let manifest = path / "repro.nim"
    if not fileExists(manifest):
      continue
    var content = ""
    try:
      content = readFile(manifest)
    except IOError, OSError:
      continue
    let lines = content.splitLines()
    var inKind = ""
    var baseIndent = 0
    for line in lines:
      let stripped = line.strip(leading = true, trailing = false)
      let indent = line.len - stripped.len
      # Detect entry into nativeBuildDeps: / buildDeps: blocks. When we
      # match a header here we ``continue`` the outer loop so the same
      # line is not re-interpreted as a dep entry (which would
      # immediately close the block on the same iteration since
      # ``indent <= baseIndent``).
      block headerCheck:
        if stripped.len == 0: break headerCheck
        if not stripped.endsWith(":"): break headerCheck
        let headerEnd = stripped.find(':')
        if headerEnd <= 0: break headerCheck
        let head = stripped[0 ..< headerEnd]
        var ok = head.len > 0
        for ch in head:
          if not (ch.isAlphaNumeric or ch == '_'):
            ok = false
            break
        if not ok: break headerCheck
        if head notin ["nativeBuildDeps", "buildDeps"]: break headerCheck
        let tail = stripped[headerEnd + 1 .. ^1].strip()
        if tail.len > 0 and not tail.startsWith("##"): break headerCheck
        inKind = head
        baseIndent = indent
      # ``continue`` if we just entered a block — the header line itself
      # is not a dep entry. We check by comparing what's in ``inKind``
      # to a sentinel: if the just-set ``inKind`` matches the head we
      # entered on THIS line, skip the rest.
      if inKind.len > 0 and indent == baseIndent and
          stripped.endsWith(":") and
          (stripped.startsWith("nativeBuildDeps") or
            stripped.startsWith("buildDeps")):
        continue
      if inKind.len > 0:
        if stripped.len == 0 or stripped.startsWith("##"):
          continue
        if indent > baseIndent:
          if stripped.len >= 2 and stripped[0] == '"':
            let close = stripped.find('"', 1)
            if close > 0:
              let raw = stripped[1 ..< close]
              # Extract leading bare identifier (strip version
              # constraint like ``" >=3.8"``).
              var idx = 0
              while idx < raw.len and
                  (raw[idx].isAlphaNumeric or raw[idx] in {'_','+','.','-'}):
                inc idx
              if idx > 0:
                let depName = raw[0 ..< idx]
                result.add((recipe: recipe, kind: inKind, name: depName))
              # Otherwise: not a recognised dep entry — close out the
              # block so we don't keep mis-attributing trailing lines.
              continue
          # A non-string indented line ends the block (e.g. nested
          # ``versions:`` sub-block in unusual recipes).
          inKind = ""
          baseIndent = 0
        else:
          inKind = ""
          baseIndent = 0

proc canonicalize(name: string): string =
  # Map ``a-b`` → ``a_b`` so stdlib files whose backtick header is the
  # hyphenated name (e.g. ``package `pkg-config`:``) AND files whose
  # filename is the underscore form (``pkg_config.nim``) both resolve.
  result = name.replace('-', '_')

suite "M9.R.10a exec-name audit":

  test "test_m9r10a_all_native_and_build_deps_resolve_to_sibling_or_stdlib":
    let root = reproRoot()
    let siblings = collectSiblingRecipes(root)
    var stdlibPkgs = initHashSet[string]()
    walkStdlibPackages(
      root / "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" /
        "packages", stdlibPkgs)
    let deps = collectRecipeDeps(root)
    check siblings.len >= 80
    check stdlibPkgs.len >= 100
    check deps.len > 0

    var unresolved: seq[DepEntry] = @[]
    for dep in deps:
      let canon = canonicalize(dep.name)
      if dep.name in siblings or canon in siblings:
        continue
      if dep.name in stdlibPkgs or canon in stdlibPkgs:
        continue
      unresolved.add(dep)

    if unresolved.len > 0:
      var report = "M9.R.10a exec-name audit: " & $unresolved.len &
        " unresolved nativeBuildDeps/buildDeps entries:\n"
      unresolved.sort(proc(a, b: DepEntry): int =
        if a.recipe == b.recipe: cmp(a.name, b.name)
        else: cmp(a.recipe, b.recipe))
      for u in unresolved:
        report.add("  " & u.recipe & "." & u.kind & " -> \"" & u.name &
          "\" (no sibling recipe at recipes/packages/source/" & u.name &
          "/ AND no stdlib package at libs/repro_dsl_stdlib/.../packages/" &
          u.name & ".nim)\n")
      checkpoint(report)
    check unresolved.len == 0

  test "test_m9r10a_meson_recipe_uses_canonical_python3_name":
    # Specific pin from the M9.R.10a brief — the meson recipe used to
    # declare ``"python >=3.8"`` against the ``python3`` stdlib package.
    # This pin guards the rename so future re-harvests of the meson
    # recipe don't regress it.
    let root = reproRoot()
    let mesonRecipe = root / "recipes" / "packages" / "source" / "meson" /
      "repro.nim"
    check fileExists(mesonRecipe)
    let content = readFile(mesonRecipe)
    check content.contains("\"python3 >=3.8\"")
    # Must NOT contain the bare ``"python "`` form in a dep block — the
    # rename is the load-bearing fix.
    check not content.contains("\"python >=3.8\"")

  test "test_m9r10a_python3_resolves_to_stdlib_package":
    # python3's stdlib package was the renamed target. Verify the audit
    # walker actually sees it.
    let root = reproRoot()
    var stdlibPkgs = initHashSet[string]()
    walkStdlibPackages(
      root / "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" /
        "packages", stdlibPkgs)
    check "python3" in stdlibPkgs

  test "test_m9r10a_pkg_config_resolves_via_backtick_stdlib_header":
    # ``pkg-config`` is registered with a backtick-quoted header (``package
    # `pkg-config`:``) in the stdlib. The walker must recognise it.
    let root = reproRoot()
    var stdlibPkgs = initHashSet[string]()
    walkStdlibPackages(
      root / "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" /
        "packages", stdlibPkgs)
    check "pkg-config" in stdlibPkgs

  test "test_m9r10a_sibling_recipes_cover_renamed_targets":
    # The four rename targets (glib→glib2, libdbus→dbus, libssl→openssl,
    # wayland-scanner→wayland) all resolve via sibling recipes; pin the
    # sibling presence so a recipe rename doesn't silently break.
    let root = reproRoot()
    let siblings = collectSiblingRecipes(root)
    check "glib2" in siblings
    check "dbus" in siblings
    check "openssl" in siblings
    check "wayland" in siblings
