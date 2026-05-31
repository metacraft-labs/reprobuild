## Scoop manifest -> ``VersionedProvisioning`` translator (M66).
##
## Reads a single ``<app>.json`` Scoop manifest and emits a
## ``HarvestResult`` carrying either a populated
## ``VersionedProvisioning`` value plus zero or more *diagnostics*
## (warnings the operator should see but that did not abort the
## translation), or — if the manifest is unusable for any reason —
## an error-only result.
##
## The Scoop manifest format is informally documented at
## https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests; the
## fields this translator honors:
##
##   * ``version`` — top-level semver pin.
##   * Top-level ``url`` (string|seq) + ``hash`` (string|seq) —
##     architecture-agnostic download (the first url/hash pair wins;
##     additional ones are advisory, e.g. helper archives — see
##     pkg-config). Treated as ``(pcAny, poWindows)``.
##   * ``architecture.64bit`` / ``architecture.arm64`` — per-cpu
##     download slices. ``32bit`` is intentionally ignored (M63 schema
##     does not model x86-only Windows builds — adding ``pcX86`` is a
##     future-milestone decision and adding entries for it now would
##     produce silently-broken records).
##   * ``extract_dir`` — inner-dir to flatten; may also be a sequence
##     paired with multi-element ``url``.
##   * ``bin`` — string | seq | seq-of-seq[2]. The seq-of-seq form is
##     Scoop's rename-pair shape ([exe, alias]); we keep the first
##     element (the real exe) and drop the alias because reprobuild's
##     launcher bypasses Scoop's shim layer.
##   * ``installer`` — presence flips ``install_method`` to
##     ``imInstallerSilent``; ``installer.args`` becomes
##     ``installer_args``. A heuristic default is supplied when the
##     manifest omits ``args``.
##   * ``env_set`` — flat string-string table; ``$dir`` is rewritten
##     to ``${prefix}`` (reprobuild's substitution shape).
##   * ``archive_format`` — inferred from URL extension.
##
## Fields outside this list (``pre_install``, ``post_install``,
## ``shortcuts``, ``persist``, ``notes``, ``checkver``,
## ``autoupdate``, ``uninstaller``, ``suggest``, ``license``,
## ``description``, ``homepage``) are deliberately discarded — they
## are Scoop-specific lifecycle hooks that reprobuild's catalog
## schema does not (yet) model. The harvester is a *catalog-author*
## tool — operators who need any of these can hand-edit the emitted
## ``<tool>.nim`` afterwards.
##
## **M67 extension — bin_relpath synthesis from env_add_path.** Several
## Scoop manifests (maven, elixir, ruby, swift, …) declare no ``bin``
## field and rely on ``env_add_path`` instead — Scoop's launcher
## prepends the listed sub-directories to ``%PATH%`` so users invoke
## the binaries by name. ``validateVersionedProvisioning`` requires
## at least one ``bin_relpath`` entry for ``imExtract`` / installer
## records, so the M67 bulk harvest extends ``parseScoopManifest``
## with an optional ``binDefaults`` map keyed by app name. When
## ``bin`` is empty and a default list is supplied, each entry is
## prepended with each ``env_add_path`` segment to synthesize the
## ``bin_relpath`` array (e.g. ``env_add_path = "bin"`` +
## ``binDefaults["maven"] = @["mvn.cmd", "mvn"]`` yields
## ``bin_relpath = @["bin/mvn.cmd", "bin/mvn"]``). This keeps the
## emitter idempotent and avoids hand-edited drift after each
## re-harvest.

import std/[algorithm, json, strutils, tables]
import repro_dsl_stdlib/packages_schema

type
  DiagnosticKind* = enum
    ## Stable diagnostic identifiers per the M66 spec. Operators key
    ## off the kind when triaging harvest failures; the message is
    ## free-form context.
    dkBinRenameIgnored = "HBinRenameIgnored"
    dkInstallerArgsUnknown = "HInstallerArgsUnknown"
    dkManifestNoHash = "HManifestNoHash"
    dkManifestNoUrl = "HManifestNoUrl"
    dkManifest32BitIgnored = "HManifest32BitIgnored"
    dkUnknownArchitecture = "HUnknownArchitecture"
    dkHashAlgorithmUnsupported = "HHashAlgorithmUnsupported"
    dkHashAlgorithmWeak = "HHashAlgorithmWeak"
      ## M1 (Realize-Closure spec): emitted when the Scoop manifest
      ## ships a ``sha1`` hash. The schema accepts sha1 under the M1
      ## extension; this diagnostic is informational (does NOT fail
      ## the parse) and asks the operator to bump to ``sha256`` if
      ## upstream provides it. ``md5`` continues to be rejected via
      ## ``dkHashAlgorithmUnsupported``.
    dkArchiveFormatUnknown = "HArchiveFormatUnknown"
    # M3 (Realize-Closure-And-Catalog-Expansion spec) — residual 7z
    # family classification.
    dkSevenZipSfx = "HSevenZipSfx"
      ## Recognized a 7z-SFX shape: the manifest's URL ends in
      ## ``.7z.exe`` OR the URL has a Scoop ``#/dl.7z`` rename suffix
      ## paired with a ``.exe`` upstream path AND no ``installer``
      ## block — i.e. a self-extracting executable whose payload is a
      ## 7z stream. Set ``archive_format = afSevenZipSfx``.
    dkNested7z = "HNested7z"
      ## The manifest's ``pre_install`` block contains an
      ## ``Expand-7zArchive`` (or ``Expand-7ZipArchive``) invocation
      ## paired with a corresponding ``Remove-Item *.7z`` cleanup —
      ## i.e. the upstream archive contains additional 7z files that
      ## need recursive extraction. Set the platform's ``nested_7z``
      ## flag.
    dkPreInstallAllowlistEntry = "HPreInstallAllowlistEntry"
      ## Recognized a Scoop ``pre_install`` line that matches the
      ## cakBuiltin allowlist; translated into a structured
      ## ``PreInstallAction``.
    dkPreInstallUnrecognized = "HPreInstallUnrecognized"
      ## A ``pre_install`` line that escaped the cakBuiltin allowlist;
      ## captured verbatim in the slice's
      ## ``pre_install_unrecognized`` for the realize loop to surface
      ## as a ``WPreInstallUnrecognized`` warning at apply time.
    dkPreInstallSkippedAllRecognized = "HPreInstallSkippedAllRecognized"
      ## The whole ``pre_install`` block was a noop (e.g. just
      ## comments / whitespace); no actions emitted.
    # M4 (Realize-Closure-And-Catalog-Expansion spec) — Windows
    # installer family classification.
    dkInstallMethodMsi = "HInstallMethodMsi"
      ## The manifest's primary download is an ``.msi`` URL (or the
      ## inferred ``archive_format`` is ``afInstallerMsi``); the
      ## harvester emits ``install_method = imInstallerMsi`` so the
      ## cakBuiltin realize loop dispatches through the M4 dark.exe
      ## extractor (vs M3's NSIS imInstallerSilent path).
    dkInstallMethodInnoSetup = "HInstallMethodInnoSetup"
      ## The manifest carries ``"innosetup": true`` (regardless of
      ## whether an ``installer:`` block is present); the harvester
      ## emits ``install_method = imInstallerInnoSetup`` so the
      ## cakBuiltin realize loop dispatches through the M4 innounp.exe
      ## extractor. Required for the freepascal/fpc shape per M1's
      ## Outstanding Task note.
    dkInstallMethodNsisBundle = "HInstallMethodNsisBundle"
      ## The manifest's ``installer.script`` block carries an
      ## ``Expand-DarkArchive`` / ``Expand-MsiArchive`` pattern — i.e.
      ## the outer ``.exe`` is an NSIS bundle wrapping inner MSIs
      ## (the python3 + swift shape). The harvester emits
      ## ``install_method = imInstallerNsisBundle`` so the cakBuiltin
      ## realize loop dispatches through the M4 NSIS-unwrap + per-MSI
      ## dark extractor.
    dkInstallerScriptAllowlistEntry = "HInstallerScriptAllowlistEntry"
      ## A line inside an ``installer.script`` block matched the M4
      ## allowlist (Expand-DarkArchive / Expand-MsiArchive /
      ## Expand-InnoArchive); translated into a structured
      ## ``PreInstallAction``.
    dkInstallerScriptUnrecognized = "HInstallerScriptUnrecognized"
      ## A line inside an ``installer.script`` block did NOT match the
      ## M4 allowlist; captured verbatim in
      ## ``pre_install_unrecognized``.
    # M5 (Realize-Closure-And-Catalog-Expansion spec) — Scoop-style
    # launcher emit recognition.
    dkLauncherEmitRecognized = "HLauncherEmitRecognized"
      ## The harvester recognized a Scoop ``pre_install`` PowerShell
      ## block that synthesizes a .phar / .jar / wrapped-script launcher
      ## (composer's ``& php (Join-Path $PSScriptRoot "composer.phar")
      ## @args`` shape, gradle's ``& java -jar ...`` shape, etc.) and
      ## translated it to a ``launcher_emit`` slice instead of dropping
      ## the lines into ``pre_install_unrecognized``. Informational —
      ## does not fail the parse. The matched pattern is closed-set;
      ## arbitrary pre_install PowerShell continues to land in
      ## ``pre_install_unrecognized``.

  Diagnostic* = object
    kind*: DiagnosticKind
    app*: string       ## the manifest's tool name (e.g. "ripgrep")
    detail*: string    ## human-readable context

  ParsedManifest* = object
    ## The parser's output. A manifest with *any* fatal problem
    ## (no hash, no URL, no platform entries) yields ``ok = false``
    ## and an empty ``entry``. Non-fatal issues populate
    ## ``diagnostics`` regardless.
    ok*: bool
    app*: string
    entry*: VersionedProvisioning
    diagnostics*: seq[Diagnostic]

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc extractDirAt(node: JsonNode; index: int): string =
  ## ``extract_dir`` may be a single string OR an array (one entry
  ## per URL in the matching ``url`` array). Return the entry at
  ## ``index`` from an array form; for a string form return it for
  ## any index (the convention: a single ``extract_dir`` applies to
  ## the first/only download).
  if node.isNil: return ""
  case node.kind
  of JString:
    if index == 0: node.getStr() else: ""
  of JArray:
    if index >= 0 and index < node.len and node[index].kind == JString:
      node[index].getStr()
    else: ""
  else: ""

