## Every package reprobuild generates carries the shell completion of each
## packaged executable that has a `cli:` description, with nothing declared by
## the package author: the Linux formats (.deb, .rpm, Arch, tarball, AppImage
## and the installed prefix) and the Windows ones (MSI, a tarball for a
## Windows target, and the Scoop manifest over it).
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
##      the directory for the prefix, which its builder-path gate passed:
##      no image in it names a build-host path, and its binary names the
##      triple's system loader in `PT_INTERP` whichever C compiler on `PATH`
##      linked it, the dev shell's Nix gcc included), each byte-equal to what the
##      built program prints for `--printCompletion=<shell>`, and no PowerShell
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
##   5. **Windows packages, built here for Windows.** The program is compiled
##      for Windows with the Nim compile's own cross flags (`--os:windows
##      --cpu:amd64 --cc:clang`, the C driver a `zig cc -target
##      x86_64-windows-gnu` wrapper: there is no Windows `--target`), so it is
##      a PE executable the build host cannot run (the case runs it to make
##      sure). The Windows tarball (read with `bsdtar`) holds
##      `share/<p>/completions/<p>.ps1` and no other completion file, byte-equal
##      to what a native build of the program prints for
##      `--printCompletion=powershell` and to the completion edge's file. The
##      Scoop manifest (parsed as JSON) describes that archive (its sha256)
##      and carries `post_install` / `pre_uninstall` hooks, which the case
##      runs with `pwsh` against a scratch home: they write clispec's profile
##      block loading the unpacked script into both editions' per-user
##      profiles, leave the rest of a profile alone, and take the block out
##      again. The MSI is built as far as a host without WiX can build it
##      (`msiAuthoring`: the payload and the `.wxs`, parsed as XML): the
##      script is installed at `INSTALLFOLDER\share\<p>\completions\<p>.ps1`,
##      byte-equal, and the four custom actions (quiet exec, deferred, not
##      impersonating, result ignored, sequenced around `InstallFinalize` and
##      `RemoveFiles`) are there; their command lines, formatted as Windows
##      Installer would format them, are run with `pwsh` against a scratch
##      `SystemRoot` and `ProgramFiles`: the block goes into
##      `Profile.ps1` of the Windows PowerShell directory and of each
##      PowerShell 7 directory holding `pwsh.exe`, a second run changes
##      nothing, an unwritable one is reported and the action exits 1, and the
##      removal action takes the blocks out.
##   6. **Windows opt-out and negative control.** With `omitShellCompletion`,
##      and without the `cli:` section, the Windows packages hold the binary
##      and no script, the `.wxs` has no custom action and the manifest no
##      hook.
##   7. **The MSI itself (Windows hosts only).** WiX's `candle` and `light`
##      run on Windows only, so on a Windows host the case builds the MSI
##      natively and reads it back through the Windows Installer database API:
##      the File, Component and Directory tables install the script at its
##      place, `MsiFileHash` holds the MD5 of the expected bytes, and the
##      CustomAction table holds the four actions. Elsewhere it is skipped,
##      naming the reason.
##
## Each case's control is the other cases: the same recipe, with one thing
## changed, builds packages that differ only in the completion files. The
## mutations that fail the cases (producers' `addShellCompletion` calls
## removed one at a time, the opt-out check removed, the target keying
## removed) were each run against this file and fail the case they name.
##
## Tools. The build runs with `--tool-provisioning=path`, so every tool the
## producers name comes from `PATH` (the Windows cases also run `pwsh`, the
## PowerShell 7 of the dev shell, with `-NoProfile` and a scratch `HOME`,
## `SystemRoot` and `ProgramFiles`, so no real profile or `$PSHOME` is read or
## written): `dpkg-deb`, `rpmbuild` (and `rpm` to read
## the package back), `bsdtar`, `appimagetool`, `unsquashfs`, `patchelf`,
## `readelf`, `llvm-objcopy` (the prefix's debug strip), `zig` and the C
## toolchain. Two have no executable of their name
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
## real files are. The PowerShell the MSI's actions and the Scoop hooks run is
## the generated code itself, run by a real PowerShell; what stands in for
## Windows is only where it looks (`SystemRoot`, `ProgramFiles`, the
## Documents folder), pointed at scratch directories, and on Linux it is
## PowerShell 7 rather than Windows PowerShell 5.1 that runs it.

import std/[json, os, osproc, sequtils, strtabs, strutils, tables, tempfiles,
            unittest, xmlparser, xmltree]
