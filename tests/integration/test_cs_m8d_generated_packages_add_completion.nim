## Every package reprobuild generates carries the shell completion of each
## packaged executable that has a `cli:` description, with nothing declared by
## the package author (the Linux formats: .deb, .rpm, Arch, tarball, AppImage
## and the installed prefix).
##
## The fixture package (`tests/fixtures/cs_m8d_generated_packages`, copied to
## a scratch directory so it is a project outside this tree) builds one
## program, `csm8d-tool`, with `nim.c`, and hands its binary to each producer
## as an ordinary executable component. Its recipe says nothing about
## completion. Each case runs the real `repro build` on it and reads every
## package back with that format's own tools:
##
##   1. **Native.** Each package holds the Bash, Zsh and Fish scripts at its
##      format's locations (`dpkg-deb -c` and the data tar for the .deb,
##      `rpm -qlp` and `bsdtar` for the .rpm, `bsdtar` for the Arch package
##      and the tarball, `unsquashfs` over the AppImage's embedded squashfs,
##      the directory for the prefix, assembled but not put through its
##      builder-path gate: a cross image keeps debug info that names
##      build-host paths, which that gate refuses, a separate defect; its
##      binary names the triple's system loader in `PT_INTERP` whichever C
##      compiler on `PATH` linked it, the dev shell's Nix gcc included),
##      each byte-equal to what the built
##      program prints for `--printCompletion=<shell>`, and no PowerShell
##      script (no Linux format has a place PowerShell reads one from).
##   2. **Cross-compiled.** With `--target=armv7-unknown-linux-gnueabihf`
##      (through the zig cross toolchain), the binary is an ARM executable the
##      build host cannot run (the case runs it to make sure, and skips,
##      saying why, on a host that can); the .deb, the tarball and the prefix still carry
##      the three scripts, byte-equal to the native ones, and the completion
##      files are written under `build@<triple>/completions/`, never under the
##      native `build/completions/`.
##   3. **Opt-out.** With `omitShellCompletion = true` (on the `Distribution`
##      and on the prefix spec), every package is built and holds the binary,
##      and none holds a completion file.
##   4. **Negative control.** With the `cli:` section removed, every package
##      is built and holds the binary, and none holds a completion file.
##
## Each case's control is the other cases: the same recipe, with one thing
## changed, builds packages that differ only in the completion files. The
## mutations that fail the cases (producers' `addShellCompletion` calls
## removed one at a time, the opt-out check removed, the target keying
## removed) were each run against this file and fail the case they name.
##
## Tools. The build runs with `--tool-provisioning=path`, so every tool the
## producers name comes from `PATH`: `dpkg-deb`, `rpmbuild` (and `rpm` to read
## the package back), `bsdtar`, `appimagetool`, `unsquashfs`, `patchelf`,
## `readelf`, `zig` and the C toolchain. Two have no executable of their name
## and are given as path-mode sidecars, the format the resolver reads
## (`<selector>.repro-tool-profile` naming `resolvedExecutablePath`):
## `install-file` (the host's `install`) and `appimage-runtime` (a
## `runtime-x86_64` on `PATH`). Without them a case is skipped, except in a
## gate run (`REPROBUILD_GATE_RUN=1`), where it fails.
##
## clispec is found as this repository's `config.nims` finds it (the
## `../nim-cli-spec` checkout, else `$CLI_SPEC_SRC`; `REPRO_SIBLING_POLICY=pin`
## takes the variable even when the checkout exists).
##
## MOCKS: none. The real `repro` of this build compiles the fixture's recipe
## and the program with the real Nim, runs the real `repro-completion-files`
## and the real packaging tools; the sidecars only tell path mode where two
## real files are.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_core/process_env
import repro_test_support
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m8d_generated_packages"
  Program = "csm8d-tool"
  Shells = ["bash", "zsh", "fish"]
  CrossTriple = "armv7-unknown-linux-gnueabihf"
  AllFormats = ["deb", "rpm", "arch", "tarball", "appimage", "prefix"]
  CrossFormats = ["deb", "tarball", "prefix"]
  CliSection = """    cli:
      help "The fixture's program with a command-line description"
      flag printCompletion is string, default = "",
        help = "Print this shell's completion script"
"""
  RequiredTools = ["sh", "gcc", "nim", "zig", "install", "patchelf",
    "readelf", "tar", "gzip", "dpkg-deb", "rpmbuild", "rpm", "find", "diff",
    "sed", "grep", "bsdtar", "appimagetool", "runtime-x86_64", "file",
    "unsquashfs"]

