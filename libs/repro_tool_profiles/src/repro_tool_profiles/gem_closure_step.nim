## The gem-closure post-extraction step: install a pinned, already-resolved
## gem closure into a realized Ruby prefix, offline, with the prefix's own
## Ruby, and compile every native extension with provisioned tools.
##
## A tarball record declares the step with ``gemClosure`` (a committed,
## generated manifest of ``<name> <version> <platform> <sha256> <url>``
## lines, ``gem_closure_manifest``), ``gemBuildUses`` (the provisioned
## packages native extensions are built with), ``gemBuildArgs`` (per-gem
## extconf arguments) and ``gemSubstitutions`` (gems admitted as prebuilt
## platform gems). The tarball provisioning edge runs it after the Ruby
## archive is unpacked into the staging prefix and before the prefix is
## checked, sealed and published, so the realized SDK -- Ruby, gems and
## compiled extensions -- is one binary-cache entry keyed on everything that
## built it (``post_extract_step``).
##
## What the step does, in order (the ``gem-closure-v1`` contract):
##
##  1. Every gem is fetched as a whole-file closure entry through the edge's
##     verified download (each checked against its SHA-256, shared download
##     cache) into ``<scratch>/.repro-gems/``, outside the prefix, before
##     anything is installed. A digest mismatch fails the edge; nothing else
##     on the host can satisfy a gem.
##  2. The environment is BUILT, not inherited: no ``GEM_HOME``,
##     ``GEM_PATH``, ``GEMRC``, ``GEM_SPEC_CACHE``, ``RUBYOPT``, ``RUBYLIB``,
##     ``BUNDLE_*`` or proxy configuration of the host; ``HOME`` and the
##     temporary directory are inside the scratch area; ``PATH`` holds only
##     the staging ``bin``, the build tools' directories and the system
##     directory. ``MSYS2_PATH`` names the provisioned MSYS root, which is
##     how RubyInstaller finds MSYS2 first; ``PKG_CONFIG_LIBDIR`` names the
##     build tools' ``pkgconfig`` directories (RubyInstaller overwrites
##     ``PKG_CONFIG_PATH`` with MSYS-form paths when it enables MSYS2, and
##     leaves ``PKG_CONFIG_LIBDIR`` alone). The proxy variables point at a
##     closed local port, so an installer that tried the network anyway
##     would fail rather than reach it.
##  3. The prefix's own Ruby must install into the staging prefix:
##     ``Gem.default_dir`` and ``Gem.dir`` must both resolve inside it.
##  4. Each gem, in manifest order, is installed with
##     ``ruby -S gem install --local --ignore-dependencies --no-document
##     --norc --no-user-install <file> [-- <build args>]``. Nothing is
##     resolved: a gem whose ``extconf.rb`` needs another gem finds it because
##     the manifest installed it first. ``--ignore-dependencies`` also keeps
##     RubyInstaller's install hook from running ``pacman`` for a gem's
##     declared MSYS2 packages (``operating_system.rb`` at
##     ``RubyInstaller-3.4.8-1`` runs it only when dependencies are not
##     ignored). Compiler flags are the Ruby's own ``CFLAGS``/``CXXFLAGS``
##     plus ``-ffile-prefix-map=<staging>=.``, passed through mkmf's
##     ``CONFIGURE_ARGS``, so debug and assertion strings do not carry the
##     staging path. The installed gem's specification must then exist in
##     the staging gem directory (RubyGems falls back to a per-user install
##     when it thinks the default directory is not writable).
##  5. After each install the extension build's intermediate products
##     (``*.o``, ``Makefile``, ``mkmf.log``, ``extconf.h`` under the gem's
##     ``ext/``) and the ``gem_make.out`` and ``mkmf.log`` RubyGems keeps
##     under ``extensions/`` are pruned, so is the ``build_info/<gem>.info``
##     that records the build arguments (which name the build tools' realized
##     prefixes, a per-host path), and a binstub whose ``#!`` line names
##     the staging Ruby is rewritten to ``#!/usr/bin/env ruby``, the form
##     RubyInstaller's own ``bin/gem`` uses.
##  6. On a MinGW Ruby (``RUBY_PLATFORM`` naming ``mingw``), every compiled
##     ``.so``/``.dll`` of the installed gems must import the UCRT
##     (``ucrtbase.dll`` or ``api-ms-win-crt-*``), must not import
##     ``msvcrt.dll``, and must not import a libxml2, libxslt, libyaml, zlib
##     or libiconv DLL (they are linked statically), as ``objdump -p`` from
##     the provisioned toolchain reports.
##
## The edge then applies the leak scan to the whole staging prefix
## (``prefix_portability``): any file still naming the staging path fails the
## edge, naming the file.
##
## No ``ridk`` and no ``pacman``: an MSYS root that ships ``pacman`` is
## refused, and so is installer output announcing an MSYS2 package install.

