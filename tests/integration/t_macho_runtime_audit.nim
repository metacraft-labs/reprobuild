## Linux-hosted behavioral coverage for the exact Mach-O audit script used by
## the packaged-runtime Nix gate.  Fake inspection tools provide independent
## per-architecture metadata; real filesystem entries decide resolution.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_binary_cache_client/dynlib_names as zstd_names
import repro_solver/dynlib_names as clingo_names

type MachoFixture = object
  root: string
  packageRoot: string
  metadataRoot: string
  auditScript: string
  lipoTool: string
  otoolTool: string
  codesignTool: string
  executable: string
  library: string
  runtimeDirs: seq[string]

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc metadataPath(fixture: MachoFixture; image, arch, kind: string): string =
  fixture.metadataRoot / (image.extractFilename & "." & arch & "." & kind)

proc writeSlice(fixture: MachoFixture; image, arch: string;
                rpaths, dependencies: seq[string]; installId = "") =
  writeFile(fixture.metadataPath(image, arch, "rpaths"),
    rpaths.join("\n") & "\n")
  writeFile(fixture.metadataPath(image, arch, "deps"),
    dependencies.join("\n") & "\n")
  writeFile(fixture.metadataPath(image, arch, "id"), installId & "\n")

proc makeFixture(repoRoot: string): MachoFixture =
  result.root = createTempDir("repro-macho-audit-", "")
  result.packageRoot = result.root / "package"
  result.metadataRoot = result.root / "metadata"
  result.auditScript = repoRoot / "scripts" / "audit_macho_runtime.sh"
  result.lipoTool = result.root / "fake-lipo"
  result.otoolTool = result.root / "fake-otool"
  result.codesignTool = result.root / "fake-codesign"
  result.executable = result.packageRoot / "bin" / ".repro-wrapped"
  result.library = result.packageRoot / "lib" / "librepro-runtime.dylib"
  createDir(result.packageRoot / "bin")
  createDir(result.packageRoot / "lib")
  createDir(result.packageRoot / "deps")
  createDir(result.metadataRoot)
  writeFile(result.executable, "fake universal executable\n")
  writeFile(result.library, "fake universal library\n")
  for i in 1 .. 6:
    let runtimeDir = result.root / ("runtime-" & $i) / "lib"
    createDir(runtimeDir)
    result.runtimeDirs.add(runtimeDir)
  writeFile(result.runtimeDirs[0] / "libzstd.1.dylib", "zstd\n")
  writeFile(result.runtimeDirs[1] / "libclingo.dylib", "clingo\n")
  writeFile(result.packageRoot / "bin" / "local-loader.dylib", "loader\n")
  writeFile(result.packageRoot / "bin" / "local-exec.dylib", "executable\n")
  writeFile(result.packageRoot / "deps" / "local-lib.dylib", "library\n")

  writeFile(result.metadataRoot / ".repro-wrapped.archs", "x86_64 arm64\n")
  writeFile(result.metadataRoot / "librepro-runtime.dylib.archs",
    "arm64 arm64e\n")
  writeFile(result.metadataRoot / ".repro-wrapped.signature", "valid\n")
  writeFile(result.metadataRoot / "librepro-runtime.dylib.signature", "valid\n")

  let executableDependencies = @[
    "@rpath/libzstd.1.dylib",
    "@rpath/libclingo.dylib",
    "@loader_path/local-loader.dylib",
    "@executable_path/local-exec.dylib",
    "/usr/lib/libSystem.B.dylib"
  ]
  let libraryDependencies = @[
    "@rpath/libclingo.dylib",
    "@loader_path/../deps/local-lib.dylib",
    "/System/Library/Frameworks/Foundation.framework/Foundation"
  ]
  for arch in ["x86_64", "arm64"]:
    result.writeSlice(result.executable, arch, result.runtimeDirs,
      executableDependencies)
  for arch in ["arm64", "arm64e"]:
    result.writeSlice(result.library, arch, result.runtimeDirs,
      libraryDependencies, result.library)

  writeExecutable(result.lipoTool, """#!/usr/bin/env bash
set -euo pipefail
test "$1" = -archs
image=$2
metadata="$FAKE_MACHO_METADATA/$(basename "$image").archs"
test -f "$metadata"
cat "$metadata"
""")
  writeExecutable(result.otoolTool, """#!/usr/bin/env bash
set -euo pipefail
test "$1" = -arch
arch=$2
mode=$3
image=$4
base="$FAKE_MACHO_METADATA/$(basename "$image").$arch"
test -f "$base.rpaths"
case "$mode" in
  -h)
    echo "Mach header"
    ;;
  -l)
    index=0
    while IFS= read -r rpath; do
      test -n "$rpath" || continue
      echo "Load command $index"
      echo "      cmd LC_RPATH"
      echo "     path $rpath (offset 12)"
      index=$((index + 1))
    done < "$base.rpaths"
    ;;
  -D)
    echo "$image (architecture $arch):"
    cat "$base.id"
    ;;
  -L)
    echo "$image (architecture $arch):"
    while IFS= read -r dependency; do
      test -n "$dependency" || continue
      echo "  $dependency (compatibility version 1.0.0, current version 1.0.0)"
    done < "$base.deps"
    ;;
  *)
    exit 65
    ;;
esac
""")
  writeExecutable(result.codesignTool, """#!/usr/bin/env bash
set -euo pipefail
image=${@: -1}
test "$(cat "$FAKE_MACHO_METADATA/$(basename "$image").signature")" = valid
""")