proc siblingSrc(sibling, variable, marker: string): string =
  ## A sibling's `src/`, as this repository's `config.nims` finds it.
  let pinned = getEnv(variable)
  if getEnv("REPRO_SIBLING_POLICY") == "pin" and pinned.len > 0:
    return pinned
  let checkout = ReprobuildRepoRoot.parentDir / sibling / "src"
  if fileExists(checkout / marker):
    return checkout
  pinned

proc unmetPrecondition(): string =
  ## Why the cases cannot run here, or "".
  for tool in RequiredTools:
    if findExe(tool).len == 0:
      return tool & " is not on PATH"
  ""

template requirePreconditions(body: untyped) =
  let unmet = unmetPrecondition()
  if unmet.len > 0 and getEnv("REPROBUILD_GATE_RUN") == "1":
    checkpoint(unmet & " in a gate run")
    check false
  elif unmet.len > 0:
    skip(unmet & "; the packages are built and read back with that tool")
  else:
    body

# ---------------------------------------------------------------------------
# Where each format puts each shell's file: the same table as the producers'
# `systemShellCompletionLayout` / `prefixShellCompletionLayout` calls and
# the user documentation, written out here so a producer that moved a file
# fails the test.
# ---------------------------------------------------------------------------

proc fileName(shell: string): string =
  case shell
  of "bash": Program
  of "zsh": "_" & Program
  else: Program & ".fish"

proc expectedPaths(format: string): seq[string] =
  ## The paths inside `format`'s package, relative to its root, of the
  ## Bash, Zsh and Fish files, in `Shells` order.
  let dirs =
    case format
    of "deb": ["usr/share/bash-completion/completions",
               "usr/share/zsh/vendor-completions",
               "usr/share/fish/vendor_completions.d"]
    of "rpm", "arch", "appimage": ["usr/share/bash-completion/completions",
               "usr/share/zsh/site-functions",
               "usr/share/fish/vendor_completions.d"]
    else: ["share/bash-completion/completions", "share/zsh/site-functions",
           "share/fish/vendor_completions.d"]
  for i, shell in Shells:
    result.add(dirs[i] & "/" & fileName(shell))

proc binaryPath(format: string): string =
  ## Where `format`'s package holds the binary.
  case format
  of "deb", "rpm", "arch", "appimage": "usr/bin/" & Program
  else: "bin/" & Program

type Project = object
  scratch: string
  root: string
  tools: string

proc projectWith(formats: openArray[string]; cli = true;
                 omit = false): Project =
  ## A scratch copy of the fixture with its placeholders filled in.
  let clispec = siblingSrc("nim-cli-spec", "CLI_SPEC_SRC", "clispec.nim")
  doAssert fileExists(clispec / "clispec.nim"), "nim-cli-spec not found: " &
    "no ../nim-cli-spec beside this checkout and no $CLI_SPEC_SRC"
  result.scratch = expandFilename(createTempDir("cs-m8d-packages-", ""))
  releaseDirAtProcessExit(result.scratch)
  result.root = result.scratch / "project"
  createDir(result.root / "src")
  var quoted: seq[string]
  for f in formats:
    quoted.add("\"" & f & "\"")
  var recipe = readFile(FixtureDir / "repro.nim")
    .replace("__CLISPEC_SRC__", clispec)
    .replace("__REPRO_DSL_SRC__",
      ReprobuildRepoRoot / "libs" / "repro_project_dsl" / "src")
    .replace("__FORMATS__", quoted.join(", "))
    .replace("__OMIT_COMPLETION__", $omit)
  doAssert CliSection in recipe
  if not cli:
    recipe = recipe.replace(CliSection, "")
  writeFile(result.root / "repro.nim", recipe)
  for kind, path in walkDir(FixtureDir / "src"):
    if kind == pcFile:
      copyFile(path, result.root / "src" / path.extractFilename)
  # The path-mode sidecars (see the header).
  result.tools = result.scratch / "path-tools"
  createDir(result.tools)
  # The link, not what it points to: a multi-call coreutils's `install` is
  # a symlink to `coreutils`, which dispatches on the name it is run as.
  writeFile(result.tools / "install-file.repro-tool-profile",
    "reprobuild-tool-profile-v1\nresolvedExecutablePath=" &
    findExe("install", followSymlinks = false) & "\n")
  writeFile(result.tools / "appimage-runtime.repro-tool-profile",
    "reprobuild-tool-profile-v1\nresolvedExecutablePath=" &
    findExe("runtime-x86_64") & "\n")