import std/[algorithm, os, osproc, sequtils, strtabs, strutils]

from repro_core/process_exec import execArgvExCloseOnce
import nimcrypto/[hash, sha2]
import repro_interface_artifacts
import repro_tool_profiles/post_extract_step

const
  GemClosureStepKind* = "gem-closure"
  GemClosureContractVersion* = "gem-closure-v1"
    ## Covers the command, the environment, the compiler-flag handling, the
    ## pruned set, the binstub rewrite and the C-runtime check described in
    ## the module comment. A change to any of them is a new version, because
    ## it changes the bytes a realized prefix holds.
  GemClosureStepDataPrefix = "gem\t"
  GemFetchDirectory* = ".repro-gems"
    ## Where the verified gem files are placed, under the step's scratch
    ## directory and never inside the prefix.
  DeadProxy = "http://127.0.0.1:9"
    ## The discard port, which nothing listens on.
  PrunedBuildProducts = ["Makefile", "mkmf.log", "extconf.h"]
  PrunedExtensionFiles = ["gem_make.out", "mkmf.log"]
  StaticOnlyLibraryPrefixes = ["libxml2", "libxslt", "libexslt", "libyaml",
                               "yaml", "zlib", "libz", "libiconv", "iconv"]
    ## DLL basenames (lowercase, without version suffix) of the libraries the
    ## C-runtime check requires to be linked statically.

type
  GemClosureStepError* = object of OSError
    ## A gem-closure step that cannot complete: the edge fails, the staging
    ## prefix is discarded, and nothing is sealed or published.

# ---------------------------------------------------------------------------
# Declaration
# ---------------------------------------------------------------------------

proc declarationRoot(record: InterfaceTarballProvisioning): string =
  if record.location.file.len > 0: parentDir(record.location.file) else: ""

proc gemManifestPath(record: InterfaceTarballProvisioning): string =
  ## The manifest file a record names, resolved as ``closureManifest`` is.
  if record.gemClosure.len == 0:
    return ""
  if record.gemClosure.isAbsolute:
    return record.gemClosure
  let root = declarationRoot(record)
  if root.len == 0: absolutePath(record.gemClosure)
  else: absolutePath(root / record.gemClosure)

proc gemEntriesOf*(record: InterfaceTarballProvisioning;
                   packageSelector: string): seq[GemClosureEntry] =
  ## The gems a record's step installs: the entries inlined in the record
  ## (re-validated, since an artifact may come from a clone another party
  ## committed), else the manifest file it names. Raises, naming the file
  ## and line, on a malformed manifest.
  if record.gemEntries.len > 0:
    return parseGemClosureManifestText(
      record.gemEntries.mapIt(canonicalGemLine(it)).join("\n"),
      "inlined gem entries of " & packageSelector)
  let path = gemManifestPath(record)
  if not fileExists(path):
    raise newException(ToolPrefixDeclarationError,
      "tool-resolution failed: the gem closure manifest of " &
      packageSelector & " was not found: " & path)
  parseGemClosureManifestText(readFile(path), path)