from std/unicode import runes, `$`
when defined(windows):
  import std/base64

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
    "unsquashfs", "llvm-objcopy"]
  WindowsFormats = ["msi-authoring", "tarball", "scoop"]
    ## What a host without WiX builds of the Windows packages.
  WindowsTools = ["pwsh", "sha256sum"]
    ## What the Windows cases need besides `RequiredTools`.
  WindowsHostTools = ["nim", "gcc", "sh", "install-file", "tar", "gzip",
    "wix-candle", "wix-light"]
    ## A Windows host's build tools for the fixture (see `projectWith`).
  PsScript = "share/" & Program & "/completions/" & Program & ".ps1"
    ## Where every Windows package puts the PowerShell script (prefix- or
    ## archive-relative): clispec's Windows location.
  BlockOpen = "# >>> clispec-completion:" & Program & " >>>"
  BlockClose = "# <<< clispec-completion:" & Program & " <<<"

proc siblingSrc(sibling, variable, marker: string): string =
  ## A sibling's `src/`, as this repository's `config.nims` finds it.
  let pinned = getEnv(variable)
  if getEnv("REPRO_SIBLING_POLICY") == "pin" and pinned.len > 0:
    return pinned
  let checkout = ReprobuildRepoRoot.parentDir / sibling / "src"
  if fileExists(checkout / marker):
    return checkout
  pinned

proc unmetPrecondition(windows = false): string =
  ## Why the cases cannot run here, or "".
  when defined(windows):
    # A Windows host builds only the Windows packages, the MSI with the WiX
    # tools in the directory `REPRO_WIX3_BIN` names (as the release's
    # packager takes them).
    for tool in ["nim", "gcc", "sh", "tar", "gzip", "sha256sum",
                 "powershell"]:
      if findExe(tool).len == 0:
        return tool & " is not on PATH"
    let wix = getEnv("REPRO_WIX3_BIN")
    if wix.len == 0 or not fileExists(wix / "candle.exe") or
        not fileExists(wix / "light.exe"):
      return "REPRO_WIX3_BIN does not name a directory holding WiX v3's " &
        "candle.exe and light.exe"
    return ""
  for tool in RequiredTools:
    if findExe(tool).len == 0:
      return tool & " is not on PATH"
  if windows:
    for tool in WindowsTools:
      if findExe(tool).len == 0:
        return tool & " is not on PATH"
  ""

template requirePreconditions(body: untyped) =
  requirePreconditionsFor(false, body)

template requirePreconditionsFor(windows: bool; body: untyped) =
  ## `windows`: a case about the Windows packages. A case about the Linux
  ## packages is not one for a Windows host, which skips it, naming why,
  ## in a gate run too.
  let unmet = unmetPrecondition(windows)
  if defined(windows) and not windows:
    skip("the Linux packages are built and read back on Linux")
  elif unmet.len > 0 and getEnv("REPROBUILD_GATE_RUN") == "1":
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
                 omit = false; targetOs = "linux"): Project =
  ## A scratch copy of the fixture with its placeholders filled in. For a
  ## Windows `targetOs` on another host, the program is compiled for Windows
  ## through a `zig cc -target x86_64-windows-gnu` wrapper written into the
  ## scratch directory (absolute paths, so it needs nothing on the
  ## compile's PATH).
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
    .replace("__TARGET_OS__", targetOs)
  var windowsCc = ""
  if targetOs == "windows" and not defined(windows):
    windowsCc = result.scratch / "windows-cc"
    writeFile(windowsCc, "#!" & findExe("sh") & "\nexec " &
      quoteShell(findExe("zig")) &
      " cc -target x86_64-windows-gnu \"$@\"\n")
    setFilePermissions(windowsCc, {fpUserRead, fpUserWrite, fpUserExec})
  recipe = recipe.replace("__WINDOWS_CC__", windowsCc)
  when defined(windows):
    # This host's tools: the WiX tools, and what the tarball and the Scoop
    # manifest's hash edge run, in place of the Linux packagers.
    let open = recipe.find("    # >>> host tools\n")
    let close = recipe.find("    # <<< host tools\n")
    doAssert open > 0 and close > open
    var tools = ""
    for tool in WindowsHostTools:
      tools.add("    \"" & tool & "\"\n")
    recipe = recipe[0 ..< open] & tools &
      recipe[close + "    # <<< host tools\n".len .. ^1]
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
  when defined(windows):
    for (selector, exe) in [("wix-candle", "candle.exe"),
                            ("wix-light", "light.exe")]:
      writeFile(result.tools / (selector & ".repro-tool-profile"),
        "reprobuild-tool-profile-v1\nresolvedExecutablePath=" &
        (getEnv("REPRO_WIX3_BIN") / exe) & "\n")

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
    # The gate writes its stamp beside the prefix only when no image in it
    # names a build-host path; a refusal fails the build before this.
    doAssert fileExists(prefixDir & ".builder-path-gate.ok"),
      "the installed prefix's builder-path gate did not pass: " & prefixDir
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

# ---------------------------------------------------------------------------
# The Windows packages.
# ---------------------------------------------------------------------------

