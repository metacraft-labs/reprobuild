## A tarball arm's gem-closure step installs a pinned gem closure into the
## realized Ruby prefix: every gem verified against its SHA-256, offline, in
## manifest order, with native extensions compiled by provisioned tools, in
## an environment built from scratch, and the result is a portable,
## deterministic prefix.
##
## Cases:
##
##   1. A three-gem closure realizes: `fxdep` (pure), `fxnative` (a C
##      extension whose `extconf.rb` requires `fxdep` at build time, so it
##      builds only if the manifest order is honoured, and which aborts if any
##      host Ruby configuration reached it) and `fxtool` (an executable, whose
##      binstub names the staging Ruby until the step rewrites it). The
##      extension is built by a toolchain that is itself a provisioned
##      package, compiled with `-g` so that its debug information would carry
##      the staging path without the step's prefix map. The prefix holds the
##      three specifications and the built extension, none of the build's
##      intermediate products, a relocatable binstub, a complete cache key,
##      and works: its own Ruby loads the extension.
##   2. No ambient state, two store roots. Host A realizes with a hostile
##      environment (`GEM_HOME`, `GEM_PATH`, `RUBYOPT` naming a library that
##      does not exist, `BUNDLE_GEMFILE`, a `~/.gemrc` asking for a user
##      install, a proxy); host B, at a different store root, realizes with
##      none of it. The prefixes are byte-identical and carry the same key.
##   3. A corrupted gem digest fails provisioning before anything is
##      installed, never reaches the network or a fallback, and seals
##      nothing.
##   4. A Ruby whose default gem directory is outside the prefix fails the
##      edge rather than installing somewhere else.
##
## Mocks, justified:
##
##   * The "RubyInstaller" archive is a fixture: a `bin/ruby` that runs the
##     dev shell's Nix Ruby with a `rubygems/defaults/operating_system.rb`
##     pointing the default gem directory, binstub directory and `Gem.ruby`
##     at the prefix -- which is what a relocatable RubyInstaller prefix does
##     by itself. The step under test is platform-neutral except for the
##     Windows C-runtime check, which `t_gem_closure_crt_check` covers on
##     real PE files; a real RubyInstaller needs a Windows host.
##   * The gems are built by the test with `gem build` and placed in the tool
##     store's download cache under their digests; their URLs name
##     `gems.invalid`, which cannot resolve. A realization that tried the
##     network for any gem would fail, so success shows that none did, and
##     the corrupted-digest case shows that a mismatch reaches no fallback.
##   * The toolchain package's `gcc` and `make` run the dev shell's real
##     compiler and make; nothing is simulated.
##
## No other mocks: the real tarball provisioning edge, the real step, the
## real RubyGems and mkmf, the real leak scan and identity file.

import std/[algorithm, os, osproc, sequtils, strtabs, strutils, tempfiles,
            unittest]

import repro_interface_artifacts
import repro_tool_profiles

const RubyApi = "3.4.0"

proc realPath(path: string): string =
  result = path
  for _ in 0 ..< 16:
    if not symlinkExists(result):
      break
    let target = expandSymlink(result)
    result = if target.isAbsolute: target else: result.parentDir / target

proc makeExecutable(path, body: string) =
  createDir(path.parentDir)
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc run(argv: seq[string]; dir: string): string =
  let res = execCmdEx(quoteShellCommand(argv), workingDir = dir)
  doAssert res.exitCode == 0, argv.join(" ") & "\n" & res.output
  res.output

proc tarGz(source, top, archive: string) =
  discard run(@[findExe("tar"), "-czf", archive, "-C", source, top], source)

proc fileUrl(path: string): string = "file://" & path

type Fixture = object
  root: string
  ruby: string
  sdkArchive, badSdkArchive, ccArchive: string
  gems: seq[tuple[name, file, sha: string]]

proc operatingSystemRb(redirect: bool): string =
  ## The fixture prefix's RubyGems defaults. With ``redirect`` it does what
  ## a relocatable prefix does: the default gem directory, the binstub
  ## directory and ``Gem.ruby`` are the prefix's own. (``user_dir`` is
  ## pointed there too: the Nix Ruby is patched to prefer it over the
  ## default directory.) Without it, the gem directory stays inside the Nix
  ## store -- outside any prefix.
  if not redirect:
    return "# no relocation\n"
  "module Gem\n" &
  "  FX_PREFIX = File.expand_path(\"../../../..\", __dir__)\n" &
  "  def self.default_dir; File.join(FX_PREFIX, \"lib\", \"ruby\", \"gems\", \"" &
    RubyApi & "\"); end\n" &
  "  def self.user_dir; default_dir; end\n" &
  "  def self.default_bindir; File.join(FX_PREFIX, \"bin\"); end\n" &
  "  def self.ruby; File.join(FX_PREFIX, \"bin\", \"ruby\"); end\n" &
  # RubyGems writes `#!/usr/bin/env ruby` stubs by default. A distribution
  # configured otherwise gets `#!<Gem.ruby>`, the staging Ruby: the case
  # the step's binstub rewrite exists for, made the fixture's default.
  "  def self.operating_system_defaults; " &
    "{ \"install\" => \"--no-env-shebang\" }; end\n" &
  "end\n"