proc splitHash(raw: string): tuple[algo: string; digest: string] =
  ## Scoop encodes the digest as either bare hex (sha256 default) or
  ## ``<algo>:<hex>`` (sha512: / sha256: / md5: / sha1: / etc.).
  ## Return a normalized (algo, digest) tuple. ``algo`` is lower-case;
  ## empty input yields ``("", "")``.
  ##
  ## M1 (Realize-Closure spec): a bare-hex digest of length exactly 40
  ## is treated as ``sha1`` (a few Scoop manifests like ``freepascal``
  ## ship the 40-char hex without an explicit prefix). The bare 64-char
  ## case continues to mean sha256; the bare 128-char case means sha512.
  if raw.len == 0:
    return ("", "")
  let idx = raw.find(':')
  if idx < 0:
    case raw.len
    of 40: return ("sha1", raw)
    of 128: return ("sha512", raw)
    else: return ("sha256", raw)  # bare hex defaults to sha256 by
                                  # Scoop convention (including 64-char)
  let prefix = raw[0 ..< idx].toLowerAscii()
  let rest = raw[idx + 1 .. ^1]
  (prefix, rest)

proc extensionForFormatSniff(url: string): string =
  ## Returns the URL substring whose extension is the source of
  ## truth for archive_format. Scoop's ``#/<filename>`` rename
  ## suffix takes precedence (it's the name scoop actually saves the
  ## file as — e.g. ``otp_win64.exe#/dl.7z`` is downloaded as
  ## ``dl.7z`` and extracted as a 7z, despite the URL's ``.exe``
  ## extension being misleading). ``?query`` is otherwise stripped.
  var s = url
  let hash = s.find('#')
  if hash >= 0:
    # Anything after #/ is the rename filename — use IT to sniff the
    # extension. If the suffix has no path slash we still treat it
    # as the new filename.
    let rename = s[hash + 1 .. ^1]
    let renameClean = if rename.startsWith("/"): rename[1 .. ^1] else: rename
    if renameClean.len > 0:
      s = renameClean
    else:
      s = s[0 ..< hash]
  let q = s.find('?')
  if q >= 0: s = s[0 ..< q]
  s

proc inferArchiveFormat(url: string; hasInstaller: bool):
    tuple[fmt: ArchiveFormat; known: bool] =
  ## Match in longest-suffix-first order so ``.tar.gz`` wins over
  ## ``.gz``. ``hasInstaller`` short-circuits to NSIS/MSI for
  ## installer manifests with a ``.exe`` / ``.msi`` URL.
  ##
  ## M3 (Realize-Closure-And-Catalog-Expansion spec) — 7z-SFX
  ## detection: an upstream URL ending in ``.7z.exe`` (the canonical
  ## ip7z / Git-for-Windows SFX naming) classifies as
  ## ``afSevenZipSfx``. The Scoop ``#/dl.7z`` rename trick is already
  ## handled by ``extensionForFormatSniff`` collapsing the rename
  ## suffix into the format-sniffed extension — so an upstream
  ## ``...some-installer.exe#/dl.7z`` lands here as ``.7z`` and
  ## dispatches to plain ``afSevenZip`` even though the upstream URL's
  ## extension is ``.exe``. We probe the *original* URL for the
  ## ``.7z.exe`` shape BEFORE the rename collapse so that
  ## genuine-SFX-without-rename is correctly classified.
  let originalLower = url.toLowerAscii()
  # Probe the raw URL (before #-suffix stripping) for the .7z.exe shape.
  # ``erlang/git/ruby`` typically use ``...XXX.exe#/dl.7z`` (already
  # sniffed as .7z) → afSevenZip. A bare ``...XXX.7z.exe`` (no rename
  # suffix) → afSevenZipSfx.
  let hashIdx = originalLower.find('#')
  let urlNoHash =
    if hashIdx >= 0: originalLower[0 ..< hashIdx] else: originalLower
  let qIdx = urlNoHash.find('?')
  let urlNoQuery =
    if qIdx >= 0: urlNoHash[0 ..< qIdx] else: urlNoHash
  if urlNoQuery.endsWith(".7z.exe") and not hasInstaller:
    return (afSevenZipSfx, true)
  let clean = extensionForFormatSniff(url).toLowerAscii()
  # Plain HTML pages or weird extensions fall through to afRaw.
  if clean.endsWith(".tar.gz") or clean.endsWith(".tgz"):
    return (afTarGz, true)
  if clean.endsWith(".tar.xz") or clean.endsWith(".txz"):
    return (afTarXz, true)
  if clean.endsWith(".tar.bz2") or clean.endsWith(".tbz2"):
    return (afTarBz2, true)
  if clean.endsWith(".tar.zst") or clean.endsWith(".tzst") or
     clean.endsWith(".pkg.tar.zst"):
    return (afTarZst, true)
  if clean.endsWith(".7z"):
    return (afSevenZip, true)
  if clean.endsWith(".zip"):
    return (afZip, true)
  if clean.endsWith(".msi"):
    return (afInstallerMsi, true)
  if clean.endsWith(".exe"):
    if hasInstaller:
      return (afInstallerNsis, true)
    # An ``.exe`` without an installer block is normally a single-
    # binary download (``afRaw``).
    return (afRaw, true)
  (afRaw, false)