type WindowsView = object
  ## The Windows packages of one build, read back.
  tarPaths: seq[string]
    ## The Windows tarball's members.
  tarDir: string
    ## The tarball, unpacked.
  manifest: JsonNode
  manifestText: string
  wxs: XmlNode
  wxsText: string
  msiFiles: Table[string, string]
    ## Every file the `.wxs` installs, as its path under INSTALLFOLDER
    ## (`/`-separated, from the Directory elements' names) -> the staged
    ## file it is built from (its `File/@Source`, as a local path).
  msiFileIds: Table[string, string]
    ## The same paths -> their `File/@Id`.

proc windowsBinary(): string = "bin/" & Program & ".exe"

proc elementById(node: XmlNode; id: string): XmlNode =
  ## The element below `node` whose `Id` is `id`, or nil.
  for child in node:
    if child.kind != xnElement:
      continue
    if child.attr("Id") == id:
      return child
    let found = elementById(child, id)
    if found != nil:
      return found
  nil

proc collectMsiFiles(node: XmlNode; dir, root: string;
                     view: var WindowsView) =
  ## Every file the Directory tree below `node` installs, `dir` being
  ## `node`'s path under INSTALLFOLDER.
  for child in node:
    if child.kind != xnElement:
      continue
    case child.tag
    of "Directory":
      collectMsiFiles(child,
        (if dir.len > 0: dir & "/" else: "") & child.attr("Name"), root, view)
    of "Component":
      for file in child:
        if file.kind == xnElement and file.tag == "File":
          let source = file.attr("Source").replace('\\', '/')
          let rel = (if dir.len > 0: dir & "/" else: "") &
            source.extractFilename
          view.msiFiles[rel] =
            if source.isAbsolute: source else: root / source
          view.msiFileIds[rel] = file.attr("Id")
    else:
      discard

proc readWindows(p: Project; scratch: string): WindowsView =
  let dist = p.root / "build" / "dist"
  let tarball = onlyFile(dist, ".tar.gz")
  for line in run("bsdtar -tf " & quoteShell(tarball)).splitLines():
    if line.strip().len > 0:
      result.tarPaths.add(normalized(line))
  result.tarDir = scratch / "extract-windows-tarball"
  createDir(result.tarDir)
  discard run("bsdtar -xf " & quoteShell(tarball) & " -C " &
    quoteShell(result.tarDir))
  result.manifestText = readFile(dist / (Program & ".json"))
  result.manifest = parseJson(result.manifestText)
  # The archive the manifest describes is this tarball, byte for byte.
  let digest = run("sha256sum " & quoteShell(tarball)).splitWhitespace()[0]
  check result.manifest["architecture"]["64bit"]["hash"].getStr ==
    "sha256:" & digest
  let wxsPath = p.root / "build" / "dist" / "stage" / "gen-msi" /
    (Program & ".wxs")
  result.wxsText = readFile(wxsPath)
  result.wxs = parseXml(result.wxsText)
  let install = elementById(result.wxs, "INSTALLFOLDER")
  doAssert install != nil, "no INSTALLFOLDER in " & wxsPath
  collectMsiFiles(install, "", p.root, result)

proc customActions(view: WindowsView): Table[string, XmlNode] =
  for product in view.wxs:
    if product.kind == xnElement and product.tag == "Product":
      for node in product:
        if node.kind == xnElement and node.tag == "CustomAction":
          result[node.attr("Id")] = node

proc properties(view: WindowsView): Table[string, string] =
  ## The `.wxs`'s `Property` elements: id -> value.
  for product in view.wxs:
    if product.kind == xnElement and product.tag == "Product":
      for node in product:
        if node.kind == xnElement and node.tag == "Property":
          result[node.attr("Id")] = node.attr("Value")

proc sequenced(view: WindowsView): seq[XmlNode] =
  for product in view.wxs:
    if product.kind == xnElement and product.tag == "Product":
      for node in product:
        if node.kind == xnElement and node.tag == "InstallExecuteSequence":
          for c in node:
            if c.kind == xnElement: result.add(c)

proc checkWindowsCarries(view: WindowsView; expected: string) =
  ## The three Windows packages hold the binary and the PowerShell script at
  ## its place, equal to `expected`, and no other completion file.
  checkpoint("windows tarball: " & $view.tarPaths)
  check windowsBinary() in view.tarPaths
  check PsScript in view.tarPaths
  if PsScript in view.tarPaths:
    check readFile(view.tarDir / PsScript) == expected
  for path in view.tarPaths:
    if "completion" in path or "site-functions" in path:
      if not path.endsWith("/") and path.extractFilename.contains(Program):
        check path == PsScript
  checkpoint("msi files: " & $view.msiFiles)
  check windowsBinary() in view.msiFiles
  check PsScript in view.msiFiles
  if PsScript in view.msiFiles:
    check readFile(view.msiFiles[PsScript]) == expected
  for rel in view.msiFiles.keys:
    if rel.extractFilename.contains(Program) and rel != windowsBinary():
      check rel == PsScript
  # Scoop shims the program and has both hooks.
  var bins: seq[string]
  for b in view.manifest["bin"]: bins.add(b.getStr)
  check bins == @["bin\\" & Program & ".exe"]
  check view.manifest.hasKey("post_install")
  check view.manifest.hasKey("pre_uninstall")