proc runAudit(fixture: MachoFixture): tuple[output: string; exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  env["PATH"] = getEnv("PATH")
  env["HOME"] = getEnv("HOME")
  env["TMPDIR"] = getEnv("TMPDIR", getTempDir())
  env["FAKE_MACHO_METADATA"] = fixture.metadataRoot
  env["LIPO"] = fixture.lipoTool
  env["OTOOL"] = fixture.otoolTool
  env["CODESIGN"] = fixture.codesignTool
  execCmdEx(quoteShellCommand(@["bash", fixture.auditScript,
    fixture.packageRoot] & fixture.runtimeDirs), env = env)

proc addDependency(fixture: MachoFixture; image, arch, dependency: string) =
  let path = fixture.metadataPath(image, arch, "deps")
  writeFile(path, readFile(path) & dependency & "\n")

type StatefulMachoFixture = object
  root: string
  packageRoot: string
  stateRoot: string
  scratchRoot: string
  toolLog: string
  fixupScript: string
  auditScript: string
  fileTool: string
  cpTool: string
  lipoTool: string
  otoolTool: string
  installNameTool: string
  statTool: string
  mvTool: string
  codesignTool: string
  thinExecutable: string
  thinLibrary: string
  fatLibrary: string
  nonMacho: string
  runtimeDirs: seq[string]

proc stateImageRoot(fixture: StatefulMachoFixture; key: string): string =
  fixture.stateRoot / "images" / key

proc imageStateKey(image: string): string =
  readFile(image).strip()

proc sliceMetadata(fixture: StatefulMachoFixture; image, arch,
                   kind: string): string =
  fixture.stateImageRoot(image.imageStateKey) / "slices" / arch / kind

proc writeStateImage(fixture: StatefulMachoFixture; image, key: string;
                     architectures: openArray[string]; isLibrary: bool;
                     permissions: set[FilePermission]) =
  let imageState = fixture.stateImageRoot(key)
  createDir(imageState / "slices")
  writeFile(imageState / "archs", architectures.join(" ") & "\n")
  writeFile(imageState / "signature", "invalid\n")
  for arch in architectures:
    let slice = imageState / "slices" / arch
    createDir(slice)
    writeFile(slice / "rpaths", fixture.runtimeDirs[0] & "\n")
    writeFile(slice / "id",
      (if isLibrary: "/wrong/install/name.dylib" else: "") & "\n")
    writeFile(slice / "deps", "@rpath/libzstd.1.dylib\n" &
      "@rpath/libclingo.dylib\n/usr/lib/libSystem.B.dylib\n")
  writeFile(image, key & "\n")
  setFilePermissions(image, permissions)

proc statefulEnvironment(fixture: StatefulMachoFixture): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  result["PATH"] = getEnv("PATH")
  result["HOME"] = getEnv("HOME")
  result["TMPDIR"] = fixture.scratchRoot
  result["FAKE_MACHO_STATE"] = fixture.stateRoot
  result["FAKE_TOOL_LOG"] = fixture.toolLog
  result["FAKE_PACKAGE_ROOT"] = fixture.packageRoot
  result["REAL_STAT"] = findExe("stat")
  result["REAL_CP"] = findExe("cp")
  result["REAL_MV"] = findExe("mv")
  result["FILE"] = fixture.fileTool
  result["CP"] = fixture.cpTool
  result["LIPO"] = fixture.lipoTool
  result["OTOOL"] = fixture.otoolTool
  result["INSTALL_NAME_TOOL"] = fixture.installNameTool
  result["STAT"] = fixture.statTool
  result["MV"] = fixture.mvTool
  result["CODESIGN"] = fixture.codesignTool

proc makeStatefulFixture(repoRoot: string): StatefulMachoFixture =
  result.root = createTempDir("repro macho state [", "] #1;")
  result.packageRoot = result.root / "package [runtime] #1;set"
  result.stateRoot = result.root / "state [images] #2;set"
  result.scratchRoot = result.root / "scratch [private] #3;set"
  result.toolLog = result.root / "tool calls [exact] #4;.log"
  result.fixupScript = repoRoot / "scripts" / "fixup_macho_runtime.sh"
  result.auditScript = repoRoot / "scripts" / "audit_macho_runtime.sh"
  result.fileTool = result.root / "fake file [magic] #5;"
  result.cpTool = result.root / "fake cp [bytes] #5b;"
  result.lipoTool = result.root / "fake lipo [stateful] #6;"
  result.otoolTool = result.root / "fake otool [stateful] #7;"
  result.installNameTool = result.root / "fake install name [stateful] #8;"
  result.statTool = result.root / "fake stat [gnu] #9;"
  result.mvTool = result.root / "fake mv [same root] #9b;"
  result.codesignTool = result.root / "fake codesign [stateful] #10;"
  result.thinExecutable = result.packageRoot / "bin" / ".thin tool-wrapped"
  result.thinLibrary = result.packageRoot / "lib" / "libthin [one] #.dylib"
  result.fatLibrary = result.packageRoot / "lib" / "libfat [two] #.dylib"
  result.nonMacho = result.packageRoot / "bin" / "wrapper [script] #;"

  createDir(result.packageRoot / "bin")
  createDir(result.packageRoot / "lib")
  createDir(result.stateRoot / "images")
  createDir(result.scratchRoot)
  writeFile(result.toolLog, "")
  for i in 1 .. 6:
    let runtimeDir = result.root / ("runtime [" & $i & "] #;lib") / "lib"
    createDir(runtimeDir)
    result.runtimeDirs.add(runtimeDir)
  writeFile(result.runtimeDirs[0] / "libzstd.1.dylib", "zstd\n")
  writeFile(result.runtimeDirs[1] / "libclingo.dylib", "clingo\n")

  result.writeStateImage(result.thinExecutable, "original-thin-executable",
    ["x86_64"], false, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersExec})
  result.writeStateImage(result.thinLibrary, "original-thin-library",
    ["arm64"], true, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  result.writeStateImage(result.fatLibrary, "original-fat-library",
    ["arm64", "arm64e"], true, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpOthersRead})
  doAssert execShellCmd(quoteShellCommand(
    @["chmod", "1751", result.fatLibrary])) == 0
  writeFile(result.nonMacho, "#!/bin/sh\nexit 0\n")
  setFilePermissions(result.nonMacho,
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec})

  writeExecutable(result.fileTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf file
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"
test "$#" -eq 2
test "$1" = -b
key=$(head -n 1 "$2")
if test -d "$FAKE_MACHO_STATE/images/$key"; then
  echo 'Mach-O universal binary'
else
  echo 'POSIX shell script, ASCII text executable'
fi
""")
  writeExecutable(result.statTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf stat
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"
test "$#" -eq 3
test "$1" = -c
test "$2" = %a
if test "${FAKE_BAD_STAT_MODE:-}" = 1; then
  echo not-an-octal-mode
  exit 0
fi
if test "$(basename "$REAL_STAT")" = coreutils; then
  "$REAL_STAT" --coreutils-prog=stat -c %a "$3"
else
  "$REAL_STAT" -c %a "$3"
fi
""")
  writeExecutable(result.cpTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf cp
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"
test "$#" -eq 2
if test "$(basename "$REAL_CP")" = coreutils; then
  "$REAL_CP" --coreutils-prog=cp "$1" "$2"
else
  "$REAL_CP" "$1" "$2"
fi
""")
  writeExecutable(result.mvTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf mv
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"
test "$#" -eq 3
test "$1" = -f
source=$2
target=$3
target_dir=$(dirname "$target")
case "$target" in
  "$FAKE_PACKAGE_ROOT"/bin/*|"$FAKE_PACKAGE_ROOT"/lib/*) ;;
  *) exit 78 ;;
esac
case "$source" in
  "$target_dir"/.repro-macho-fixup.*/*) ;;
  *) exit 79 ;;
esac
if test "$(basename "$REAL_MV")" = coreutils; then
  "$REAL_MV" --coreutils-prog=mv -f "$source" "$target"
else
  "$REAL_MV" -f "$source" "$target"
fi
""")
  writeExecutable(result.lipoTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf lipo
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"

state_for() {
  local key
  key=$(head -n 1 "$1")
  test -d "$FAKE_MACHO_STATE/images/$key"
  printf '%s\n' "$FAKE_MACHO_STATE/images/$key"
}

new_state() {
  local directory
  directory=$(mktemp -d "$FAKE_MACHO_STATE/images/generated.XXXXXX")
  mkdir -p "$directory/slices"
  printf '%s\n' "$directory"
}

if test "$#" -eq 2 && test "$1" = -archs; then
  state=$(state_for "$2")
  cat "$state/archs"
elif test "$#" -eq 5 && test "$2" = -thin && test "$4" = -output; then
  source_state=$(state_for "$1")
  arch=$3
  output=$5
  tr ' ' '\n' < "$source_state/archs" | grep -Fxq "$arch"
  target_state=$(new_state)
  printf '%s\n' "$arch" > "$target_state/archs"
  cp -R "$source_state/slices/$arch" "$target_state/slices/$arch"
  printf 'invalid\n' > "$target_state/signature"
  basename "$target_state" > "$output"
elif test "$#" -ge 4 && test "$1" = -create; then
  if test "${FAKE_FAIL_LIPO_CREATE:-}" = 1; then
    exit 75
  fi
  args=("$@")
  count=${#args[@]}
  test "${args[count - 2]}" = -output
  output=${args[count - 1]}
  target_state=$(new_state)
  : > "$target_state/archs"
  for ((index = 1; index < count - 2; index++)); do
    source_state=$(state_for "${args[index]}")
    read -r arch extra < "$source_state/archs"
    test -n "$arch"
    test -z "${extra:-}"
    if test -s "$target_state/archs"; then
      printf ' ' >> "$target_state/archs"
    fi
    printf '%s' "$arch" >> "$target_state/archs"
    cp -R "$source_state/slices/$arch" "$target_state/slices/$arch"
  done
  printf '\n' >> "$target_state/archs"
  printf 'invalid\n' > "$target_state/signature"
  basename "$target_state" > "$output"
else
  exit 64
fi
""")
  writeExecutable(result.otoolTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf otool
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"

state_for() {
  local key
  key=$(head -n 1 "$1")
  test -d "$FAKE_MACHO_STATE/images/$key"
  printf '%s\n' "$FAKE_MACHO_STATE/images/$key"
}

if test "$1" = -arch; then
  test "$#" -eq 4
  arch=$2
  mode=$3
  image=$4
else
  test "$#" -eq 2
  mode=$1
  image=$2
  state=$(state_for "$image")
  read -r arch extra < "$state/archs"
  test -n "$arch"
  test -z "${extra:-}"
fi
state=$(state_for "$image")
slice="$state/slices/$arch"
test -d "$slice"
case "$mode" in
  -h)
    echo 'Mach header'
    ;;
  -l)
    index=0
    while IFS= read -r rpath; do
      test -n "$rpath" || continue
      echo "Load command $index"
      echo '      cmd LC_RPATH'
      echo "     path $rpath (offset 12)"
      index=$((index + 1))
    done < "$slice/rpaths"
    ;;
  -D)
    echo "$image (architecture $arch):"
    cat "$slice/id"
    ;;
  -L)
    echo "$image (architecture $arch):"
    while IFS= read -r dependency; do
      test -n "$dependency" || continue
      echo "  $dependency (compatibility version 1.0.0, current version 1.0.0)"
    done < "$slice/deps"
    ;;
  *)
    exit 64
    ;;
esac
""")
  writeExecutable(result.installNameTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf install_name_tool
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"

image=${@: -1}
key=$(head -n 1 "$image")
state="$FAKE_MACHO_STATE/images/$key"
test -d "$state"
read -r arch extra < "$state/archs"
test -n "$arch"
test -z "${extra:-}"
slice="$state/slices/$arch"
case "$1" in
  -add_rpath)
    test "$#" -eq 3
    rpath=$2
    if grep -Fxq "$rpath" "$slice/rpaths"; then
      exit 76
    fi
    if test "${FAKE_FAIL_INSTALL_ARCH:-}" = "$arch"; then
      exit 77
    fi
    ;;
  -id)
    test "$#" -eq 3
    ;;
  *)
    exit 64
    ;;