proc makeSdk(root, top, ruby, gemScript: string; redirect: bool): string =
  let tree = root / ("src-" & top) / top
  makeExecutable(tree / "bin" / "ruby",
    # No `dirname`: the step's PATH holds only the prefix and its tools.
    "#!/bin/sh\nhere=\"${0%/bin/ruby}\"\n" &
    "exec " & ruby & " -I\"$here/lib/fx-site\" \"$@\"\n")
  makeExecutable(tree / "bin" / "gem", readFile(gemScript))
  createDir(tree / "lib" / "fx-site" / "rubygems" / "defaults")
  writeFile(tree / "lib" / "fx-site" / "rubygems" / "defaults" /
    "operating_system.rb", operatingSystemRb(redirect))
  createDir(tree / "lib" / "ruby" / "gems" / RubyApi / "specifications")
  writeFile(tree / "lib" / "ruby" / "gems" / RubyApi / "specifications" /
    ".keep", "")
  result = root / (top & ".tar.gz")
  tarGz(root / ("src-" & top), top, result)

proc buildGem(root, name: string; files: openArray[(string, string)];
              extra = ""): tuple[name, file, sha: string] =
  let dir = root / "gem-src" / name
  var listed: seq[string]
  for (path, body) in files:
    createDir((dir / path).parentDir)
    writeFile(dir / path, body)
    listed.add("\"" & path & "\"")
  writeFile(dir / (name & ".gemspec"),
    "Gem::Specification.new do |s|\n" &
    "  s.name = \"" & name & "\"; s.version = \"1.0.0\"\n" &
    "  s.summary = \"fixture\"; s.authors = [\"fixture\"]\n" &
    "  s.files = [" & listed.join(", ") & "]\n" & extra & "end\n")
  discard run(@[findExe("gem"), "build", name & ".gemspec"], dir)
  let file = dir / (name & "-1.0.0.gem")
  (name: name, file: file, sha: fileSha256Hex(file))

proc createFixture(root: string): Fixture =
  result.root = root
  result.ruby = realPath(findExe("ruby"))
  let gemScript = realPath(findExe("gem"))
  result.sdkArchive = makeSdk(root, "fx-ruby", result.ruby, gemScript, true)
  result.badSdkArchive = makeSdk(root, "fx-ruby-bad", result.ruby, gemScript,
    false)
  let cc = root / "src-cc" / "fx-cc"
  makeExecutable(cc / "bin" / "gcc",
    "#!/bin/sh\nexec " & realPath(findExe("gcc")) & " \"$@\"\n")
  makeExecutable(cc / "bin" / "make",
    "#!/bin/sh\nexec " & realPath(findExe("make")) & " \"$@\"\n")
  result.ccArchive = root / "fx-cc.tar.gz"
  tarGz(root / "src-cc", "fx-cc", result.ccArchive)
  result.gems.add(buildGem(root, "fxdep",
    [("lib/fxdep.rb", "FXDEP = \"dependency\"\n")]))
  result.gems.add(buildGem(root, "fxnative", [
    ("ext/fxnative/extconf.rb",
     "require \"mkmf\"\n" &
     # Installed earlier by the manifest's order, with no dependency
     # resolution: this require is what fails if the order is not honoured.
     "require \"fxdep\"\n" &
     "abort \"host GEM_HOME reached extconf\" if ENV[\"GEM_HOME\"]\n" &
     "abort \"host GEM_PATH reached extconf\" if ENV[\"GEM_PATH\"]\n" &
     "abort \"host RUBYOPT reached extconf\" if ENV[\"RUBYOPT\"]\n" &
     "abort \"host BUNDLE_GEMFILE reached extconf\" if ENV[\"BUNDLE_GEMFILE\"]\n" &
     "abort \"host FX_LEAK reached extconf\" if ENV[\"FX_LEAK\"]\n" &
     "abort \"proxy not pinned\" unless ENV[\"http_proxy\"] == \"http://127.0.0.1:9\"\n" &
     "dir = with_config(\"fx-cc-dir\")\n" &
     "abort \"no fx-cc-dir\" unless dir && File.exist?(File.join(dir, \"bin\", \"gcc\"))\n" &
     "$CFLAGS << \" -g\"\n" &
     "create_makefile(\"fxnative/fxnative\")\n"),
    ("ext/fxnative/fxnative.c",
     "#include <ruby.h>\n" &
     "static VALUE hello(VALUE self) { return rb_str_new_cstr(\"hello from \" __FILE__); }\n" &
     "void Init_fxnative(void) { rb_define_global_function(\"fxnative_hello\", hello, 0); }\n"),
    ("lib/fxnative.rb", "require \"fxnative/fxnative\"\n")],
    extra = "  s.extensions = [\"ext/fxnative/extconf.rb\"]\n"))
  result.gems.add(buildGem(root, "fxtool",
    [("bin/fxtool", "puts \"fxtool\"\n"), ("lib/fxtool.rb", "\n")],
    extra = "  s.executables = [\"fxtool\"]\n"))