proc installerArgsFor(installerNode: JsonNode; archiveFmt: ArchiveFormat):
    tuple[args: seq[string]; unknown: bool] =
  ## Pull ``installer.args`` (string | seq[string]) or fall back to a
  ## sensible default. Returns ``unknown = true`` when neither path
  ## yields a usable args list so the caller can emit
  ## ``HInstallerArgsUnknown``.
  if not installerNode.isNil and installerNode.kind == JObject:
    if installerNode.hasKey("args"):
      let argsNode = installerNode["args"]
      case argsNode.kind
      of JString:
        # Scoop allows a single-string shell-quoted args field
        # (``"-sasl"``, ``"/S /D=$dir"``). Split on whitespace as a
        # first approximation — operators can hand-fix exotic
        # quoting after the harvest.
        let s = argsNode.getStr().strip()
        if s.len > 0:
          return (s.splitWhitespace(), false)
      of JArray:
        var args: seq[string] = @[]
        for it in argsNode.items:
          if it.kind == JString: args.add(it.getStr())
        if args.len > 0:
          return (args, false)
      else: discard
  # Heuristic defaults.
  case archiveFmt
  of afInstallerMsi:
    (@["/quiet", "/norestart"], false)
  of afInstallerNsis:
    (@["/S"], false)
  else:
    # Caller had no installer-shaped archive_format yet asked for
    # args — leave the caller to decide. We mark unknown so the
    # diagnostic is emitted.
    (newSeq[string](), true)

proc envAddPathsOf(node: JsonNode): seq[string] =
  ## Translate the ``env_add_path`` field (string OR array of strings)
  ## to a flat list of sub-directory relpaths. Returns an empty seq
  ## if the field is missing / malformed.
  ##
  ## Scoop separator is backslash on disk; we normalize to forward
  ## slashes so the harvester's synthesized ``bin_relpath`` mirrors
  ## the JDK reference (``bin/javac.exe``).
  if node.isNil: return @[]
  case node.kind
  of JString:
    let s = node.getStr().strip()
    if s.len > 0: @[s.replace("\\", "/")]
    else: @[]
  of JArray:
    var outDirs: seq[string] = @[]
    for child in node.items:
      if child.kind == JString:
        let s = child.getStr().strip()
        if s.len > 0: outDirs.add(s.replace("\\", "/"))
    outDirs
  else: @[]

proc synthesizeBinRelpaths(envAddPaths, binDefaults: openArray[string]):
    seq[string] =
  ## Synthesize a ``bin_relpath`` list by prepending every
  ## ``env_add_path`` directory to every ``binDefaults`` filename. If
  ## ``env_add_path`` is empty, fall back to the filenames as-is
  ## (root-of-prefix install layout, e.g. Zig).
  if binDefaults.len == 0: return @[]
  if envAddPaths.len == 0:
    var out0: seq[string] = @[]
    for b in binDefaults: out0.add(b)
    return out0
  var combined: seq[string] = @[]
  for dir in envAddPaths:
    # M68 refinement: also strip the ``.`` (current-dir marker) — Scoop
    # manifests like nodejs use ``env_add_path: ["bin", "."]`` to surface
    # both the persist subdir AND the prefix root. ``"."`` should
    # synthesize ``<binary>`` (root-relative) rather than ``./<binary>``,
    # matching the convention the rest of the catalog uses (Zig, Just).
    let trimmed = dir.strip(chars = {'/', '\\', '.'})
    for b in binDefaults:
      if trimmed.len == 0:
        combined.add(b)
      else:
        combined.add(trimmed & "/" & b)
  combined

proc binRelpathsOf(node: JsonNode; app: string; diags: var seq[Diagnostic]):
    seq[string] =
  ## Translate the ``bin`` field to a flat list of relpaths.
  ##
  ## Scoop accepts:
  ##   * ``"rg.exe"`` — single string.
  ##   * ``["bin/foo.exe", "bin/bar.exe"]`` — flat list.
  ##   * ``[["win_bison.exe", "bison"], ["win_flex.exe", "flex"]]`` —
  ##     rename pairs (``[exe, alias]``).
  ##
  ## We keep ``exe`` and drop ``alias`` because reprobuild's launcher
  ## doesn't need Scoop's shim renames. The dropped alias is recorded
  ## as a diagnostic so the operator knows what was discarded.
  if node.isNil: return @[]
  case node.kind
  of JString:
    @[node.getStr()]
  of JArray:
    var outPaths: seq[string] = @[]
    for child in node.items:
      case child.kind
      of JString: outPaths.add(child.getStr())
      of JArray:
        if child.len >= 1 and child[0].kind == JString:
          outPaths.add(child[0].getStr())
          if child.len >= 2 and child[1].kind == JString:
            diags.add(Diagnostic(
              kind: dkBinRenameIgnored,
              app: app,
              detail: "dropped alias '" & child[1].getStr() &
                "' for bin '" & child[0].getStr() & "'"))
      else: discard
    outPaths
  else: @[]

## ---------------------------------------------------------------------------
## M3 — pre_install allowlist translator
## ---------------------------------------------------------------------------
##
## Scoop manifests carry ``pre_install: [...]`` blocks of PowerShell.
## The harvester translates each LINE into either a structured
## ``PreInstallAction`` (cakBuiltin allowlist hit) or records it
## verbatim in ``pre_install_unrecognized``. The cakBuiltin realize
## loop replays actions; unrecognized lines surface as
## ``WPreInstallUnrecognized`` stderr warnings at apply time.
##
## The harvester does NOT execute PowerShell — it only does shape
## recognition. The matcher is intentionally lenient (whitespace +
## case-insensitive cmdlet names) but conservative on argument shapes
## (only accepts $dir-rooted paths; anything reaching ``$persist_dir``,
## ``$bucketsdir``, etc. lands in unrecognized).

proc isDirRootedPath(arg: string): bool =
  ## Path references must stay rooted under ``$dir`` (the realized
  ## prefix). Scoop's ``$persist_dir`` / ``$bucketsdir`` /
  ## ``$cachedir`` / ``$env:TMP`` references → unrecognized.
  let s = arg.strip(chars = {' ', '\t', '"', '\''})
  s.startsWith("$dir") or s.startsWith("$Dir") or s.startsWith("${dir}")

proc unquoteArg(arg: string): string =
  let s = arg.strip()
  if s.len >= 2 and ((s.startsWith("\"") and s.endsWith("\"")) or
                     (s.startsWith("'") and s.endsWith("'"))):
    return s[1 ..< s.len - 1]
  s