proc reproBuild(p: Project; label: string; args: openArray[string] = []):
    tuple[code: int; output: string] =
  ## `repro build [args]` in the project, with this checkout's `repro`.
  let repoRoot = ReprobuildRepoRoot
  let reproBin = requireBinary(reproBinaryPath(repoRoot),
    "reprobuild.apps.repro")
  discard requireBinary(repoRoot / "build" / "bin" /
    addFileExt("repro-completion-files", ExeExt),
    "reprobuild.apps.repro-completion-files")
  let shim = requireBinary(monitorShimPath(repoRoot),
    "reprobuild.test_fixtures.monitor_shim")
  # The host's names, whatever their case rules (`repro_core/process_env`).
  let env = inheritedEnvTable()
  env["REPROBUILD_REPO_ROOT"] = repoRoot
  env["REPROBUILD_LIBS_DIR"] = repoRoot / "libs"
  env["REPRO_MONITOR_SHIM_LIB"] = shim
  env["REPRO_LOCAL_STORE"] = p.scratch / "store"
  env["REPRO_STORE_ROOT"] = p.scratch / "cas"
  env["REPRO_CACHE_DISABLE"] = "1"
  env.del("REPRO_VARIANTS")
  env.del("LD_PRELOAD")
  env["PATH"] = reproBin.parentDir & PathSep & p.tools & PathSep &
    getEnv("PATH")
  var argv = @["build", "--daemon=off", "--tool-provisioning=path",
    "--no-runquota", "--progress=quiet",
    "--work-root=" & (p.scratch / "work"),
    "--action-cache-root=" & (p.scratch / "cache")]
  argv.add(@args)
  # The fixture's collection of every package (see its header).
  argv.add(".#packages")
  let run = runProgramSplit(reproBin, argv, p.root, env)
  checkpoint(label & ": repro " & argv.join(" ") & " -> exit " & $run.code)
  if run.code != 0:
    checkpoint(run.stdout & run.stderr)
  (run.code, run.stdout & run.stderr)

# ---------------------------------------------------------------------------
# Reading the packages back, with each format's own tools.
# ---------------------------------------------------------------------------

proc run(cmd: string): string =
  let (output, code) = execCmdEx(cmd)
  checkpoint(cmd & " -> exit " & $code)
  doAssert code == 0, cmd & " failed:\n" & output
  output

proc onlyFile(dir, suffix: string): string =
  ## The one file in `dir` whose name ends with `suffix`.
  var found: seq[string]
  if dirExists(dir):
    for kind, path in walkDir(dir):
      # An Arch package's `.pkg.tar.gz` is not the tarball.
      if kind == pcFile and path.endsWith(suffix) and
          (suffix != ".tar.gz" or not path.endsWith(".pkg.tar.gz")):
        found.add(path)
  doAssert found.len == 1, "expected one *" & suffix & " in " & dir &
    ", found " & $found
  found[0]

proc squashfsOffset(path: string): int =
  ## Where an AppImage's squashfs starts: the end of its ELF runtime, read
  ## from the ELF64 header (section headers last), without running it.
  let head = readFile(path)
  doAssert head.len > 64 and head.startsWith("\x7fELF") and head[4] == '\x02'
  proc u16(at: int): int = int(uint8(head[at])) or (int(uint8(head[at + 1])) shl 8)
  var shoff = 0
  for i in countdown(7, 0):
    shoff = (shoff shl 8) or int(uint8(head[0x28 + i]))
  shoff + u16(0x3A) * u16(0x3C)

type PackageView = object
  ## A package read back: the paths it holds (relative, no leading `./` or
  ## `/`), and a way to read one file's bytes.
  format: string
  paths: seq[string]
  extracted: string
    ## A directory holding the package's tree, for the formats read by
    ## extraction.