proc manifestText(fx: Fixture; corrupt = ""): string =
  result = "# fixture closure; line order is install order\n\n"
  for gem in fx.gems:
    let sha = if gem.name == corrupt: "0".repeat(64) else: gem.sha
    result.add(gem.name & " 1.0.0 ruby " & sha &
      " https://gems.invalid/gems/" & gem.name & "-1.0.0.gem\n")

proc ccUse(fx: Fixture): InterfaceToolUse =
  var record = InterfaceTarballProvisioning(url: fileUrl(fx.ccArchive),
    sha256: fileSha256Hex(fx.ccArchive), archiveType: "tar.gz",
    executablePath: "bin/gcc", stripComponents: 1, cpu: "any", os: "any",
    packageId: "fx-cc@1")
  record.detail.version = "1"
  InterfaceToolUse(rawConstraint: "fx-cc", packageSelector: "fx-cc",
    executableName: "gcc", tarballProvisioning: @[record])

proc sdkUse(fx: Fixture; manifest: string; bad = false): InterfaceToolUse =
  let archive = if bad: fx.badSdkArchive else: fx.sdkArchive
  let selector = if bad: "fx-ruby-bad" else: "fx-ruby"
  var record = InterfaceTarballProvisioning(url: fileUrl(archive),
    sha256: fileSha256Hex(archive), archiveType: "tar.gz",
    executablePath: "bin/ruby", stripComponents: 1, cpu: "any", os: "any",
    packageId: selector & "@1",
    gemClosure: manifest,
    gemBuildUses: @[ccUse(fx)],
    gemBuildArgs: @[GemBuildArgs(gem: "fxnative",
      args: @["--with-fx-cc-dir=$REPRO_PREFIX_FX_CC"])])
  record.detail.version = "1"
  InterfaceToolUse(rawConstraint: selector, packageSelector: selector,
    executableName: "ruby", tarballProvisioning: @[record])

proc seedDownloads(fx: Fixture; storeRoot: string) =
  ## The gems, in the tool store's download cache under their digests, the
  ## only place a realization can find them.
  createDir(storeRoot / "downloads")
  for gem in fx.gems:
    copyFile(gem.file, storeRoot / "downloads" / (gem.sha & ".archive"))

proc treeContents(root: string): seq[string] =
  for path in walkDirRec(root, relative = true):
    if path.extractFilename == ".repro-receipt":
      continue
    result.add(path & "\0" & readFile(root / path))
  result.sort()

proc withEnv(vars: openArray[(string, string)]; body: proc ()) =
  var saved: seq[(string, string, bool)]
  for (key, value) in vars:
    saved.add((key, getEnv(key), existsEnv(key)))
    putEnv(key, value)
  try:
    body()
  finally:
    for (key, value, existed) in saved:
      if existed: putEnv(key, value) else: delEnv(key)

proc cleanup(root: string) =
  for p in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