proc canonicalizeArg(arg: string): string =
  ## Normalize ``\\`` -> ``\`` (manifest authors double-escape
  ## backslashes in JSON strings) and unquote. The realize loop's
  ## ``substituteDirPlaceholder`` does the final $dir → staging dir
  ## substitution.
  unquoteArg(arg).replace("\\\\", "\\")

proc splitPsArgs(rest: string): seq[string] =
  ## Tokenize a PowerShell argv tail (after the cmdlet name). Honors
  ## quoted strings (' and "), splits on whitespace otherwise. Returns
  ## the tokens in order; the caller pairs them with named flags
  ## (``-Path X -Destination Y``) or treats them as positional.
  result = @[]
  var i = 0
  while i < rest.len:
    let ch = rest[i]
    if ch in {' ', '\t'}:
      inc i; continue
    if ch == '"' or ch == '\'':
      let q = ch
      var j = i + 1
      while j < rest.len and rest[j] != q:
        inc j
      result.add(rest[i+1 ..< j])
      i = j + 1
    else:
      var j = i
      while j < rest.len and rest[j] notin {' ', '\t'}:
        inc j
      result.add(rest[i ..< j])
      i = j

proc parsePathFlags(args: openArray[string]):
    tuple[path, destination, value: string; recurse, force: bool] =
  ## Walk the ``args`` list looking for ``-Path``, ``-Destination``,
  ## ``-Value``, ``-Recurse``, ``-Force`` flags (case-insensitive).
  ## Positional args fall back: first positional → path, second →
  ## destination/value.
  var positional: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    let aL = a.toLowerAscii()
    if aL in ["-path", "-literalpath"] and i + 1 < args.len:
      result.path = args[i + 1]
      i += 2
    elif aL == "-destination" and i + 1 < args.len:
      result.destination = args[i + 1]
      i += 2
    elif aL == "-value" and i + 1 < args.len:
      result.value = args[i + 1]
      i += 2
    elif aL == "-recurse":
      result.recurse = true
      inc i
    elif aL == "-force":
      result.force = true
      inc i
    elif aL.startsWith("-"):
      # Skip unknown named-flag values (one-arg consumption is the
      # conservative default; this drops e.g. -Encoding utf8).
      if i + 1 < args.len and not args[i + 1].startsWith("-"):
        i += 2
      else:
        inc i
    else:
      positional.add(a)
      inc i
  if result.path.len == 0 and positional.len >= 1:
    result.path = positional[0]
  if result.destination.len == 0 and result.value.len == 0 and
     positional.len >= 2:
    result.destination = positional[1]

proc translatePreInstallLine(line: string;
                              dropped: var seq[string]):
    tuple[ok: bool; action: PreInstallAction] =
  ## Translate ONE pre_install PS line into a structured action. On
  ## allowlist miss, return ``(false, default)`` so the caller records
  ## the verbatim line in ``pre_install_unrecognized``. ``dropped`` is
  ## populated with rejected-arg reasons (debug info).
  let stripped = line.strip()
  # Empty + comment-only lines are noops — return (false) and let the
  # caller treat them as no-emit (NOT as unrecognized).
  if stripped.len == 0 or stripped.startsWith("#"):
    return (false, PreInstallAction())
  # Multi-statement lines (e.g. `if (Test-Path ...) { ... }`) are
  # out of allowlist; fail soft.
  if stripped.contains("{") or stripped.contains("}") or
     stripped.contains("if (") or stripped.contains("foreach") or
     stripped.startsWith("&") or stripped.startsWith("$") or
     stripped.startsWith("("):
    dropped.add("control-flow / variable-assignment")
    return (false, PreInstallAction())

  # Split into cmdlet + arg list.
  var idx = 0
  while idx < stripped.len and stripped[idx] notin {' ', '\t'}: inc idx
  let cmdlet = stripped[0 ..< idx].toLowerAscii()
  let tail = if idx < stripped.len: stripped[idx + 1 .. ^1] else: ""
  let args = splitPsArgs(tail)

  case cmdlet
  of "new-item":
    let flags = parsePathFlags(args)
    var itemType = ""
    var j = 0
    while j < args.len:
      if args[j].toLowerAscii() == "-itemtype" and j + 1 < args.len:
        itemType = args[j + 1].toLowerAscii()
        break
      inc j
    if flags.path.len == 0 or not isDirRootedPath(flags.path):
      dropped.add("New-Item path not $dir-rooted")
      return (false, PreInstallAction())
    case itemType
    of "directory":
      return (true, PreInstallAction(kind: piaNewItemDir,
        source: "", target: canonicalizeArg(flags.path),
        recurse: false, literal: ""))
    of "file":
      return (true, PreInstallAction(kind: piaNewItemFile,
        source: "", target: canonicalizeArg(flags.path),
        recurse: false, literal: ""))
    else:
      dropped.add("New-Item -ItemType not Directory/File")
      return (false, PreInstallAction())
  of "copy-item":
    let flags = parsePathFlags(args)
    if flags.path.len == 0 or flags.destination.len == 0 or
       not isDirRootedPath(flags.path) or
       not isDirRootedPath(flags.destination):
      dropped.add("Copy-Item path/destination not $dir-rooted")
      return (false, PreInstallAction())
    return (true, PreInstallAction(kind: piaCopyItem,
      source: canonicalizeArg(flags.path),
      target: canonicalizeArg(flags.destination),
      recurse: flags.recurse, literal: ""))
  of "move-item":
    let flags = parsePathFlags(args)
    if flags.path.len == 0 or flags.destination.len == 0 or
       not isDirRootedPath(flags.path) or
       not isDirRootedPath(flags.destination):
      dropped.add("Move-Item path/destination not $dir-rooted")
      return (false, PreInstallAction())
    return (true, PreInstallAction(kind: piaMoveItem,
      source: canonicalizeArg(flags.path),
      target: canonicalizeArg(flags.destination),
      recurse: false, literal: ""))
  of "remove-item":
    let flags = parsePathFlags(args)
    if flags.path.len == 0 or not isDirRootedPath(flags.path):
      dropped.add("Remove-Item path not $dir-rooted")
      return (false, PreInstallAction())
    return (true, PreInstallAction(kind: piaRemoveItem,
      source: "", target: canonicalizeArg(flags.path),
      recurse: flags.recurse, literal: ""))
  of "set-content":
    let flags = parsePathFlags(args)
    if flags.path.len == 0 or not isDirRootedPath(flags.path):
      dropped.add("Set-Content path not $dir-rooted")
      return (false, PreInstallAction())
    if flags.value.len == 0:
      dropped.add("Set-Content -Value missing or non-literal")
      return (false, PreInstallAction())
    return (true, PreInstallAction(kind: piaSetContent,
      source: "", target: canonicalizeArg(flags.path),
      recurse: false, literal: unquoteArg(flags.value)))
  of "add-path":
    # Scoop's Add-Path helper: ``Add-Path <dir>``.
    if args.len < 1 or not isDirRootedPath(args[0]):
      dropped.add("Add-Path target not $dir-rooted")
      return (false, PreInstallAction())
    return (true, PreInstallAction(kind: piaAddPath,
      source: "", target: canonicalizeArg(args[0]),
      recurse: false, literal: ""))
  of "expand-7zarchive", "expand-7ziparchive":
    # ``Expand-7zArchive <source> <destination>``.
    var positionals: seq[string] = @[]
    for a in args:
      if not a.startsWith("-"):
        positionals.add(a)
    if positionals.len < 1 or not isDirRootedPath(positionals[0]):
      dropped.add("Expand-7zArchive source not $dir-rooted")
      return (false, PreInstallAction())
    let src = canonicalizeArg(positionals[0])
    let dst =
      if positionals.len >= 2 and isDirRootedPath(positionals[1]):
        canonicalizeArg(positionals[1])
      else: "$dir"
    return (true, PreInstallAction(kind: piaExpand7z,
      source: src, target: dst, recurse: false, literal: ""))
  of "expand-darkarchive", "expand-msiarchive":
    # M4: ``Expand-DarkArchive <msi> <dir>`` / ``Expand-MsiArchive
    # <msi> <dir>``. Scoop's installer.script primitives for MSI
    # extraction; both dispatch through the same cakBuiltin path.
    # The harvester maps both into the matching PreInstallActionKind
    # variant (piaExpandDark vs piaExpandMsi) so the realize loop's
    # diagnostic can distinguish them, but the runtime dispatch is
    # identical.
    var positionals: seq[string] = @[]
    for a in args:
      if not a.startsWith("-"):
        positionals.add(a)
    if positionals.len < 1 or not isDirRootedPath(positionals[0]):
      dropped.add(cmdlet & " source not $dir-rooted")
      return (false, PreInstallAction())
    let src = canonicalizeArg(positionals[0])
    let dst =
      if positionals.len >= 2 and isDirRootedPath(positionals[1]):
        canonicalizeArg(positionals[1])
      else: "$dir"
    let kind =
      if cmdlet == "expand-darkarchive": piaExpandDark else: piaExpandMsi
    return (true, PreInstallAction(kind: kind,
      source: src, target: dst, recurse: false, literal: ""))
  of "expand-innoarchive":
    # M4: ``Expand-InnoArchive <exe> <dir>``. NOT a stock Scoop
    # cmdlet; M4 wires this in for forward compatibility with
    # manifests that may grow it (innounp users currently roll their
    # own; the catalog author can hand-write Expand-InnoArchive in
    # an installer.script after M4).
    var positionals: seq[string] = @[]
    for a in args:
      if not a.startsWith("-"):
        positionals.add(a)
    if positionals.len < 1 or not isDirRootedPath(positionals[0]):
      dropped.add("Expand-InnoArchive source not $dir-rooted")
      return (false, PreInstallAction())
    let src = canonicalizeArg(positionals[0])
    let dst =
      if positionals.len >= 2 and isDirRootedPath(positionals[1]):
        canonicalizeArg(positionals[1])
      else: "$dir"
    return (true, PreInstallAction(kind: piaExpandInno,
      source: src, target: dst, recurse: false, literal: ""))
  else:
    dropped.add("cmdlet not in allowlist: " & cmdlet)
    return (false, PreInstallAction())