proc normalized(line: string): string =
  result = line.strip()
  if result.startsWith("./"): result = result[2 .. ^1]
  elif result.startsWith("/"): result = result[1 .. ^1]
  result = result.strip(leading = false, chars = {'/'})

proc readPackage(p: Project; format, scratch: string): PackageView =
  result.format = format
  let dist = p.root / "build" / "dist"
  result.extracted = scratch / ("extract-" & format)
  createDir(result.extracted)
  let q = quoteShell(result.extracted)
  case format
  of "deb":
    let deb = onlyFile(dist, ".deb")
    # The member list, from the format's own tool.
    for line in run("dpkg-deb -c " & quoteShell(deb)).splitLines():
      let fields = line.splitWhitespace()
      if fields.len >= 6:
        result.paths.add(normalized(fields[5]))
    discard run("dpkg-deb -x " & quoteShell(deb) & " " & q)
  of "rpm":
    let rpm = onlyFile(dist, ".rpm")
    for line in run("rpm -qlp " & quoteShell(rpm)).splitLines():
      if line.strip().len > 0:
        result.paths.add(normalized(line))
    discard run("bsdtar -xf " & quoteShell(rpm) & " -C " & q)
  of "arch":
    let pkg = onlyFile(dist, ".pkg.tar.gz")
    for line in run("bsdtar -tf " & quoteShell(pkg)).splitLines():
      if line.strip().len > 0:
        result.paths.add(normalized(line))
    discard run("bsdtar -xf " & quoteShell(pkg) & " -C " & q)
  of "tarball":
    let tgz = onlyFile(dist, ".tar.gz")
    for line in run("bsdtar -tf " & quoteShell(tgz)).splitLines():
      if line.strip().len > 0:
        result.paths.add(normalized(line))
    discard run("bsdtar -xf " & quoteShell(tgz) & " -C " & q)
  of "appimage":
    let image = onlyFile(dist, ".AppImage")
    let offset = squashfsOffset(image)
    for line in run("unsquashfs -o " & $offset & " -l -d '' " &
        quoteShell(image)).splitLines():
      if line.strip().len > 0:
        result.paths.add(normalized(line))
    removeDir(result.extracted)
    discard run("unsquashfs -o " & $offset & " -d " & q & " " &
      quoteShell(image))
  of "prefix":
    var prefixDir = ""
    for kind, path in walkDir(p.root):
      if kind == pcDir and path.extractFilename.startsWith("build"):
        if dirExists(path / "prefix"): prefixDir = path / "prefix"
    doAssert prefixDir.len > 0, "no installed prefix under " & p.root
    # The assembly made the binary name the triple's system loader, not the
    # one of the toolchain that linked it (a Nix gcc's store glibc).
    let keyed = prefixDir.parentDir.extractFilename
    let loader = if keyed == "build": "/lib64/ld-linux-x86-64.so.2"
                 else: "/lib/ld-linux-armhf.so.3"
    check ("[Requesting program interpreter: " & loader & "]") in
      run("readelf -l -W " & quoteShell(prefixDir / binaryPath(format)))
    removeDir(result.extracted)
    copyDir(prefixDir, result.extracted)
    for path in walkDirRec(result.extracted, relative = true):
      result.paths.add(path.replace('\\', '/'))
  else:
    doAssert false, format

proc fileText(view: PackageView; rel: string): string =
  let path = view.extracted / rel
  doAssert fileExists(path), view.format & ": no " & rel & " extracted"
  readFile(path)

proc completionPaths(view: PackageView): seq[string] =
  ## Every path in the package that looks like a completion file.
  for path in view.paths:
    if "completion" in path or "site-functions" in path or
        path.endsWith(".ps1"):
      if not path.endsWith("/") and path.extractFilename.contains(Program):
        result.add(path)

proc printedScript(binary, shell: string): string =
  ## What the built program prints as its completion script for `shell`.
  let run = runProgramSplit(binary, ["--printCompletion=" & shell], "",
    newEnvTable())
  checkpoint(binary & " --printCompletion=" & shell & " -> exit " &
    $run.code & " " & run.stderr)
  doAssert run.code == 0
  run.stdout