proc checkWindowsCarriesNone(view: WindowsView) =
  checkpoint("windows tarball: " & $view.tarPaths)
  check windowsBinary() in view.tarPaths
  check windowsBinary() in view.msiFiles
  for path in view.tarPaths:
    check not path.endsWith(".ps1")
  for rel in view.msiFiles.keys:
    check not rel.endsWith(".ps1")
  check view.customActions.len == 0
  check view.sequenced.len == 0
  check not view.manifest.hasKey("post_install")
  check not view.manifest.hasKey("pre_uninstall")
  check "clispec-completion" notin view.wxsText
  check "ClispecCompletionRun" notin view.wxsText
  check "clispec-completion" notin view.manifestText

proc pwshEnv(scratch: string): StringTableRef =
  ## A PowerShell environment with nothing of this user's: a scratch home
  ## (where PowerShell on Linux keeps its own files, and what .NET calls
  ## the Documents folder), no telemetry or update check.
  result = inheritedEnvTable()
  let home = scratch / "pwsh-home"
  # .NET on Linux names `$HOME/Documents` as the Documents folder, and only
  # when it exists.
  createDir(home / "Documents")
  result["HOME"] = home
  result["XDG_CONFIG_HOME"] = home / ".config"
  result["XDG_DATA_HOME"] = home / ".local" / "share"
  result["XDG_CACHE_HOME"] = home / ".cache"
  result["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
  result["POWERSHELL_UPDATECHECK"] = "Off"
  result["POWERSHELL_CLI_TELEMETRY_OPTOUT"] = "1"
  result.del("LD_PRELOAD")
  result.del("PSModulePath")

proc runPwsh(command: string; env: StringTableRef):
    tuple[code: int; output: string] =
  let run = runProgramSplit(findExe("pwsh"),
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
    "", env)
  checkpoint("pwsh -> exit " & $run.code & "\n" & run.stdout & run.stderr)
  (run.code, run.stdout & run.stderr)

proc msiFormat(value: string; fileValues, properties: Table[string, string]):
    string =
  ## `value` formatted as Windows Installer formats a type-51 action's
  ## value (https://learn.microsoft.com/windows/win32/msi/formatted), for
  ## the forms the command lines use: `[\x]` is `x`, `[#<file id>]` the
  ## file's installed path (`fileValues`), `[<property>]` the property's
  ## value as it is (`properties`, the `.wxs`'s own, and `System64Folder`);
  ## any other is refused, since a test that guessed one would test its
  ## guess.
  var i = 0
  while i < value.len:
    if value[i] == '[':
      let close = value.find(']', i + 2)
      doAssert close > i, "unterminated [ in " & value
      var inner = value[i + 1 ..< close]
      if inner.startsWith("\\"):
        # `[\]]`: the escaped character is the one after the backslash.
        result.add(value[i + 2])
        i = (if inner.len == 1: close + 2 else: close + 1)
        continue
      if inner.startsWith("#"):
        doAssert inner[1 .. ^1] in fileValues, "unknown file key " & inner
        result.add(fileValues[inner[1 .. ^1]])
      elif inner == "System64Folder":
        result.add("C:\\Windows\\System32\\")
      elif inner in properties:
        result.add(properties[inner])
      else:
        doAssert false, "a property the test does not know: " & inner
      i = close + 1
    else:
      result.add(value[i])
      inc i

proc commandOf(formatted: string): string =
  ## The `-Command "<...>"` argument of a formatted quiet-exec command line.
  let marker = " -Command \""
  let at = formatted.find(marker)
  doAssert at > 0 and formatted.endsWith("\""), formatted
  result = formatted[at + marker.len ..< formatted.len - 1]
  doAssert '"' notin result

proc blockIn(text: string): string =
  ## The body of the program's block in a profile's text, or "" when there
  ## is none; refuses two.
  let lines = text.replace("\r\n", "\n").split('\n')
  var inside = false
  var count = 0
  for line in lines:
    if line == BlockOpen:
      inside = true
      inc count
    elif line == BlockClose:
      inside = false
    elif inside:
      result.add(line & "\n")
  doAssert count <= 1, "two blocks in:\n" & text

proc expectedBlock(script: string): string =
  ## clispec's PowerShell profile block body for `script`
  ## (`cliProfileBlockBody`), spelled out: a test that called the generator
  ## would compare it with itself. Every quote PowerShell reads as one is
  ## doubled: `'` and the typographic `\u2018`-`\u201B`.
  var quoted = ""
  for r in script.runes:
    let c = $r
    quoted.add(if c in ["'", "\u2018", "\u2019", "\u201A", "\u201B"]: c & c
               else: c)
  "if (Test-Path -LiteralPath '" & quoted &
    "') { Invoke-Expression ([System.IO.File]::ReadAllText('" &
    quoted & "')) }\n"

proc noBom(text: string): string =
  ## `text` without the UTF-8 byte-order mark the block writer puts first.
  if text.startsWith("\xEF\xBB\xBF"): text[3 .. ^1] else: text

proc u32le(data: string; at: int): int =
  for i in countdown(3, 0):
    result = (result shl 8) or int(uint8(data[at + i]))

proc isWindowsX64Executable(path: string): bool =
  ## A PE image for x86-64 (the `MZ` stub, the `PE\0\0` signature at the
  ## offset in 0x3C, machine 0x8664), read without running it.
  let image = readFile(path)
  if image.len < 0x40 or not image.startsWith("MZ"):
    return false
  let pe = u32le(image, 0x3C)
  pe + 6 <= image.len and image[pe ..< pe + 4] == "PE\0\0" and
    uint8(image[pe + 4]) == 0x64'u8 and uint8(image[pe + 5]) == 0x86'u8

var windowsBuild: tuple[done: bool; p: Project; code: int]
  ## The Windows packages of `WindowsFormats`, built once for the cases
  ## that read them.

proc builtWindowsPackages(): tuple[p: Project; code: int] =
  if not windowsBuild.done:
    let p = projectWith(WindowsFormats, targetOs = "windows")
    windowsBuild = (true, p, p.reproBuild("windows").code)
  (windowsBuild.p, windowsBuild.code)

proc nativePowerShellScript(): string =
  ## The PowerShell script a native (Linux) build of the program prints:
  ## the bytes the Windows packages must carry.
  let native = projectWith(["tarball"])
  doAssert native.reproBuild("windows-reference").code == 0
  printedScript(native.root / "build" / "bin" / Program, "powershell")

proc hookText(view: WindowsView; name: string): string =
  ## A Scoop hook's lines, as Scoop joins them into one script.
  var lines: seq[string]
  for line in view.manifest[name]: lines.add(line.getStr)
  lines.join("\n")

proc psQuote(s: string): string = "'" & s.replace("'", "''") & "'"

when defined(windows):
  const MsiTableReader = """
$ErrorActionPreference = 'Stop'
# One table of the database, a row per line, cells tab-separated, read
# through the Windows Installer database API
# (https://learn.microsoft.com/windows/win32/msi/installer-opendatabase).
# A binary-stream column (type v/V in View.ColumnInfo) is written as its
# length, since Record.StringData refuses a stream.
function Get-P($o, [string]$n, [object[]]$a) { $o.GetType().InvokeMember($n, 'GetProperty', $null, $o, $a) }
function Invoke-M($o, [string]$n, [object[]]$a) { $o.GetType().InvokeMember($n, 'InvokeMethod', $null, $o, $a) }
try {
  $i = New-Object -ComObject WindowsInstaller.Installer
  $db = Invoke-M $i 'OpenDatabase' @($env:CSM8D_MSI, 0)
  $v = Invoke-M $db 'OpenView' @('SELECT * FROM `' + $env:CSM8D_MSI_TABLE + '`')
  Invoke-M $v 'Execute' $null | Out-Null
  $cols = Get-P $v 'ColumnInfo' @(1)
  $n = Get-P $cols 'FieldCount' $null
  $types = @(foreach ($k in 1..$n) { Get-P $cols 'StringData' @($k) })
  while ($r = Invoke-M $v 'Fetch' $null) {
    $f = foreach ($k in 1..$n) {
      if ($types[$k - 1] -cmatch '^[vV]') { [string](Get-P $r 'DataSize' @($k)) }
      else { [string](Get-P $r 'StringData' @($k)) }
    }
    [Console]::Out.WriteLine(($f -join [char]9))
  }
} catch {
  [Console]::Error.WriteLine('reading ' + $env:CSM8D_MSI_TABLE + ' failed: ' + $_.Exception.Message)
  exit 1
}
"""

  proc encodedCommand(script: string): string =
    ## PowerShell's -EncodedCommand: base64 of the UTF-16LE text (ASCII
    ## here).
    var bytes = ""
    for ch in script:
      bytes.add(ch)
      bytes.add('\0')
    encode(bytes)

  proc msiTable(msi, table: string): seq[seq[string]] =
    let env = inheritedEnvTable()
    env["CSM8D_MSI"] = msi
    env["CSM8D_MSI_TABLE"] = table
    let run = runProgramSplit(findExe("powershell"),
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
       encodedCommand(MsiTableReader)], "", env)
    checkpoint("MSI table " & table & " -> exit " & $run.code & " " &
      run.stderr)
    doAssert run.code == 0
    for line in run.stdout.replace("\r\n", "\n").split('\n'):
      if line.len > 0:
        result.add(line.split('\t'))

  proc longName(defaultDir: string): string =
    ## A Directory row's target name: `target[:source]`, each `short|long`.
    result = defaultDir.split(':')[0]
    if '|' in result: result = result.split('|')[1]

  proc msiChecks(msi, expected, scratch: string) =
    ## The MSI at `msi` installs the PowerShell script at its place under
    ## INSTALLFOLDER with `expected`'s size and MD5 (`MsiFileHash`, which
    ## light writes for an unversioned file), and has the four actions.
    var fileRow: seq[string]
    for row in msiTable(msi, "File"):
      if row[2].split('|')[^1] == Program & ".ps1":
        fileRow = row
    require fileRow.len > 0
    check parseInt(fileRow[3]) == expected.len
    var compDir = ""
    for row in msiTable(msi, "Component"):
      if row[0] == fileRow[1]: compDir = row[2]
    var dirs = initTable[string, (string, string)]()
    for row in msiTable(msi, "Directory"):
      dirs[row[0]] = (row[1], longName(row[2]))
    var names: seq[string]
    var d = compDir
    while d.len > 0 and d != "INSTALLFOLDER":
      require d in dirs
      names.insert(dirs[d][1], 0)
      d = dirs[d][0]
    check d == "INSTALLFOLDER"
    check names.join("/") & "/" & Program & ".ps1" == PsScript
    # MsiFileHash: the MD5 as four little-endian 32-bit integers.
    let sample = scratch / "expected.ps1"
    writeFile(sample, expected)
    let md5 = runProgramSplit(findExe("powershell"), ["-NoLogo",
      "-NoProfile", "-NonInteractive", "-Command",
      "(Get-FileHash -Algorithm MD5 -LiteralPath '" & sample &
      "').Hash"], "", inheritedEnvTable()).stdout.strip()
    require md5.len == 32
    var parts: seq[string]
    for k in 0 .. 3:
      var v = 0'i64
      for b in countdown(3, 0):
        v = (v shl 8) or fromHex[int64](md5[(k * 4 + b) * 2 ..< (k * 4 + b) * 2 + 2])
      parts.add($cast[int32](v))
    var hashed = false
    for row in msiTable(msi, "MsiFileHash"):
      if row[0] == fileRow[0]:
        hashed = true
        check row[2 .. 5] == parts
    check hashed
    var actions = initTable[string, seq[string]]()
    for row in msiTable(msi, "CustomAction"):
      actions[row[0]] = row
    for id in ["ClispecCompletionEnsure1", "ClispecCompletionRemove1"]:
      require id in actions and ("Set" & id) in actions
      check actions[id][2] == "WixCA" and actions[id][3] == "WixQuietExec64"
      check actions["Set" & id][1] == "51"
      check actions["Set" & id][2] == id
    check ("[#" & fileRow[0] & "]") in
      actions["SetClispecCompletionEnsure1"][3]

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

  test "every Windows package carries the PowerShell script (built for Windows here)":
    requirePreconditionsFor(true):
      when defined(windows):
        skip("a Windows host builds the Windows packages natively, in the " &
          "MSI case below")
      else:
        let expected = nativePowerShellScript()
        check "__complete" in expected
        let (p, code) = builtWindowsPackages()
        require code == 0
        let exe = p.root / "build" / "bin" / (Program & ".exe")
        # A Windows executable, which nothing on this host ran to make the
        # script: the completion edge wrote it from the description.
        check isWindowsX64Executable(exe)
        check readFile(p.root / "build" / "completions" / Program /
          (Program & ".ps1")) == expected
        let view = p.readWindows(p.scratch / "windows")
        view.checkWindowsCarries(expected)
        # That this host cannot run it is measured, not assumed: a host
        # with a Windows loader registered (wine through binfmt_misc) could.
        var ranCode = -1
        try:
          ranCode = runProgramSplit(exe, ["--printCompletion=powershell"],
            "", newEnvTable()).code
        except OSError as e:
          checkpoint("the Windows executable does not start here: " & e.msg)
        checkpoint("the Windows executable run here -> exit " & $ranCode)
        if ranCode == 0:
          skip("this host runs Windows executables, so the case cannot " &
            "show that the script was made without running the program")

  test "the Scoop hooks register the script for the user and remove it":
    requirePreconditionsFor(true):
      when defined(windows):
        skip("needs the Windows packages built on another host; a " &
          "Windows host's Scoop is not to be touched by a test")
      else:
        let (p, code) = builtWindowsPackages()
        require code == 0
        let scratch = p.scratch / "scoop"
        createDir(scratch)
        let view = p.readWindows(scratch)
        let env = pwshEnv(scratch)
        # Where the hooks will write: .NET's Documents folder, which must be
        # in the scratch home, or the case stops before writing anything.
        let docs = runPwsh("[Environment]::GetFolderPath('MyDocuments')",
          env).output.strip()
        checkpoint("Documents: " & docs)
        require docs.len > 0 and docs.startsWith(scratch)
        let profile7 = docs / "PowerShell" / "Profile.ps1"
        let profile5 = docs / "WindowsPowerShell" / "Profile.ps1"
        createDir(profile7.parentDir)
        const UserLine = "Set-Alias ll Get-ChildItem\r\n"
        writeFile(profile7, UserLine)
        # Scoop runs a hook with `$dir` naming the app's directory: here,
        # the unpacked archive the manifest describes.
        let dir = view.tarDir
        let script = dir / PsScript
        let post = "$dir = " & psQuote(dir) & "\n" &
          view.hookText("post_install")
        let first = runPwsh(post, env)
        check first.code == 0
        for profile in [profile7, profile5]:
          checkpoint(profile)
          check fileExists(profile)
          if fileExists(profile):
            check blockIn(noBom(readFile(profile))) == expectedBlock(script)
        check noBom(readFile(profile7)).startsWith(UserLine)
        # The block loads the script: running the profile evaluates it.
        check runPwsh(". " & psQuote(profile7) & "; " &
          "if (-not (Test-Path -LiteralPath " & psQuote(script) &
          ")) { exit 3 }", env).code == 0
        # A second run changes nothing.
        let before = readFile(profile7)
        let again = runPwsh(post, env)
        check again.code == 0 and "unchanged" in again.output
        check readFile(profile7) == before
        # pre_uninstall takes the blocks out and leaves the rest.
        let pre = "$dir = " & psQuote(dir) & "\n" &
          view.hookText("pre_uninstall")
        check runPwsh(pre, env).code == 0
        # Byte for byte: the user's file as it was (an ASCII file gets no
        # byte-order mark), and the file the hook created, which held only
        # the block, gone.
        check readFile(profile7) == UserLine
        check not fileExists(profile5)

  test "the MSI's actions write the all-users blocks and remove them":
    requirePreconditionsFor(true):
      when defined(windows):
        skip("a Windows host builds the MSI itself, in the case below")
      else:
        let (p, code) = builtWindowsPackages()
        require code == 0
        let scratch = p.scratch / "msi"
        createDir(scratch)
        let view = p.readWindows(scratch)
        let actions = view.customActions
        checkpoint("custom actions: " & $toSeq(actions.keys))
        check actions.len == 4
        for id in ["ClispecCompletionEnsure1", "ClispecCompletionRemove1"]:
          require id in actions
          let a = actions[id]
          check a.attr("BinaryKey") == "WixCA"
          check a.attr("DllEntry") == "WixQuietExec64"
          check a.attr("Execute") == "deferred"
          check a.attr("Impersonate") == "no"
          check a.attr("Return") == "ignore"
          require ("Set" & id) in actions
          let setter = actions["Set" & id]
          check setter.attr("Property") == id
          check setter.attr("Execute") == "immediate"
        var sequence: seq[(string, string, string)]
        for c in view.sequenced:
          sequence.add((c.attr("Action"), c.attr("Before"), c.innerText))
        checkpoint("sequence: " & $sequence)
        check ("ClispecCompletionEnsure1", "InstallFinalize",
          "NOT (REMOVE~=\"ALL\")") in sequence
        check ("SetClispecCompletionEnsure1", "ClispecCompletionEnsure1",
          "NOT (REMOVE~=\"ALL\")") in sequence
        check ("ClispecCompletionRemove1", "RemoveFiles",
          "REMOVE~=\"ALL\"") in sequence
        check ("SetClispecCompletionRemove1", "ClispecCompletionRemove1",
          "REMOVE~=\"ALL\"") in sequence
        # The install action names the installed script by its file key.
        require PsScript in view.msiFileIds
        let fileId = view.msiFileIds[PsScript]
        let ensureValue = actions["SetClispecCompletionEnsure1"].attr("Value")
        check ("[#" & fileId & "]") in ensureValue
        # Run both command lines as Windows Installer would format them,
        # with this host's PowerShell, against a scratch Windows: Windows
        # PowerShell's $PSHOME, two PowerShell 7 directories (one without
        # pwsh.exe, which is not a PowerShell), and nothing else.
        let systemRoot = scratch / "Windows"
        let programFiles = scratch / "Program Files"
        let ps5 = systemRoot / "System32" / "WindowsPowerShell" / "v1.0"
        let ps7 = programFiles / "PowerShell" / "7"
        let notPs = programFiles / "PowerShell" / "7-preview"
        for d in [ps5, ps7, notPs]: createDir(d)
        writeFile(ps7 / "pwsh.exe", "")
        const MachineLine = "# the machine's own profile\r\n"
        writeFile(ps5 / "Profile.ps1", MachineLine)
        let env = pwshEnv(scratch)
        env["SystemRoot"] = systemRoot
        env["ProgramFiles"] = programFiles
        # An install folder whose name would end a PowerShell string and run
        # the rest as code, were the path spliced into one: the actions must
        # write it into the block quoted, and run nothing of it (`exit 7`
        # would be the action's exit code).
        let installed = "C:\\Program Files\\x';exit 7;'\\share\\" &
          Program & "\\completions\\" & Program & ".ps1"
        let props = view.properties
        check "ClispecCompletionRun1" in props
        let formatted = msiFormat(ensureValue, {fileId: installed}.toTable,
          props)
        checkpoint("formatted: " & formatted)
        check formatted.startsWith("\"C:\\Windows\\System32\\" &
          "WindowsPowerShell\\v1.0\\powershell.exe\" -NoLogo -NoProfile " &
          "-NonInteractive -Command \"")
        let ensure = commandOf(formatted)
        let remove = commandOf(msiFormat(
          actions["SetClispecCompletionRemove1"].attr("Value"),
          initTable[string, string](), props))
        let first = runPwsh(ensure, env)
        check first.code == 0
        for home in [ps5, ps7]:
          checkpoint(home)
          check fileExists(home / "Profile.ps1")
          if fileExists(home / "Profile.ps1"):
            check blockIn(noBom(readFile(home / "Profile.ps1"))) ==
              expectedBlock(installed)
        check noBom(readFile(ps5 / "Profile.ps1")).startsWith(MachineLine)
        check not fileExists(notPs / "Profile.ps1")
        let before = readFile(ps5 / "Profile.ps1")
        check runPwsh(ensure, env).code == 0
        check readFile(ps5 / "Profile.ps1") == before
        # A PowerShell whose $PSHOME it cannot write is reported, the others
        # are still done, and the action exits 1 (which the package ignores).
        let locked = programFiles / "PowerShell" / "7.4"
        createDir(locked)
        writeFile(locked / "pwsh.exe", "")
        setFilePermissions(locked, {fpUserRead, fpUserExec})
        try:
          let partial = runPwsh(ensure, env)
          check partial.code == 1
          check (locked / "Profile.ps1") in partial.output and
            "not changed" in partial.output
          check blockIn(noBom(readFile(ps7 / "Profile.ps1"))) ==
            expectedBlock(installed)
          # The removal action takes every block out, the machine's own
          # lines stay, and a directory with nothing to remove is fine.
          check runPwsh(remove, env).code == 0
        finally:
          setFilePermissions(locked, {fpUserRead, fpUserWrite, fpUserExec})
        # Byte for byte the machine's own profile, and the one the action
        # created, which held only the block, gone.
        check readFile(ps5 / "Profile.ps1") == MachineLine
        check not fileExists(ps7 / "Profile.ps1")

  test "the Windows packages' opt-out ships no script and no registration":
    requirePreconditionsFor(true):
      when defined(windows):
        skip("a Windows host builds the Windows packages natively, in the " &
          "MSI case below")
      else:
        let p = projectWith(WindowsFormats, omit = true, targetOs = "windows")
        require p.reproBuild("windows-omit").code == 0
        p.readWindows(p.scratch / "windows").checkWindowsCarriesNone()

  test "negative control: without a cli: section no Windows package has one":
    requirePreconditionsFor(true):
      when defined(windows):
        skip("a Windows host builds the Windows packages natively, in the " &
          "MSI case below")
      else:
        let p = projectWith(WindowsFormats, cli = false, targetOs = "windows")
        require p.reproBuild("windows-no-cli").code == 0
        check not dirExists(p.root / "build" / "completions")
        p.readWindows(p.scratch / "windows").checkWindowsCarriesNone()

  test "the MSI installs the script and its actions (Windows hosts)":
    when not defined(windows):
      skip("WiX v3's candle and light, which link the MSI, run on Windows " &
        "only; this host builds its payload and .wxs (the cases above)")
    else:
      requirePreconditionsFor(true):
        let p = projectWith(["msi", "tarball", "scoop"], targetOs = "windows")
        require p.reproBuild("windows-msi").code == 0
        let exe = p.root / "build" / "bin" / (Program & ".exe")
        let expected = printedScript(exe, "powershell")
        check "__complete" in expected
        let msi = onlyFile(p.root / "build" / "dist", ".msi")
        msiChecks(msi, expected, p.scratch)
        # For an install check in a disposable machine (never this one):
        # a copy of the package outside the scratch directory.
        let keep = getEnv("CSM8D_KEEP_MSI")
        if keep.len > 0:
          createDir(keep)
          copyFile(msi, keep / msi.extractFilename)