proc gemClosureDeclFor*(use: InterfaceToolUse;
                        record: InterfaceTarballProvisioning):
    PostExtractStepDecl =
  ## The registered declaration reader: the gem-closure step a selected
  ## tarball record declares, validated in full -- the manifest grammar, the
  ## platform substitutions, the build arguments and their prefix references
  ## -- before any edge runs and before any gem is fetched.
  if not hasGemClosureStep(record):
    return
  let selector = use.packageSelector
  let origin =
    if record.gemEntries.len > 0: "the gem closure of " & selector
    else: gemManifestPath(record)
  var entries: seq[GemClosureEntry]
  var selectors: seq[string]
  try:
    entries = gemEntriesOf(record, selector)
    for tool in record.gemBuildUses:
      selectors.add(tool.packageSelector)
    validateGemClosureDeclaration(entries, record.gemSubstitutions,
      record.gemBuildArgs, selectors, origin)
  except ToolPrefixDeclarationError:
    raise
  except ValueError as err:
    raise newException(ToolPrefixDeclarationError, err.msg)
  result = PostExtractStepDecl(
    kind: GemClosureStepKind,
    contractVersion: GemClosureContractVersion,
    manifestDigest: "sha256:" & toLowerAscii($sha256.digest(
      gemClosureContentDigestInput(entries))),
    buildConfig: canonicalGemBuildArgs(record.gemBuildArgs),
    dependencies: record.gemBuildUses)
  if record.gemSubstitutions.len > 0:
    result.buildConfig.add("substitutions\t" &
      record.gemSubstitutions.sorted().join("\t"))
  # The install order, for the runner. The manifest digest keys the sorted
  # entries, as a closure manifest's identity is formed.
  for entry in entries:
    result.stepData.add(GemClosureStepDataPrefix & canonicalGemLine(entry))
  let path = gemManifestPath(record)
  if path.len > 0 and fileExists(path):
    result.declarationFiles.add(path)

# ---------------------------------------------------------------------------
# Execution helpers
# ---------------------------------------------------------------------------

proc fail(selector, message: string) {.noreturn.} =
  raise newException(GemClosureStepError, "tool-resolution failed: the " &
    "gem-closure step of " & selector & ": " & message)

proc rubyExecutable(stagingPrefix: string): string =
  for name in ["ruby.exe", "ruby"]:
    let candidate = stagingPrefix / "bin" / name
    if fileExists(candidate):
      return candidate
  ""

proc isMsysRoot(prefix: string): bool =
  ## RubyInstaller's own test for an MSYS2 installation
  ## (``Msys2Installation#msys_path``): ``usr/bin/msys-2.0.dll`` exists.
  prefix.len > 0 and fileExists(prefix / "usr" / "bin" / "msys-2.0.dll")

proc portablePath(path: string): string =
  ## A path as an argument to the Ruby toolchain: forward slashes, which
  ## mkmf and the MinGW tools accept on every host and which a ``Makefile``
  ## does not mistake for escapes.
  path.replace('\\', '/')

proc expandPrefixReferences(arg: string;
                            tools: openArray[PostExtractStepTool]): string =
  ## ``$REPRO_PREFIX_<NAME>`` -> the realized prefix of the step tool whose
  ## selector spells ``<NAME>``. The declaration reader already refused a
  ## reference to anything else.
  result = arg
  for tool in tools:
    let token = GemPrefixReferenceStart & gemPrefixVariableName(tool.role)
    var at = result.find(token)
    while at >= 0:
      let after = at + token.len
      # Only a whole name: ``$REPRO_PREFIX_LIBXML2`` must not match the
      # start of ``$REPRO_PREFIX_LIBXML2_DEV``.
      if after < result.len and result[after] in {'A' .. 'Z', '0' .. '9', '_'}:
        at = result.find(token, after)
        continue
      let replacement = portablePath(tool.prefix)
      result = result[0 ..< at] & replacement & result[after .. ^1]
      at = result.find(token, at + replacement.len)

proc toolDirectories(tool: PostExtractStepTool): seq[string] =
  ## The directories a build tool contributes to ``PATH``.
  var dirs: seq[string]
  if tool.executable.len > 0:
    dirs.add(parentDir(tool.executable))
  for sub in ["bin", "usr" / "bin"]:
    if tool.prefix.len > 0 and dirExists(tool.prefix / sub):
      dirs.add(tool.prefix / sub)
  for dir in dirs:
    if dir notin result:
      result.add(dir)

proc systemDirectories(): seq[string] =
  when defined(windows):
    let root = getEnv("SystemRoot", getEnv("WINDIR", "C:\\Windows"))
    @[root / "System32", root, root / "System32" / "Wbem"]
  else:
    @["/usr/bin", "/bin"]

proc shellQuote(value: string): string =
  ## A single-quoted word for mkmf's ``Shellwords`` split of
  ## ``CONFIGURE_ARGS``. Backslashes are literal inside single quotes there.
  "'" & value.replace("'", "'\\''") & "'"