proc checkCarries(view: PackageView; expected: openArray[string]) =
  ## `view` holds the binary and the three files at its format's places,
  ## each equal to `expected` (Shells order), and no PowerShell script.
  checkpoint(view.format & " paths: " & $view.paths)
  check binaryPath(view.format) in view.paths
  let want = expectedPaths(view.format)
  for i, rel in want:
    checkpoint(view.format & " " & rel)
    check rel in view.paths
    if rel in view.paths:
      check view.fileText(rel) == expected[i]
  for path in view.completionPaths:
    checkpoint(view.format & " completion path " & path)
    check path in want
  for path in view.paths:
    check not path.endsWith(".ps1")

proc checkCarriesNone(view: PackageView) =
  ## `view` holds the binary and no completion file.
  checkpoint(view.format & " paths: " & $view.paths)
  check binaryPath(view.format) in view.paths
  check view.completionPaths.len == 0
  for rel in expectedPaths(view.format):
    check rel notin view.paths

suite "test_cs_m8d_generated_packages_add_completion":

  test "every Linux package carries the completion of its cli: executable":
    requirePreconditions:
      let p = projectWith(AllFormats)
      let built = p.reproBuild("native")
      require built.code == 0
      let binary = p.root / "build" / "bin" / Program
      var expected: seq[string]
      for shell in Shells:
        expected.add(printedScript(binary, shell))
        check expected[^1].len > 0
      # The completion edge's own files are the same bytes.
      for i, shell in Shells:
        let generated = p.root / "build" / "completions" / Program /
          (case shell
           of "bash": Program & ".bash"
           of "zsh": "_" & Program
           else: Program & ".fish")
        check fileExists(generated) and readFile(generated) == expected[i]
      for format in AllFormats:
        let view = p.readPackage(format, p.scratch)
        view.checkCarries(expected)

  test "a cross-compiled package carries them without the binary running":
    requirePreconditions:
      # The scripts a native build packages: the expected bytes.
      let native = projectWith(["tarball"])
      require native.reproBuild("cross-reference").code == 0
      var expected: seq[string]
      for shell in Shells:
        expected.add(printedScript(native.root / "build" / "bin" / Program,
          shell))
      let p = projectWith(CrossFormats)
      let built = p.reproBuild("cross", ["--target=" & CrossTriple])
      require built.code == 0
      let keyed = p.root / ("build@" & CrossTriple)
      # An ARM executable: the build host cannot run it, so nothing that
      # needed to run it could have produced the files.
      let elf = readFile(keyed / "bin" / Program)
      check elf.startsWith("\x7fELF") and elf.len > 20 and
        uint8(elf[18]) == 40'u8
      # Target-keyed: the completion files and the entry-list location are
      # under `build@<triple>/`, and the cross build wrote no native ones.
      check dirExists(keyed / "completions" / Program)
      check not dirExists(p.root / "build" / "completions")
      for format in CrossFormats:
        let view = p.readPackage(format, p.scratch)
        view.checkCarries(expected)
      # That the host cannot run it is measured, not assumed: a host with
      # an armv7 user-mode emulator registered (binfmt_misc) and an armhf
      # loader could, and there this case shows nothing about running.
      var ranCode = -1
      try:
        ranCode = runProgramSplit(keyed / "bin" / Program,
          ["--printCompletion=bash"], "",
          newEnvTable()).code
      except OSError as e:
        checkpoint("the armv7 binary does not start here: " & e.msg)
      checkpoint("the armv7 binary run here -> exit " & $ranCode)
      if ranCode == 0:
        skip("this host runs armv7 binaries, so the case cannot show " &
          "that the files were made without running the program")

  test "the opt-out ships none":
    requirePreconditions:
      let p = projectWith(AllFormats, omit = true)
      let built = p.reproBuild("omit")
      require built.code == 0
      for format in AllFormats:
        p.readPackage(format, p.scratch).checkCarriesNone()

  test "negative control: without a cli: section no package has a file":
    requirePreconditions:
      let p = projectWith(AllFormats, cli = false)
      let built = p.reproBuild("no-cli")
      require built.code == 0
      check not dirExists(p.root / "build" / "completions")
      for format in AllFormats:
        p.readPackage(format, p.scratch).checkCarriesNone()