proc recognizeLauncherEmitFromPreInstall*(lines: openArray[string];
                                           app: string;
                                           diags: var seq[Diagnostic]):
    tuple[recognized: bool; spec: LauncherEmitSpec; consumedLines: seq[int]] =
  ## M5: scan the pre_install lines for a Scoop-style launcher synthesis
  ## shape. Currently recognizes the .phar wrap pattern (composer's
  ## shape: lines containing ``& php`` + ``<name>.phar`` + the
  ## eventual ``$dir\<name>.ps1`` write target). Returns the matched
  ## ``LauncherEmitSpec`` AND the line indices the matcher consumed so
  ## the caller can skip them in the unrecognized fallback.
  ##
  ## Recognition heuristic — closed-set, conservative:
  ##   * the lines collectively reference ``& php`` (case-insensitive)
  ##   * the lines collectively reference a ``<name>.phar`` literal
  ##   * the lines collectively reference a ``$dir\<name>.ps1`` write
  ##     target (Add-Content / Set-Content / `>` redirect) whose
  ##     ``<name>`` matches the .phar's stem
  ##
  ## When all three match, emit ``LauncherEmitSpec(kind: lekPhar,
  ## target: "<name>.phar", interpreter_package_id: "php",
  ## launcher_name: "<name>")`` and mark every line that contributed
  ## a match as consumed. Arbitrary additional pre_install logic (e.g.
  ## composer's COMPOSER_HOME migration block) is left unconsumed and
  ## flows through the existing unrecognized path so the operator sees
  ## the gap.
  ##
  ## Java/jar shape (``& java -jar <name>.jar``) is detected with the
  ## same pattern + ``jdk`` interpreter; M5 does not exercise it (no
  ## current catalog tool uses it) but the schema supports it.
  result.recognized = false
  result.consumedLines = @[]
  var pharStem = ""
  var jarStem = ""
  var sawPhpInvoke = false
  var sawJavaJarInvoke = false
  var ps1WriteStem = ""
  var consumedCandidate: seq[int] = @[]
  for i, raw in lines:
    let line = raw.strip()
    if line.len == 0: continue
    let low = line.toLowerAscii()
    # & php ... <name>.phar
    if (low.contains("& php") or low.contains("&php")) and low.contains(".phar"):
      sawPhpInvoke = true
      consumedCandidate.add(i)
      # Extract the .phar stem.
      var idx = low.find(".phar")
      if idx > 0:
        var start = idx
        while start > 0 and low[start - 1] notin {' ', '\t', '"', '\'',
                                                   '\\', '/', '(', ')'}:
          dec start
        pharStem = line[start ..< idx]
    # & java -jar ... <name>.jar
    if (low.contains("& java") or low.contains("&java")) and
       low.contains("-jar") and low.contains(".jar"):
      sawJavaJarInvoke = true
      consumedCandidate.add(i)
      var idx = low.find(".jar")
      if idx > 0:
        var start = idx
        while start > 0 and low[start - 1] notin {' ', '\t', '"', '\'',
                                                   '\\', '/', '(', ')'}:
          dec start
        jarStem = line[start ..< idx]
    # Add-Content / Set-Content / > redirect targeting $dir\<name>.ps1
    if low.contains("$dir") and low.contains(".ps1") and
       (low.contains("add-content") or low.contains("set-content") or
        low.contains(">") or low.contains("out-file")):
      consumedCandidate.add(i)
      var idx = low.find(".ps1")
      if idx > 0:
        var start = idx
        while start > 0 and low[start - 1] notin {' ', '\t', '"', '\'',
                                                   '\\', '/'}:
          dec start
        ps1WriteStem = line[start ..< idx]
  # Deduplicate consumed indices preserving order.
  var seen: seq[int] = @[]
  for i in consumedCandidate:
    if i notin seen: seen.add(i)
  consumedCandidate = seen
  if sawPhpInvoke and pharStem.len > 0 and ps1WriteStem.len > 0 and
     pharStem.toLowerAscii() == ps1WriteStem.toLowerAscii():
    result.recognized = true
    result.spec = LauncherEmitSpec(
      kind: lekPhar,
      target: pharStem & ".phar",
      interpreter_package_id: "php",
      launcher_name: pharStem)
    result.consumedLines = consumedCandidate
    diags.add(Diagnostic(
      kind: dkLauncherEmitRecognized, app: app,
      detail: "lekPhar launcher synthesis: target=" & pharStem &
        ".phar interpreter=php launcher_name=" & pharStem &
        " (consumed " & $consumedCandidate.len & " pre_install lines)"))
    return
  if sawJavaJarInvoke and jarStem.len > 0 and ps1WriteStem.len > 0 and
     jarStem.toLowerAscii() == ps1WriteStem.toLowerAscii():
    result.recognized = true
    result.spec = LauncherEmitSpec(
      kind: lekJar,
      target: jarStem & ".jar",
      interpreter_package_id: "jdk",
      launcher_name: jarStem)
    result.consumedLines = consumedCandidate
    diags.add(Diagnostic(
      kind: dkLauncherEmitRecognized, app: app,
      detail: "lekJar launcher synthesis: target=" & jarStem &
        ".jar interpreter=jdk launcher_name=" & jarStem &
        " (consumed " & $consumedCandidate.len & " pre_install lines)"))

