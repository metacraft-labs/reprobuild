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
    dkArchiveFormatUnknown = "HArchiveFormatUnknown"

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
  ## ``<algo>:<hex>`` (sha512: / sha256: / md5: / etc.). Return a
  ## normalized (algo, digest) tuple. ``algo`` is lower-case; empty
  ## input yields ``("", "")``.
  if raw.len == 0:
    return ("", "")
  let idx = raw.find(':')
  if idx < 0:
    # Bare hex digest -> sha256 by Scoop convention.
    return ("sha256", raw)
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
  let clean = extensionForFormatSniff(url).toLowerAscii()
  # Plain HTML pages or weird extensions fall through to afRaw.
  if clean.endsWith(".tar.gz") or clean.endsWith(".tgz"):
    return (afTarGz, true)
  if clean.endsWith(".tar.xz") or clean.endsWith(".txz"):
    return (afTarXz, true)
  if clean.endsWith(".tar.bz2") or clean.endsWith(".tbz2"):
    return (afTarBz2, true)
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
  case algo
  of "sha256": sha256 = digest
  of "sha512": sha512 = digest
  else:
    diags.add(Diagnostic(
      kind: dkHashAlgorithmUnsupported, app: app,
      detail: arch & ": hash algorithm '" & algo &
        "' is not supported (M63 schema accepts sha256 / sha512 only)"))
    return false
  let extractDir = if node.hasKey("extract_dir"):
                     extractDirAt(node["extract_dir"], 0)
                   else: ""
  platforms.add(PlatformBinary(
    cpu: cpuOf(arch),
    os: poWindows,
    url: url,
    sha256: sha256, sha512: sha512,
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
      case algo
      of "sha256": sha256 = digest
      of "sha512": sha512 = digest
      else:
        result.diagnostics.add(Diagnostic(
          kind: dkHashAlgorithmUnsupported, app: app,
          detail: "hash algorithm '" & algo & "' is not supported"))
        return
      let extractDir = if fauxNode.hasKey("extract_dir"):
                         extractDirAt(fauxNode["extract_dir"], 0)
                       else: ""
      platforms.add(PlatformBinary(
        cpu: pcAny, os: poWindows,
        url: url,
        sha256: sha256, sha512: sha512,
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

  # ----- install_method -----
  var installMethod = imExtract
  var installerArgs: seq[string] = @[]
  if hasInstaller:
    installMethod = imInstallerSilent
    let (argsResult, unknown) = installerArgsFor(installerNode, archiveFmt)
    installerArgs = argsResult
    if unknown:
      result.diagnostics.add(Diagnostic(
        kind: dkInstallerArgsUnknown, app: app,
        detail: "installer block lacks 'args' and archive_format is " &
          $archiveFmt & "; please review the emitted installer_args"))

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

  # ----- Compose the VersionedProvisioning -----
  result.entry = initVersionedProvisioning(
    version = version,
    archive_format = archiveFmt,
    install_method = installMethod,
    bin_relpath = binRelpath,
    platforms = platforms,
    installer_args = installerArgs,
    env = envPairs)
  result.ok = true