proc escapeRubyString(value: string): string =
  ## A double-quoted Ruby string literal for ``value``.
  result = "\""
  for c in value:
    case c
    of '"', '\\', '#': result.add("\\" & c)
    of '\x1E': result.add("\\x1E")
    else: result.add(c)
  result.add("\"")

proc runTool(selector: string; argv: seq[string]; env: StringTableRef;
             workingDir: string): tuple[exitCode: int; output: string] =
  ## Run ``argv`` with exactly ``env``, stdout and stderr together. Every
  ## program the step runs is named by an absolute path inside the staging
  ## prefix or a provisioned build tool's prefix, so it is started without
  ## a shell and without a ``PATH`` search.
  try:
    let res = execArgvExCloseOnce(argv, options = {poStdErrToStdOut},
      env = env, workingDir = workingDir)
    (exitCode: res.exitCode, output: res.output)
  except OSError, IOError, ValueError:
    fail(selector, "could not run " & argv[0] & ": " &
      getCurrentExceptionMsg())

proc outputTail(output: string; lines = 40): string =
  let all = output.strip().splitLines()
  all[max(0, all.len - lines) .. ^1].join("\n")

proc isUnderPrefix(path, prefix: string): bool =
  var p = normalizedPath(path.replace('\\', '/'))
  var r = normalizedPath(prefix.replace('\\', '/'))
  when defined(windows):
    p = p.toLowerAscii
    r = r.toLowerAscii
  p == r or p.startsWith(r & "/")

proc gemDirName(entry: GemClosureEntry): string =
  gemFileName(entry)[0 ..< gemFileName(entry).len - ".gem".len]

proc prunePath(path: string) =
  if fileExists(path) or symlinkExists(path):
    removeFile(path)

proc pruneBuildProducts(gemDir: string; entry: GemClosureEntry) =
  ## The intermediate products of one gem's extension build, and the
  ## RubyGems logs that record the build's working directory. The built
  ## ``.so`` files and the gem's own sources stay.
  let extRoot = gemDir / "gems" / gemDirName(entry) / "ext"
  if dirExists(extRoot):
    for path in walkDirRec(extRoot):
      let name = extractFilename(path)
      if name.endsWith(".o") or name in PrunedBuildProducts:
        prunePath(path)
  # RubyGems records the build arguments in ``build_info/<gem>.info`` (for
  # ``gem pristine``). Expanded, they name the build tools' realized
  # prefixes, which differ between hosts, so two hosts would otherwise build
  # different bytes under one key.
  prunePath(gemDir / "build_info" / (gemDirName(entry) & ".info"))
  let extensions = gemDir / "extensions"
  if dirExists(extensions):
    for platformDir in walkDirs(extensions / "*"):
      for abiDir in walkDirs(platformDir / "*"):
        let built = abiDir / gemDirName(entry)
        if dirExists(built):
          for path in walkDirRec(built):
            if extractFilename(path) in PrunedExtensionFiles:
              prunePath(path)

proc rewriteBinstubs(binDir, stagingPrefix: string) =
  ## A script RubyGems wrote whose ``#!`` line names the staging Ruby works
  ## only at the staging path. That line becomes ``#!/usr/bin/env ruby``,
  ## which is what RubyInstaller's own stubs carry. The ``#!`` line need not
  ## be the first: on Windows RubyGems writes a ``cmd``/``sh`` prolog above
  ## it (RubyInstaller's ``bin/rake``), and ``ruby -x`` starts at the
  ## ``#!``. Anything else that still names the staging path is left for
  ## the leak scan to refuse.
  if not dirExists(binDir):
    return
  var spellings = @[stagingPrefix, stagingPrefix.replace('\\', '/'),
                    stagingPrefix.replace('/', '\\')]
  when defined(windows):
    for item in spellings.mitems:
      item = item.toLowerAscii
  for kind, path in walkDir(binDir):
    if kind != pcFile:
      continue
    var text: string
    try:
      text = readFile(path)
    except IOError:
      continue
    if "#!" notin text:
      continue
    var lines = text.split('\n')
    var changed = false
    for line in lines.mitems:
      if not line.startsWith("#!"):
        continue
      var probe = line
      when defined(windows):
        probe = probe.toLowerAscii
      if spellings.anyIt(probe.contains(it)):
        line = "#!/usr/bin/env ruby" & (if line.endsWith("\r"): "\r" else: "")
        changed = true
    if changed:
      let permissions = getFilePermissions(path)
      writeFile(path, lines.join("\n"))
      setFilePermissions(path, permissions)