proc translatePreInstall(node: JsonNode;
                          app: string;
                          diags: var seq[Diagnostic]):
    tuple[actions: seq[PreInstallAction]; unrecognized: seq[string];
          impliesNested7z: bool; launcherEmit: seq[LauncherEmitSpec]] =
  ## Translate a Scoop ``pre_install`` JSON node (string | seq[string])
  ## into the M3 schema. Detects the nested-7z idiom: presence of an
  ## ``Expand-7zArchive`` ``*.7z`` glob (or a sibling cleanup
  ## ``Remove-Item *.7z``) → ``impliesNested7z = true``.
  result.impliesNested7z = false
  if node.isNil: return
  var lines: seq[string] = @[]
  case node.kind
  of JString: lines.add(node.getStr())
  of JArray:
    for child in node.items:
      if child.kind == JString: lines.add(child.getStr())
  else: return
  if lines.len == 0: return
  # M5: try the launcher-emit recognizer FIRST. If matched, the
  # contributing lines are skipped in the per-line allowlist walk below
  # (so we don't double-emit them as pre_install_unrecognized warnings).
  let launcherMatch = recognizeLauncherEmitFromPreInstall(lines, app, diags)
  if launcherMatch.recognized:
    result.launcherEmit.add(launcherMatch.spec)
  var sawExpandWildcard = false
  var sawRemoveSevenZ = false
  for idx, line in lines:
    if launcherMatch.recognized and idx in launcherMatch.consumedLines:
      continue
    var dropped: seq[string] = @[]
    let translation = translatePreInstallLine(line, dropped)
    if translation.ok:
      result.actions.add(translation.action)
      diags.add(Diagnostic(
        kind: dkPreInstallAllowlistEntry, app: app,
        detail: "translated: " & line.strip()))
      if translation.action.kind == piaExpand7z and
         '*' in translation.action.source:
        sawExpandWildcard = true
      if translation.action.kind == piaRemoveItem and
         translation.action.target.toLowerAscii().endsWith(".7z"):
        sawRemoveSevenZ = true
    elif line.strip().len == 0 or line.strip().startsWith("#"):
      # Noop line — drop silently.
      discard
    else:
      result.unrecognized.add(line)
      let reason = if dropped.len > 0: dropped.join("; ") else: "no allowlist match"
      diags.add(Diagnostic(
        kind: dkPreInstallUnrecognized, app: app,
        detail: line.strip() & " (" & reason & ")"))
  result.impliesNested7z = sawExpandWildcard or sawRemoveSevenZ
  if result.actions.len == 0 and result.unrecognized.len == 0 and
     result.launcherEmit.len == 0:
    diags.add(Diagnostic(
      kind: dkPreInstallSkippedAllRecognized, app: app,
      detail: "pre_install block was entirely comments / blank lines"))

proc cpuOf(arch: string): PlatformCpu =
  case arch
  of "64bit": pcX86_64
  of "arm64": pcAArch64
  else: pcAny  # unreachable when paired with archIsAccepted

proc dollarDirToPrefix(value: string): string =
  ## Rewrite Scoop's ``$dir`` (the app's realized prefix) to
  ## reprobuild's ``${prefix}`` substitution shape.
  value.replace("$dir", "${prefix}")