suite "gem-closure step: offline install into a provisioned Ruby prefix":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let root = createTempDir("repro-gem-closure-", "")
  let fx = createFixture(root)
  let manifest = root / "fx-gems.manifest"
  writeFile(manifest, manifestText(fx))

  test "a three-gem closure installs in order, offline, and is portable":
    let store = root / "host-a" / "store"
    seedDownloads(fx, store)
    var prefix = ""
    let fakeHome = root / "hostile-home"
    createDir(fakeHome)
    writeFile(fakeHome / ".gemrc", "install: --user-install\ngem: --user-install\n")
    withEnv([("GEM_HOME", root / "host-gem-home"),
             ("GEM_PATH", root / "host-gem-path"),
             ("RUBYOPT", "-rfixture-library-that-does-not-exist"),
             ("BUNDLE_GEMFILE", root / "Gemfile"),
             ("FX_LEAK", "1"),
             ("HOME", fakeHome),
             ("http_proxy", "http://proxy.invalid:3128")]) do ():
      prefix = resolveTarballTool(sdkUse(fx, manifest), store).
        selectedStorePath
    let gemDir = prefix / "lib" / "ruby" / "gems" / RubyApi
    for gem in fx.gems:
      check fileExists(gemDir / "specifications" / (gem.name & "-1.0.0.gemspec"))
    check fileExists(gemDir / "gems" / "fxnative-1.0.0" / "lib" / "fxnative" /
      "fxnative.so")
    # Nothing went to the hostile GEM_HOME or a user directory.
    check not dirExists(root / "host-gem-home")
    check not dirExists(fakeHome / ".local")
    check not dirExists(fakeHome / ".gem")
    # The build's intermediate products and logs are pruned.
    for path in walkDirRec(gemDir):
      let name = path.extractFilename
      check not name.endsWith(".o")
      check name notin ["Makefile", "mkmf.log", "extconf.h", "gem_make.out"]
    # The binstub RubyGems wrote named the staging Ruby; it is relocatable.
    let stub = prefix / "bin" / "fxtool"
    check fileExists(stub)
    check readFile(stub).splitLines()[0] == "#!/usr/bin/env ruby"
    # A complete key: every input, the toolchain included, has an identity.
    let sealed = readPrefixIdentityFile(prefix)
    check sealed.found
    check sealed.keyHex.len == 64
    check sealed.incomplete.len == 0
    # The prefix works: its own Ruby loads the compiled extension.
    let loaded = execCmdEx(quoteShellCommand(@[prefix / "bin" / "ruby", "-e",
      "require \"fxnative\"; print fxnative_hello"]),
      env = newStringTable({"PATH": "/usr/bin:/bin"}, modeCaseSensitive))
    checkpoint loaded.output
    check loaded.exitCode == 0
    check loaded.output.strip() == "hello from fxnative.c"

  test "two store roots, with and without host state, give byte-identical prefixes":
    let a = resolveTarballTool(sdkUse(fx, manifest), root / "host-a" / "store").
      selectedStorePath
    let storeB = root / "elsewhere" / "deeper" / "host-b" / "store"
    seedDownloads(fx, storeB)
    let b = resolveTarballTool(sdkUse(fx, manifest), storeB).selectedStorePath
    check a != b
    check readPrefixIdentityFile(b).keyHex == readPrefixIdentityFile(a).keyHex
    let (treeA, treeB) = (treeContents(a), treeContents(b))
    for entry in treeA:
      if entry notin treeB:
        checkpoint "differs: " & entry.split('\0')[0]
    check treeB == treeA

  test "a corrupted gem digest fails before any install and seals nothing":
    let corrupt = root / "corrupt.manifest"
    writeFile(corrupt, manifestText(fx, corrupt = "fxtool"))
    let store = root / "host-c" / "store"
    seedDownloads(fx, store)
    var message = ""
    try:
      discard resolveTarballTool(sdkUse(fx, corrupt), store)
    except CatchableError as err:
      message = err.msg
    checkpoint message
    check "gems.invalid/gems/fxtool-1.0.0.gem" in message
    # Nothing was sealed for the SDK.
    if dirExists(store / "prefixes"):
      for kind, dir in walkDir(store / "prefixes"):
        check not lastPathPart(dir).startsWith("fx-ruby")
    # The same bytes under a digest the manifest does declare, but mangled:
    # the cached file is discarded and the realization still never falls
    # back to anything.
    let mangled = root / "host-d" / "store"
    seedDownloads(fx, mangled)
    let fxtool = fx.gems[2]
    writeFile(mangled / "downloads" / (fxtool.sha & ".archive"), "not a gem")
    message = ""
    try:
      discard resolveTarballTool(sdkUse(fx, manifest), mangled)
    except CatchableError as err:
      message = err.msg
    checkpoint message
    check "fxtool-1.0.0.gem" in message

  test "a Ruby whose default gem directory is outside the prefix fails the edge":
    let store = root / "host-e" / "store"
    seedDownloads(fx, store)
    var message = ""
    try:
      discard resolveTarballTool(sdkUse(fx, manifest, bad = true), store)
    except CatchableError as err:
      message = err.msg
    checkpoint message
    check "outside the staging prefix" in message

  cleanup(root)