# ---------------------------------------------------------------------------
# C-runtime check
# ---------------------------------------------------------------------------

proc peImports*(objdumpOutput: string): seq[string] =
  ## The ``DLL Name:`` entries of an ``objdump -p`` listing of a PE file,
  ## lowercased, in order.
  for raw in objdumpOutput.splitLines():
    let line = raw.strip()
    if line.startsWith("DLL Name:"):
      result.add(line["DLL Name:".len .. ^1].strip().toLowerAscii)

proc crtImportRefusal*(imports: openArray[string]): string =
  ## Why a compiled extension with these imports is refused, or "" when it
  ## passes: it must import the UCRT, must not import ``msvcrt.dll``, and must
  ## not import a DLL of a library that is linked statically.
  var ucrt = false
  for name in imports:
    if name == "ucrtbase.dll" or name.startsWith("api-ms-win-crt-"):
      ucrt = true
    if name == "msvcrt.dll":
      return "imports msvcrt.dll; every extension uses the UCRT, the C " &
        "runtime of the Ruby it is loaded into"
    let base = name.changeFileExt("")
    for prefix in StaticOnlyLibraryPrefixes:
      if base == prefix or (base.startsWith(prefix) and base.len > prefix.len and
          base[prefix.len] in {'-', '_', '.', '0' .. '9'}):
        return "imports " & name & ", a library that is linked statically, " &
          "so the extension has no run-time DLL search for it"
  if not ucrt:
    return "imports neither ucrtbase.dll nor an api-ms-win-crt-* DLL"
  ""

proc checkCompiledExtensions*(selector: string; files: openArray[string];
                              objdump: string; env: StringTableRef = nil;
                              workingDir = "") =
  ## Run ``objdump -p`` on every file and refuse the first whose imports
  ## ``crtImportRefusal`` rejects, naming the file and the import. The
  ## C-runtime check of the step, separate so that it can be exercised on
  ## real PE files without a Windows host.
  let runEnv = if env.isNil: newStringTable(modeCaseSensitive) else: env
  if env.isNil:
    for key, value in envPairs():
      runEnv[key] = value
  let cwd = if workingDir.len > 0: workingDir else: getCurrentDir()
  for file in files:
    let listed = runTool(selector, @[objdump, "-p", file], runEnv, cwd)
    if listed.exitCode != 0:
      fail(selector, "objdump -p " & file & " exited " & $listed.exitCode &
        ":\n" & outputTail(listed.output))
    let refusal = crtImportRefusal(peImports(listed.output))
    if refusal.len > 0:
      fail(selector, "the compiled extension " & file & " " & refusal)

proc compiledExtensions(gemDir: string;
                        entries: openArray[GemClosureEntry]): seq[string] =
  ## Every ``.so`` / ``.dll`` the installed gems carry, in their gem
  ## directories and under ``extensions/``, sorted.
  var files: seq[string]
  for entry in entries:
    let root = gemDir / "gems" / gemDirName(entry)
    if dirExists(root):
      for path in walkDirRec(root):
        if path.toLowerAscii.endsWith(".so") or
            path.toLowerAscii.endsWith(".dll"):
          files.add(path)
    let extensions = gemDir / "extensions"
    if dirExists(extensions):
      for path in walkDirRec(extensions):
        if gemDirName(entry) in path.replace('\\', '/').split('/') and
            (path.toLowerAscii.endsWith(".so") or
             path.toLowerAscii.endsWith(".dll")):
          files.add(path)
  files.sort()
  files.deduplicate(isSorted = true)

# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------