proc takePerArchSlice(arch: string; node: JsonNode; app: string;
                      platforms: var seq[PlatformBinary];
                      diags: var seq[Diagnostic]): bool =
  ## Convert a single per-arch node into a PlatformBinary appended
  ## to ``platforms``. Returns true iff a slice was added. All
  ## diagnostics flow through the ``diags`` ref.
  if node.isNil or node.kind != JObject: return false
  if not node.hasKey("url"): return false
  # url + hash + extract_dir each accept a string OR an array; we
  # keep the FIRST element of each (multiple-archive manifests like
  # pkg-config string several archives together — only the first is
  # the primary download; the rest are helpers reprobuild cannot
  # model in a single PlatformBinary).
  let urlNode = node["url"]
  let url = case urlNode.kind
            of JString: urlNode.getStr()
            of JArray:
              if urlNode.len >= 1 and urlNode[0].kind == JString:
                urlNode[0].getStr()
              else: ""
            else: ""
  if url.len == 0: return false
  let hashRaw = if node.hasKey("hash"):
                  case node["hash"].kind
                  of JString: node["hash"].getStr()
                  of JArray:
                    if node["hash"].len >= 1 and
                       node["hash"][0].kind == JString:
                      node["hash"][0].getStr()
                    else: ""
                  else: ""
                else: ""
  if hashRaw.len == 0:
    diags.add(Diagnostic(
      kind: dkManifestNoHash, app: app,
      detail: arch & ": no hash field"))
    return false
  let (algo, digest) = splitHash(hashRaw)
  var sha256 = ""
  var sha512 = ""
  var sha1 = ""
  case algo
  of "sha256": sha256 = digest
  of "sha512": sha512 = digest
  of "sha1":
    sha1 = digest
    diags.add(Diagnostic(
      kind: dkHashAlgorithmWeak, app: app,
      detail: arch & ": sha1 hash accepted; upstream prefer sha256"))
  else:
    diags.add(Diagnostic(
      kind: dkHashAlgorithmUnsupported, app: app,
      detail: arch & ": hash algorithm '" & algo &
        "' is not supported (M63/M1 schema accepts sha256/sha512/sha1)"))
    return false
  let extractDir = if node.hasKey("extract_dir"):
                     extractDirAt(node["extract_dir"], 0)
                   else: ""
  platforms.add(PlatformBinary(
    cpu: cpuOf(arch),
    os: poWindows,
    url: url,
    sha256: sha256, sha512: sha512, sha1: sha1,
    extract_path: extractDir))
  true

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc parseScoopManifest*(app: string; raw: string;
                         binDefaults: openArray[string] = []):
    ParsedManifest =
  ## Parse one Scoop manifest. ``app`` is the tool name (the manifest
  ## filename without ``.json``); ``raw`` is the manifest JSON
  ## source. Errors are non-throwing — invalid input yields
  ## ``ok = false`` and a populated ``diagnostics`` seq.
  ##
  ## ``binDefaults`` is the M67 escape hatch: when the manifest's
  ## ``bin`` field is absent / empty, the parser synthesizes
  ## ``bin_relpath`` from the manifest's ``env_add_path`` cross-product
  ## with ``binDefaults`` (see module docstring).
  result = ParsedManifest(ok: false, app: app)

  var root: JsonNode
  try:
    root = parseJson(raw)
  except JsonParsingError as err:
    result.diagnostics.add(Diagnostic(
      kind: dkManifestNoUrl, app: app,
      detail: "manifest is not valid JSON: " & err.msg))
    return

  if root.kind != JObject:
    result.diagnostics.add(Diagnostic(
      kind: dkManifestNoUrl, app: app,
      detail: "manifest is not a JSON object"))
    return

  # Required: top-level version.
  if not root.hasKey("version") or root["version"].kind != JString:
    result.diagnostics.add(Diagnostic(
      kind: dkManifestNoUrl, app: app,
      detail: "missing top-level 'version' string"))
    return
  let version = root["version"].getStr()

  let installerNode =
    if root.hasKey("installer"): root["installer"] else: nil
  # M68 refinement: only treat the manifest as an installer-style payload
  # when ``installer`` carries a ``url`` or ``file`` key (i.e. an actual
  # binary to invoke). A bare ``installer.script`` (e.g. nim's PATH-tweak
  # ``Add-Path``) is a post-extract PowerShell hook semantically equivalent
  # to ``post_install`` and must NOT flip ``install_method`` to
  # ``imInstallerSilent`` — the archive still extracts normally and the
  # script-only hook is silently dropped (consistent with how
  # ``post_install`` is dropped per the module docstring).
  let hasInstaller = (not installerNode.isNil) and
    installerNode.kind == JObject and
    (installerNode.hasKey("url") or installerNode.hasKey("file"))
  # M4: ``installer.script`` is M4 territory — a NSIS+MSI bundle
  # (python3, swift) ships the outer .exe as a Burn/NSIS shell whose
  # extraction is gated entirely by the script (Expand-DarkArchive +
  # Expand-MsiArchive). Detect the script-only shape so we can flip
  # to imInstallerNsisBundle.
  let hasInstallerScript = (not installerNode.isNil) and
    installerNode.kind == JObject and
    installerNode.hasKey("script")
  # M4: ``"innosetup": true`` flips dispatch to imInstallerInnoSetup
  # regardless of whether an installer block is present (the
  # freepascal shape is "innosetup: true" + no installer block).
  let hasInnoSetup = root.hasKey("innosetup") and
    root["innosetup"].kind == JBool and
    root["innosetup"].getBool()

  # ----- Per-platform slices -----
  var platforms: seq[PlatformBinary] = @[]

  if root.hasKey("architecture") and root["architecture"].kind == JObject:
    let archNode = root["architecture"]
    # Walk the accepted architecture keys in fixed order (x86_64
    # before aarch64) for deterministic platforms[] ordering — the
    # JObject insertion order would otherwise leak from the JSON
    # author's choice.
    #
    # Top-level ``extract_dir`` (Scoop convention: when the
    # architecture-split download lands in the same inner dir
    # regardless of CPU, e.g. ``jdk-21.0.11+10`` for temurin21-jdk)
    # is propagated down into per-arch nodes that lack their own
    # ``extract_dir`` so the synthesized PlatformBinary records carry
    # the correct flatten path.
    let topExtractDir =
      if root.hasKey("extract_dir"): root["extract_dir"] else: nil
    for arch in ["64bit", "arm64"]:
      if archNode.hasKey(arch):
        var perArch = archNode[arch]
        if not topExtractDir.isNil and
           perArch.kind == JObject and not perArch.hasKey("extract_dir"):
          # Shallow-copy + augment so we don't mutate the parsed
          # JSON tree (the inspector / verify path may re-walk it).
          var augmented = newJObject()
          for k, v in perArch.pairs: augmented[k] = v
          augmented["extract_dir"] = topExtractDir
          perArch = augmented
        let added = takePerArchSlice(arch, perArch, app,
          platforms, result.diagnostics)
        discard added
    # Diagnostic for any other architecture key present.
    for key in archNode.keys:
      if key == "32bit":
        result.diagnostics.add(Diagnostic(
          kind: dkManifest32BitIgnored, app: app,
          detail: "the M63 schema does not model 32-bit Windows builds"))
      elif key notin ["64bit", "arm64"]:
        result.diagnostics.add(Diagnostic(
          kind: dkUnknownArchitecture, app: app,
          detail: "unknown architecture key '" & key & "'"))
  else:
    # Top-level url + hash, no architecture split.
    var fauxNode = newJObject()
    if root.hasKey("url"): fauxNode["url"] = root["url"]
    if root.hasKey("hash"): fauxNode["hash"] = root["hash"]
    if root.hasKey("extract_dir"):
      fauxNode["extract_dir"] = root["extract_dir"]
    if fauxNode.hasKey("url"):
      # Architecture-agnostic: encode as a single (pcAny, poWindows)
      # platform. Use ``cpuOf`` would yield pcAny only on unknown
      # input, so synthesize directly.
      let urlNode = fauxNode["url"]
      let url = case urlNode.kind
                of JString: urlNode.getStr()
                of JArray:
                  if urlNode.len >= 1 and urlNode[0].kind == JString:
                    urlNode[0].getStr()
                  else: ""
                else: ""
      if url.len == 0:
        result.diagnostics.add(Diagnostic(
          kind: dkManifestNoUrl, app: app,
          detail: "top-level 'url' is empty"))
        return
      let hashRaw = if fauxNode.hasKey("hash"):
                      case fauxNode["hash"].kind
                      of JString: fauxNode["hash"].getStr()
                      of JArray:
                        if fauxNode["hash"].len >= 1 and
                           fauxNode["hash"][0].kind == JString:
                          fauxNode["hash"][0].getStr()
                        else: ""
                      else: ""
                    else: ""
      if hashRaw.len == 0:
        result.diagnostics.add(Diagnostic(
          kind: dkManifestNoHash, app: app,
          detail: "top-level 'hash' is missing"))
        return
      let (algo, digest) = splitHash(hashRaw)
      var sha256 = ""
      var sha512 = ""
      var sha1 = ""
      case algo
      of "sha256": sha256 = digest
      of "sha512": sha512 = digest
      of "sha1":
        sha1 = digest
        result.diagnostics.add(Diagnostic(
          kind: dkHashAlgorithmWeak, app: app,
          detail: "sha1 hash accepted; upstream prefer sha256"))
      else:
        result.diagnostics.add(Diagnostic(
          kind: dkHashAlgorithmUnsupported, app: app,
          detail: "hash algorithm '" & algo &
            "' is not supported (M63/M1 schema accepts sha256/sha512/sha1)"))
        return
      let extractDir = if fauxNode.hasKey("extract_dir"):
                         extractDirAt(fauxNode["extract_dir"], 0)
                       else: ""
      platforms.add(PlatformBinary(
        cpu: pcAny, os: poWindows,
        url: url,
        sha256: sha256, sha512: sha512, sha1: sha1,
        extract_path: extractDir))
    else:
      result.diagnostics.add(Diagnostic(
        kind: dkManifestNoUrl, app: app,
        detail: "no 'url' field and no 'architecture' block"))
      return

  if platforms.len == 0:
    # All architectures failed (e.g. all blocks lacked hash). The
    # diagnostics already say why; just bail.
    return

  # ----- archive_format inferred from the FIRST platform's URL -----
  let (archiveFmt, archiveKnown) = inferArchiveFormat(
    platforms[0].url, hasInstaller)
  if not archiveKnown:
    result.diagnostics.add(Diagnostic(
      kind: dkArchiveFormatUnknown, app: app,
      detail: "could not infer archive_format from URL '" &
        platforms[0].url & "'; defaulting to afRaw"))
  # M3: emit the SFX-recognition diagnostic so operators can grep
  # for the dkSevenZipSfx kind across a bulk-harvest log.
  if archiveFmt == afSevenZipSfx:
    result.diagnostics.add(Diagnostic(
      kind: dkSevenZipSfx, app: app,
      detail: "URL '" & platforms[0].url &
        "' classified as 7z self-extracting (afSevenZipSfx)"))

  # ----- install_method -----
  # M4: dispatch priority — innosetup wins (cleanest signal), then
  # installer.script (NSIS+MSI bundle), then a regular .msi URL, then
  # installer-with-file (M3 NSIS imInstallerSilent), then bare extract.
  var installMethod = imExtract
  var installerArgs: seq[string] = @[]
  if hasInnoSetup:
    installMethod = imInstallerInnoSetup
    result.diagnostics.add(Diagnostic(
      kind: dkInstallMethodInnoSetup, app: app,
      detail: "manifest has innosetup: true; dispatching through M4 " &
        "innounp.exe extractor"))
  elif hasInstallerScript and not hasInstaller:
    # Script-only block. Probe the script content for Expand-DarkArchive
    # / Expand-MsiArchive — if either is present, treat as NSIS+MSI
    # bundle. Otherwise the manifest's installer.script is a generic
    # post-extract hook (we already drop those for safety per the
    # M68 refinement); fall through to imExtract.
    let scriptNode = installerNode["script"]
    var scriptLines: seq[string] = @[]
    case scriptNode.kind
    of JString: scriptLines.add(scriptNode.getStr())
    of JArray:
      for child in scriptNode.items:
        if child.kind == JString: scriptLines.add(child.getStr())
    else: discard
    var sawMsiExtract = false
    for line in scriptLines:
      let lower = line.toLowerAscii()
      if "expand-darkarchive" in lower or "expand-msiarchive" in lower:
        sawMsiExtract = true
        break
    if sawMsiExtract:
      installMethod = imInstallerNsisBundle
      result.diagnostics.add(Diagnostic(
        kind: dkInstallMethodNsisBundle, app: app,
        detail: "installer.script contains Expand-DarkArchive / " &
          "Expand-MsiArchive; dispatching through M4 NSIS-unwrap + " &
          "per-MSI dark extractor"))
  elif hasInstaller:
    installMethod = imInstallerSilent
    let (argsResult, unknown) = installerArgsFor(installerNode, archiveFmt)
    installerArgs = argsResult
    if unknown:
      result.diagnostics.add(Diagnostic(
        kind: dkInstallerArgsUnknown, app: app,
        detail: "installer block lacks 'args' and archive_format is " &
          $archiveFmt & "; please review the emitted installer_args"))
  # M4: bare .msi URLs with no installer block → imInstallerMsi.
  if installMethod == imExtract and archiveFmt == afInstallerMsi:
    installMethod = imInstallerMsi
    result.diagnostics.add(Diagnostic(
      kind: dkInstallMethodMsi, app: app,
      detail: "primary download is .msi; dispatching through M4 " &
        "dark.exe extractor (override via CAKBUILTIN_PREFER_MSIEXEC=1)"))

  # ----- bin -----
  var diags: seq[Diagnostic] = @[]
  var binRelpath = binRelpathsOf(
    if root.hasKey("bin"): root["bin"] else: nil, app, diags)
  for d in diags: result.diagnostics.add(d)

  # If ``bin`` was empty (or absent) AND the operator supplied a
  # binDefaults list for this app, synthesize bin_relpath from the
  # manifest's env_add_path cross-product with the defaults. Mirrors
  # the M67 spec's "M66 known limitation #1" workaround.
  if binRelpath.len == 0 and binDefaults.len > 0:
    let envPaths = envAddPathsOf(
      if root.hasKey("env_add_path"): root["env_add_path"] else: nil)
    binRelpath = synthesizeBinRelpaths(envPaths, binDefaults)

  # ----- env -----
  var envPairs: seq[(string, string)] = @[]
  if root.hasKey("env_set") and root["env_set"].kind == JObject:
    # Sort env keys for deterministic order (idempotence).
    var keys: seq[string] = @[]
    for k in root["env_set"].keys: keys.add(k)
    keys.sort(cmp[string])
    for k in keys:
      let v = root["env_set"][k]
      if v.kind == JString:
        envPairs.add((k, dollarDirToPrefix(v.getStr())))

  # ----- M3: pre_install allowlist translation -----
  var preActions: seq[PreInstallAction] = @[]
  var preUnrecognized: seq[string] = @[]
  var impliesNested = false
  # M5: launcher_emit specs harvested from a recognized pre_install
  # synthesis pattern (composer's .phar shape, future .jar wraps).
  var launcherEmit: seq[LauncherEmitSpec] = @[]
  if root.hasKey("pre_install"):
    let translated = translatePreInstall(root["pre_install"], app,
      result.diagnostics)
    preActions = translated.actions
    preUnrecognized = translated.unrecognized
    impliesNested = translated.impliesNested7z
    for spec in translated.launcherEmit: launcherEmit.add(spec)

  # M4: when install_method == imInstallerNsisBundle, also harvest the
  # installer.script lines through the same translator and append to
  # preActions/preUnrecognized — they describe the per-tool flatten
  # quirks (swift's LocalApp\Programs\Swift\ Move-Item dance,
  # python3's appendpath.msi skip + tmp cleanup) that the realize loop
  # replays AFTER the M4 bundle extractor materializes the merged file
  # tree. The translator's allowlist now covers Expand-DarkArchive +
  # Expand-MsiArchive; unrecognized lines (control flow, Get-ChildItem
  # piping) land verbatim in preUnrecognized for the realize loop to
  # surface as WPreInstallUnrecognized warnings.
  if installMethod == imInstallerNsisBundle and hasInstallerScript:
    let scriptNode = installerNode["script"]
    let translated = translatePreInstall(scriptNode, app,
      result.diagnostics)
    for action in translated.actions: preActions.add(action)
    for line in translated.unrecognized: preUnrecognized.add(line)
    for spec in translated.launcherEmit: launcherEmit.add(spec)

  # M3: nested_7z is per-platform. When pre_install actions imply a
  # nested extraction, mark every platform's nested_7z = true (the
  # nested-archive shape is upstream-uniform across CPUs for the M3
  # target tools — gcc's components-*.7z ships the same payload on
  # x86_64 + arm64 if/when the arm64 build lands).
  if impliesNested:
    for i in 0 ..< platforms.len:
      platforms[i].nested_7z = true
    result.diagnostics.add(Diagnostic(
      kind: dkNested7z, app: app,
      detail: "pre_install contains Expand-7zArchive + Remove-Item *.7z; " &
        "platform nested_7z flag set"))

  # M5: when a launcher_emit was harvested, the catalog's bin_relpath
  # surface should be the LAUNCHERS we will emit at realize time, not
  # the raw .phar / .jar payload. Override bin_relpath here when the
  # auto-harvested value is empty / is just the payload file (composer's
  # auto-harvest landed bin_relpath=["composer.ps1"] from the Scoop
  # ``bin`` field; we replace it with the synthesized .ps1+.cmd pair so
  # the M5 schema validator's launcher_name-in-bin_relpath sanity check
  # holds).
  if launcherEmit.len > 0:
    var synthBins: seq[string] = @[]
    for spec in launcherEmit:
      synthBins.add("bin/" & spec.launcher_name & ".ps1")
      synthBins.add("bin/" & spec.launcher_name & ".cmd")
    binRelpath = synthBins

  # ----- Compose the VersionedProvisioning -----
  result.entry = initVersionedProvisioning(
    version = version,
    archive_format = archiveFmt,
    install_method = installMethod,
    bin_relpath = binRelpath,
    platforms = platforms,
    installer_args = installerArgs,
    env = envPairs,
    pre_install_actions = preActions,
    pre_install_unrecognized = preUnrecognized,
    launcher_emit = launcherEmit)
  result.ok = true