esac
# Real install_name_tool mutates the scratch file's bytes, not any other file
# copied from the same source. The fixture stores bytes out of line, so clone
# that state before every successful mutation to model filesystem copy
# independence and make accidental in-place production edits observable.
source_state=$state
state=$(mktemp -d "$FAKE_MACHO_STATE/images/generated.XXXXXX")
cp -R "$source_state/." "$state/"
key=$(basename "$state")
printf '%s\n' "$key" > "$image"
slice="$state/slices/$arch"
case "$1" in
  -add_rpath)
    printf '%s\n' "$rpath" >> "$slice/rpaths"
    ;;
  -id)
    printf '%s\n' "$2" > "$slice/id"
    ;;
esac
printf 'invalid\n' > "$state/signature"
""")
  writeExecutable(result.codesignTool, """#!/usr/bin/env bash
set -euo pipefail
{
  printf codesign
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_TOOL_LOG"

image=${@: -1}
key=$(head -n 1 "$image")
state="$FAKE_MACHO_STATE/images/$key"
test -d "$state"
if test "$#" -eq 4 && test "$1" = --force && test "$2" = --sign &&
    test "$3" = -; then
  printf 'valid\n' > "$state/signature"
elif test "$#" -eq 3 && test "$1" = --verify && test "$2" = --strict; then
  test "$(cat "$state/signature")" = valid
else
  exit 64
fi
""")

proc runFixup(fixture: StatefulMachoFixture; failInstallArch = "";
              failLipoCreate = false; badStatMode = false):
              tuple[output: string; exitCode: int] =
  var env = fixture.statefulEnvironment()
  if failInstallArch.len > 0:
    env["FAKE_FAIL_INSTALL_ARCH"] = failInstallArch
  if failLipoCreate:
    env["FAKE_FAIL_LIPO_CREATE"] = "1"
  if badStatMode:
    env["FAKE_BAD_STAT_MODE"] = "1"
  execCmdEx(quoteShellCommand(@["bash", fixture.fixupScript,
    fixture.packageRoot] & fixture.runtimeDirs), env = env)

proc runStatefulAudit(fixture: StatefulMachoFixture):
    tuple[output: string; exitCode: int] =
  execCmdEx(quoteShellCommand(@["bash", fixture.auditScript,
    fixture.packageRoot] & fixture.runtimeDirs),
    env = fixture.statefulEnvironment())

proc signStatefulImages(fixture: StatefulMachoFixture) =
  let env = fixture.statefulEnvironment()
  for image in [fixture.thinExecutable, fixture.thinLibrary,
                fixture.fatLibrary]:
    let signing = execCmdEx(quoteShellCommand(@[fixture.codesignTool,
      "--force", "--sign", "-", image]), env = env)
    doAssert signing.exitCode == 0, signing.output

proc stateArchitectures(fixture: StatefulMachoFixture;
                        image: string): seq[string] =
  readFile(fixture.stateImageRoot(image.imageStateKey) / "archs").splitWhitespace()

proc stateRpaths(fixture: StatefulMachoFixture; image, arch: string): seq[string] =
  for rpath in readFile(fixture.sliceMetadata(image, arch, "rpaths")).splitLines():
    if rpath.len > 0:
      result.add(rpath)

proc stateId(fixture: StatefulMachoFixture; image, arch: string): string =
  readFile(fixture.sliceMetadata(image, arch, "id")).strip()

proc countValue(values: openArray[string]; expected: string): int =
  for value in values:
    if value == expected:
      inc result

proc loggedCalls(fixture: StatefulMachoFixture; tool: string): seq[seq[string]] =
  for line in readFile(fixture.toolLog).splitLines():
    if line.len == 0:
      continue
    let fields = line.split('\t')
    if fields[0] == tool:
      result.add(fields)

proc scratchIsEmpty(fixture: StatefulMachoFixture): bool =
  for _ in walkDir(fixture.scratchRoot):
    return false
  true

proc packageScratchIsEmpty(fixture: StatefulMachoFixture): bool =
  for directory in [fixture.packageRoot / "bin", fixture.packageRoot / "lib"]:
    for kind, path in walkDir(directory):
      if kind in {pcDir, pcLinkToDir} and
          path.extractFilename.startsWith(".repro-macho-fixup."):
        return false
  true

proc numericFileMode(path: string): string =
  let mode = execCmdEx(quoteShellCommand(@["stat", "-c", "%a", path]))
  doAssert mode.exitCode == 0, mode.output
  mode.output.strip()

proc isPackageScratchPath(fixture: StatefulMachoFixture; path: string): bool =
  for directory in [fixture.packageRoot / "bin", fixture.packageRoot / "lib"]:
    if path.startsWith(directory / ".repro-macho-fixup."):
      return true
  false

when defined(posix):
  suite "strict per-slice Mach-O runtime audit":
    let repoRoot = getCurrentDir()

    test "actual binding helpers select relocatable Darwin loader names":
      check zstd_names.zstdDynlibName(zstd_names.zdtWindows) == "libzstd.dll"
      check zstd_names.zstdDynlibName(zstd_names.zdtLinux) == "libzstd.so.1"
      check zstd_names.zstdDynlibName(zstd_names.zdtDarwin) ==
        "@rpath/libzstd.1.dylib"
      check clingo_names.clingoDynlibName(clingo_names.cdtWindows) ==
        "clingo.dll"
      check clingo_names.clingoDynlibName(clingo_names.cdtLinux) ==
        "libclingo.so"
      check clingo_names.clingoDynlibName(clingo_names.cdtDarwin) ==
        "@rpath/libclingo.dylib"

    test "exact fixup is atomic, per-slice, mode preserving, and idempotent":
      let fixture = makeStatefulFixture(repoRoot)
      defer: removeDir(fixture.root)
      let executableMode = getFilePermissions(fixture.thinExecutable)
      let thinLibraryMode = getFilePermissions(fixture.thinLibrary)
      let fatLibraryMode = getFilePermissions(fixture.fatLibrary)
      let nonMachoMode = getFilePermissions(fixture.nonMacho)
      let executableNumericMode = numericFileMode(fixture.thinExecutable)
      let thinLibraryNumericMode = numericFileMode(fixture.thinLibrary)
      let fatLibraryNumericMode = numericFileMode(fixture.fatLibrary)
      let nonMachoContents = readFile(fixture.nonMacho)
      check executableNumericMode.len == 3
      check thinLibraryNumericMode.len == 3
      check fatLibraryNumericMode.len == 4

      let fixup = fixture.runFixup()
      checkpoint fixup.output
      check fixup.exitCode == 0
      check fixup.output.len == 0
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()
      check getFilePermissions(fixture.thinExecutable) == executableMode
      check getFilePermissions(fixture.thinLibrary) == thinLibraryMode
      check getFilePermissions(fixture.fatLibrary) == fatLibraryMode
      check getFilePermissions(fixture.nonMacho) == nonMachoMode
      check numericFileMode(fixture.thinExecutable) == executableNumericMode
      check numericFileMode(fixture.thinLibrary) == thinLibraryNumericMode
      check numericFileMode(fixture.fatLibrary) == fatLibraryNumericMode
      check readFile(fixture.nonMacho) == nonMachoContents
      check fixture.stateArchitectures(fixture.thinExecutable) == @["x86_64"]
      check fixture.stateArchitectures(fixture.thinLibrary) == @["arm64"]
      check fixture.stateArchitectures(fixture.fatLibrary) ==
        @["arm64", "arm64e"]

      for image in [fixture.thinExecutable, fixture.thinLibrary,
                    fixture.fatLibrary]:
        for arch in fixture.stateArchitectures(image):
          let rpaths = fixture.stateRpaths(image, arch)
          check rpaths.len == fixture.runtimeDirs.len
          for runtimeDir in fixture.runtimeDirs:
            check countValue(rpaths, runtimeDir) == 1
      check fixture.stateId(fixture.thinExecutable, "x86_64").len == 0
      check fixture.stateId(fixture.thinLibrary, "arm64") ==
        fixture.thinLibrary
      check fixture.stateId(fixture.fatLibrary, "arm64") == fixture.fatLibrary
      check fixture.stateId(fixture.fatLibrary, "arm64e") == fixture.fatLibrary

      let fileCalls = fixture.loggedCalls("file")
      check fileCalls.len == 4
      for call in fileCalls:
        check call.len == 3
        check call[1] == "-b"
      let statCalls = fixture.loggedCalls("stat")
      check statCalls == @[
        @["stat", "-c", "%a", fixture.thinExecutable],
        @["stat", "-c", "%a", fixture.fatLibrary],
        @["stat", "-c", "%a", fixture.thinLibrary]
      ]

      let lipoCalls = fixture.loggedCalls("lipo")
      var thinCalls: seq[seq[string]]
      var createCalls: seq[seq[string]]
      for call in lipoCalls:
        if call.len >= 2 and call[1] == "-create":
          createCalls.add(call)
        elif call.len == 6 and call[2] == "-thin":
          thinCalls.add(call)
        check fixture.nonMacho notin call
      check thinCalls.len == 2
      check thinCalls[0][1 .. 3] ==
        @[fixture.fatLibrary, "-thin", "arm64"]
      check thinCalls[1][1 .. 3] ==
        @[fixture.fatLibrary, "-thin", "arm64e"]
      for call in thinCalls:
        check call[4] == "-output"
        check call[5].startsWith(
          fixture.fatLibrary.parentDir / ".repro-macho-fixup.")
        check fixture.isPackageScratchPath(call[5])
        check call[5].extractFilename == call[3]
      check createCalls.len == 1
      check createCalls[0].len == 6
      check createCalls[0][2].extractFilename == "arm64"
      check createCalls[0][3].extractFilename == "arm64e"
      check createCalls[0][4] == "-output"
      check createCalls[0][5].extractFilename == "rebuilt"
      for index in 2 .. 3:
        check createCalls[0][index].startsWith(
          fixture.fatLibrary.parentDir / ".repro-macho-fixup.")
        check fixture.isPackageScratchPath(createCalls[0][index])
      check fixture.isPackageScratchPath(createCalls[0][5])

      let cpCalls = fixture.loggedCalls("cp")
      check cpCalls.len == 2
      check cpCalls[0].len == 3
      check cpCalls[0][1] == fixture.thinExecutable
      check cpCalls[0][2].extractFilename == "x86_64"
      check cpCalls[0][2].startsWith(
        fixture.thinExecutable.parentDir / ".repro-macho-fixup.")
      check fixture.isPackageScratchPath(cpCalls[0][2])
      check cpCalls[1].len == 3
      check cpCalls[1][1] == fixture.thinLibrary
      check cpCalls[1][2].extractFilename == "arm64"
      check cpCalls[1][2].startsWith(
        fixture.thinLibrary.parentDir / ".repro-macho-fixup.")
      check fixture.isPackageScratchPath(cpCalls[1][2])

      let installCallsBeforeRerun = fixture.loggedCalls("install_name_tool")
      var addCount = 0
      var idCount = 0
      for call in installCallsBeforeRerun:
        if call[1] == "-add_rpath":
          inc addCount
          check call.len == 4
        elif call[1] == "-id":
          inc idCount
          check call.len == 4
          check call[2] in [fixture.thinLibrary, fixture.fatLibrary]
        else:
          check false
        check fixture.isPackageScratchPath(call[^1])
      check addCount == 20
      check idCount == 3

      let mvCalls = fixture.loggedCalls("mv")
      check mvCalls.len == 3
      check mvCalls[0][1] == "-f"
      check mvCalls[0][3] == fixture.thinExecutable
      check mvCalls[1][1] == "-f"
      check mvCalls[1][3] == fixture.fatLibrary
      check mvCalls[2][1] == "-f"
      check mvCalls[2][3] == fixture.thinLibrary
      for call in mvCalls:
        check call.len == 4
        check fixture.isPackageScratchPath(call[2])
        check call[2].parentDir.parentDir == call[3].parentDir

      fixture.signStatefulImages()
      let lipoCallCountBeforeAudit = fixture.loggedCalls("lipo").len
      let audit = fixture.runStatefulAudit()
      checkpoint audit.output
      check audit.exitCode == 0
      check audit.output.len == 0
      let lipoCallsAfterAudit = fixture.loggedCalls("lipo")
      for index in lipoCallCountBeforeAudit ..< lipoCallsAfterAudit.len:
        for argument in lipoCallsAfterAudit[index]:
          check not argument.contains(".repro-macho-fixup.")

      let secondFixup = fixture.runFixup()
      checkpoint secondFixup.output
      check secondFixup.exitCode == 0
      check secondFixup.output.len == 0
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()
      check getFilePermissions(fixture.thinExecutable) == executableMode
      check getFilePermissions(fixture.thinLibrary) == thinLibraryMode
      check getFilePermissions(fixture.fatLibrary) == fatLibraryMode
      check numericFileMode(fixture.thinExecutable) == executableNumericMode
      check numericFileMode(fixture.thinLibrary) == thinLibraryNumericMode
      check numericFileMode(fixture.fatLibrary) == fatLibraryNumericMode
      let installCallsAfterRerun = fixture.loggedCalls("install_name_tool")
      var secondAddCount = 0
      var secondIdCount = 0
      for call in installCallsAfterRerun:
        if call[1] == "-add_rpath":
          inc secondAddCount
        elif call[1] == "-id":
          inc secondIdCount
      check secondAddCount == addCount
      check secondIdCount == idCount * 2
      for image in [fixture.thinExecutable, fixture.thinLibrary,
                    fixture.fatLibrary]:
        for arch in fixture.stateArchitectures(image):
          let rpaths = fixture.stateRpaths(image, arch)
          check rpaths.len == fixture.runtimeDirs.len
          for runtimeDir in fixture.runtimeDirs:
            check countValue(rpaths, runtimeDir) == 1
      fixture.signStatefulImages()
      let secondAudit = fixture.runStatefulAudit()
      checkpoint secondAudit.output
      check secondAudit.exitCode == 0
      check secondAudit.output.len == 0

    test "invalid GNU stat mode fails before mutation and recovers":
      let fixture = makeStatefulFixture(repoRoot)
      defer: removeDir(fixture.root)
      let executableContents = readFile(fixture.thinExecutable)
      let thinLibraryContents = readFile(fixture.thinLibrary)
      let fatLibraryContents = readFile(fixture.fatLibrary)
      let executableMode = numericFileMode(fixture.thinExecutable)
      let thinLibraryMode = numericFileMode(fixture.thinLibrary)
      let fatLibraryMode = numericFileMode(fixture.fatLibrary)

      let failed = fixture.runFixup(badStatMode = true)
      checkpoint failed.output
      check failed.exitCode != 0
      check failed.output.contains("stat returned an invalid file mode")
      check fixture.loggedCalls("stat") == @[
        @["stat", "-c", "%a", fixture.thinExecutable]
      ]
      check fixture.loggedCalls("cp").len == 0
      check fixture.loggedCalls("install_name_tool").len == 0
      check fixture.loggedCalls("mv").len == 0
      check readFile(fixture.thinExecutable) == executableContents
      check readFile(fixture.thinLibrary) == thinLibraryContents
      check readFile(fixture.fatLibrary) == fatLibraryContents
      check numericFileMode(fixture.thinExecutable) == executableMode
      check numericFileMode(fixture.thinLibrary) == thinLibraryMode
      check numericFileMode(fixture.fatLibrary) == fatLibraryMode
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()

      let recovered = fixture.runFixup()
      checkpoint recovered.output
      check recovered.exitCode == 0
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()
      fixture.signStatefulImages()
      let audit = fixture.runStatefulAudit()
      checkpoint audit.output
      check audit.exitCode == 0
      check audit.output.len == 0

    test "slice mutation failure preserves the installed image and recovers":
      let fixture = makeStatefulFixture(repoRoot)
      defer: removeDir(fixture.root)
      let originalFatContents = readFile(fixture.fatLibrary)
      let originalFatMode = getFilePermissions(fixture.fatLibrary)
      let originalArmRpaths =
        fixture.stateRpaths(fixture.fatLibrary, "arm64")
      let originalArm64eRpaths =
        fixture.stateRpaths(fixture.fatLibrary, "arm64e")

      let failed = fixture.runFixup(failInstallArch = "arm64e")
      checkpoint failed.output
      check failed.exitCode != 0
      check readFile(fixture.fatLibrary) == originalFatContents
      check getFilePermissions(fixture.fatLibrary) == originalFatMode
      check fixture.stateRpaths(fixture.fatLibrary, "arm64") ==
        originalArmRpaths
      check fixture.stateRpaths(fixture.fatLibrary, "arm64e") ==
        originalArm64eRpaths
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()

      let recovered = fixture.runFixup()
      checkpoint recovered.output
      check recovered.exitCode == 0
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()
      fixture.signStatefulImages()
      let audit = fixture.runStatefulAudit()
      checkpoint audit.output
      check audit.exitCode == 0
      check audit.output.len == 0

    test "fat reassembly failure preserves the installed image and recovers":
      let fixture = makeStatefulFixture(repoRoot)
      defer: removeDir(fixture.root)
      let originalFatContents = readFile(fixture.fatLibrary)
      let originalFatMode = getFilePermissions(fixture.fatLibrary)
      let originalArmRpaths =
        fixture.stateRpaths(fixture.fatLibrary, "arm64")
      let originalArm64eRpaths =
        fixture.stateRpaths(fixture.fatLibrary, "arm64e")

      let failed = fixture.runFixup(failLipoCreate = true)
      checkpoint failed.output
      check failed.exitCode != 0
      check readFile(fixture.fatLibrary) == originalFatContents
      check getFilePermissions(fixture.fatLibrary) == originalFatMode
      check fixture.stateRpaths(fixture.fatLibrary, "arm64") ==
        originalArmRpaths
      check fixture.stateRpaths(fixture.fatLibrary, "arm64e") ==
        originalArm64eRpaths
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()

      let recovered = fixture.runFixup()
      checkpoint recovered.output
      check recovered.exitCode == 0
      check fixture.scratchIsEmpty()
      check fixture.packageScratchIsEmpty()
      fixture.signStatefulImages()
      let audit = fixture.runStatefulAudit()
      checkpoint audit.output
      check audit.exitCode == 0
      check audit.output.len == 0

    test "valid fat images pass with loader, executable, and rpath deps":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      let audit = fixture.runAudit()
      checkpoint audit.output
      check audit.exitCode == 0
      check audit.output.len == 0

    test "missing absolute Nix-store dependency is rejected":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      fixture.addDependency(fixture.executable, "x86_64",
        "/nix/store/reprobuild-missing/lib/missing.dylib")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("missing absolute dependency")

    test "missing loader-relative dependency is rejected":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      removeFile(fixture.packageRoot / "bin" / "local-loader.dylib")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("missing @loader_path dependency")

    test "missing executable-relative dependency is rejected":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      removeFile(fixture.packageRoot / "bin" / "local-exec.dylib")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("missing @executable_path dependency")

    test "missing rpath dependency is rejected":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      removeFile(fixture.runtimeDirs[0] / "libzstd.1.dylib")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("unresolved @rpath dependency")

    test "one invalid fat slice rejects the whole image":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      writeFile(fixture.metadataPath(fixture.library, "arm64e", "deps"),
        "@loader_path/not-present.dylib\n")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("[arm64e]")
      check audit.output.contains("missing @loader_path dependency")

    test "RPATH entries split across fat slices are not unioned":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      writeFile(fixture.metadataPath(fixture.executable, "x86_64", "rpaths"),
        fixture.runtimeDirs[0 .. 2].join("\n") & "\n")
      writeFile(fixture.metadataPath(fixture.executable, "arm64", "rpaths"),
        fixture.runtimeDirs[3 .. 5].join("\n") & "\n")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("[x86_64]")
      check audit.output.contains("missing LC_RPATH")

    test "install IDs are validated independently per slice":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      writeFile(fixture.metadataPath(fixture.library, "arm64e", "id"),
        "/nix/store/wrong/lib/librepro-runtime.dylib\n")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("[arm64e]")
      check audit.output.contains("incorrect install ID")

    test "bare Darwin loader dependency is rejected":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      fixture.addDependency(fixture.executable, "x86_64",
        "libzstd.1.dylib")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
      check audit.output.contains("bare or unsupported dependency")

    test "invalid arm signature is rejected after all slice checks":
      let fixture = makeFixture(repoRoot)
      defer: removeDir(fixture.root)
      writeFile(fixture.metadataRoot / ".repro-wrapped.signature", "invalid\n")
      let audit = fixture.runAudit()
      check audit.exitCode != 0