proc buildEnvironment(ctx: PostExtractStepContext; ruby: string;
                      msysRoot: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  var path = @[parentDir(ruby)]
  var pkgConfigDirs: seq[string]
  for tool in ctx.tools:
    for dir in toolDirectories(tool):
      if dir notin path:
        path.add(dir)
    for sub in ["lib" / "pkgconfig", "share" / "pkgconfig"]:
      if tool.prefix.len > 0 and dirExists(tool.prefix / sub):
        pkgConfigDirs.add(tool.prefix / sub)
  for dir in systemDirectories():
    if dir notin path:
      path.add(dir)
  result["PATH"] = path.join($PathSep)
  let home = ctx.scratchDir / "home"
  let tmp = ctx.scratchDir / "tmp"
  createDir(home)
  createDir(tmp)
  result["HOME"] = home
  result["USERPROFILE"] = home
  result["TMP"] = tmp
  result["TEMP"] = tmp
  result["TMPDIR"] = tmp
  result["LANG"] = "C"
  when defined(windows):
    # The variables Windows programs cannot start without, which describe the
    # operating system rather than any configuration of Ruby or RubyGems.
    for name in ["SystemRoot", "SYSTEMDRIVE", "WINDIR", "COMSPEC", "PATHEXT",
                 "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "OS"]:
      if existsEnv(name):
        result[name] = getEnv(name)
  if msysRoot.len > 0:
    result["MSYS2_PATH"] = msysRoot
  if pkgConfigDirs.len > 0:
    result["PKG_CONFIG_LIBDIR"] = pkgConfigDirs.join($PathSep)
  for name in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
               "all_proxy", "ALL_PROXY"]:
    result[name] = DeadProxy

proc rubyQuery(selector, ruby, expression: string; env: StringTableRef;
               scratch: string): string =
  ## The value ``expression`` prints, bracketed by markers so that anything
  ## else the Ruby or a wrapper writes (a warning on stderr, say) cannot be
  ## mistaken for it.
  const Mark = "\x1Erepro-gem-closure\x1E"
  let query = runTool(selector, @[ruby, "-e",
    "print " & escapeRubyString(Mark) & "; " & expression & "; print " &
    escapeRubyString(Mark)], env, scratch)
  let first = query.output.find(Mark)
  let last = query.output.rfind(Mark)
  if query.exitCode != 0 or first < 0 or last <= first:
    fail(selector, "the prefix's Ruby could not report its configuration " &
      "(exit " & $query.exitCode & "):\n" & outputTail(query.output))
  query.output[first + Mark.len ..< last]

proc runGemClosureStep*(ctx: PostExtractStepContext) {.gcsafe.} =
  ## The registered implementation of ``gem-closure``. See the module
  ## comment for the contract.
  let selector = ctx.packageSelector
  var entries: seq[GemClosureEntry]
  for line in ctx.decl.stepData:
    if line.startsWith(GemClosureStepDataPrefix):
      entries.add(parseGemClosureManifestText(
        line[GemClosureStepDataPrefix.len .. ^1],
        "the gem closure of " & selector))
  var buildArgs: seq[GemBuildArgs]
  for line in ctx.decl.buildConfig:
    let parts = line.split('\t')
    if parts.len >= 1 and parts[0] != "substitutions":
      buildArgs.add(GemBuildArgs(gem: parts[0], args: parts[1 .. ^1]))
  let ruby = rubyExecutable(ctx.stagingPrefix)
  if ruby.len == 0:
    fail(selector, "the unpacked prefix has no bin/ruby.exe or bin/ruby")

  # 1. Fetch and verify every gem before anything is installed.
  let gemFiles = ctx.scratchDir / GemFetchDirectory
  createDir(gemFiles)
  if ctx.placeFile.isNil:
    fail(selector, "the provisioning edge supplied no verified fetch")
  for entry in entries:
    ctx.placeFile(ClosureEntry(path: GemFetchDirectory & "/" &
      gemFileName(entry), sha256: entry.sha256, url: entry.url,
      archiveType: ClosureFileKind, stripComponents: 0), ctx.scratchDir)

  # 2. The build environment, from the provisioned tools only.
  var msysRoot = ""
  var objdump = ""
  for tool in ctx.tools:
    if isMsysRoot(tool.prefix):
      if msysRoot.len > 0 and msysRoot != tool.prefix:
        fail(selector, "two build tools are MSYS roots (" & msysRoot &
          " and " & tool.prefix & "); declare one")
      msysRoot = tool.prefix
    for dir in toolDirectories(tool):
      for name in ["objdump.exe", "objdump"]:
        if objdump.len == 0 and fileExists(dir / name):
          objdump = dir / name
  if msysRoot.len > 0:
    for name in ["pacman.exe", "pacman"]:
      if fileExists(msysRoot / "usr" / "bin" / name):
        fail(selector, "the MSYS root " & msysRoot & " ships " & name &
          "; a pinned MSYS root carries no package manager, so that " &
          "nothing can install packages during the step")
  let env = buildEnvironment(ctx, ruby, msysRoot)

  # 3. The Ruby installs into the staging prefix, and nowhere else.
  for (what, expression) in [("Gem.default_dir", "print Gem.default_dir"),
                             ("Gem.dir", "print Gem.dir")]:
    let dir = rubyQuery(selector, ruby, expression, env, ctx.scratchDir)
    if not isUnderPrefix(dir, ctx.stagingPrefix):
      fail(selector, what & " is " & dir & ", outside the staging prefix " &
        ctx.stagingPrefix & "; the gems must be installed into the prefix")
  let gemDir = rubyQuery(selector, ruby, "print Gem.default_dir", env,
    ctx.scratchDir)
  let platform = rubyQuery(selector, ruby, "print RUBY_PLATFORM", env,
    ctx.scratchDir)
  let flags = rubyQuery(selector, ruby,
    "print RbConfig::MAKEFILE_CONFIG['CFLAGS'].to_s, \"\\n\", " &
    "RbConfig::MAKEFILE_CONFIG['CXXFLAGS'].to_s", env,
    ctx.scratchDir).splitLines()
  var prefixMap = "-ffile-prefix-map=" & ctx.stagingPrefix & "=."
  if ctx.stagingPrefix.contains('\\'):
    prefixMap.add(" -ffile-prefix-map=" &
      ctx.stagingPrefix.replace('\\', '/') & "=.")
  let cflags = (if flags.len > 0: flags[0] else: "").strip()
  let cxxflags = (if flags.len > 1: flags[1] else: "").strip()
  env["CONFIGURE_ARGS"] =
    "--with-cflags=" & shellQuote((cflags & " " & prefixMap).strip()) & " " &
    "--with-cxxflags=" & shellQuote((cxxflags & " " & prefixMap).strip())

  # 4.-5. Install, in manifest order, then normalise.
  for entry in entries:
    var argv = @[ruby, "-S", "gem", "install", "--local",
                 "--ignore-dependencies", "--no-document", "--norc",
                 "--no-user-install",
                 gemFiles / gemFileName(entry)]
    for item in buildArgs:
      if item.gem == entry.name and item.args.len > 0:
        argv.add("--")
        for arg in item.args:
          argv.add(expandPrefixReferences(arg, ctx.tools))
    let installed = runTool(selector, argv, env, ctx.scratchDir)
    if installed.exitCode != 0:
      fail(selector, "installing " & gemFileName(entry) & " exited " &
        $installed.exitCode & ":\n" & outputTail(installed.output))
    if "Installing required msys2 packages" in installed.output or
        "> pacman " in installed.output:
      fail(selector, "installing " & gemFileName(entry) & " ran MSYS2's " &
        "package manager:\n" & outputTail(installed.output))
    let spec = gemDir / "specifications" / (gemDirName(entry) & ".gemspec")
    if not fileExists(spec):
      fail(selector, "installing " & gemFileName(entry) & " left no " &
        "specification at " & spec & " (RubyGems installed it somewhere " &
        "else):\n" & outputTail(installed.output))
    pruneBuildProducts(gemDir, entry)
    rewriteBinstubs(ctx.stagingPrefix / "bin", ctx.stagingPrefix)

  # 6. One C runtime.
  if "mingw" in platform:
    if objdump.len == 0:
      fail(selector, "the Ruby is a MinGW build (" & platform & "), and " &
        "no build tool provides objdump to check the compiled extensions' " &
        "C runtime; declare the toolchain in gemBuildUses")
    checkCompiledExtensions(selector, compiledExtensions(gemDir, entries),
      objdump, env, ctx.scratchDir)

registerPostExtractStep(GemClosureStepKind, runGemClosureStep)
registerPostExtractDeclProvider(GemClosureStepKind,
  proc(use: InterfaceToolUse; record: InterfaceTarballProvisioning):
      PostExtractStepDecl {.gcsafe.} =
    {.cast(gcsafe).}:
      result = gemClosureDeclFor(use, record))
