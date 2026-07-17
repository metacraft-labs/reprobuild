import std/[os, strutils, unittest]

const MigratedPackages = [
  "parted", "dosfstools", "lvm2", "gdisk", "less", "procps",
  "cryptsetup", "iproute2",
  "xkeyboard-config",
  "libxkbfile", "xkbcomp",
  "adwaita-icon-theme",
  "xz",
]

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and dirExists(dir / "recipes"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot locate reprobuild repository root")

proc shellArrayEntries(text, marker: string): seq[string] =
  let startPos = text.find(marker & "=(")
  if startPos < 0:
    return
  let bodyStart = startPos + marker.len + 2
  let endPos = text.find("\n)", bodyStart)
  if endPos < 0:
    return
  for line in text[bodyStart ..< endPos].splitLines:
    let code = line.split('#', maxsplit = 1)[0].strip
    result.add(code.splitWhitespace)

suite "ReproOS source bridge inventory":
  test "migrated packages are required from source and absent from apt inputs":
    let repoRoot = findRepoRoot()
    let baseScript = readFile(repoRoot / "recipes" / "reproos-iso" /
      "scripts" / "build-base-rootfs.sh")
    let stageScript = readFile(repoRoot / "recipes" / "reproos-iso" /
      "scripts" / "stage-de-rootfs.sh")

    let aptPackages = shellArrayEntries(baseScript, "PKG_LIST")
    let sourceBridges = shellArrayEntries(stageScript,
      "BASE_USERSPACE_RECIPES")
    check aptPackages.len > 0
    check sourceBridges.len > 0

    for packageName in MigratedPackages:
      check packageName notin aptPackages
      check packageName in sourceBridges

    # Debian's gdb closure pulls procps through libdebuginfod-common and ucf.
    check "gdb" notin aptPackages
    check "required source mirror missing: $recipe" in stageScript
    check "required iproute2 ss binary missing" in stageScript
    check "$STAGE_DIR/usr/bin/ss" in stageScript
    check "required xkeyboard-config data missing" in stageScript
    check "dpkg --purge --force-depends xkb-data" in baseScript
    check "test ! -e /usr/share/X11/xkb" in baseScript
    check "$STAGE_DIR/usr/share/X11/xkb" in stageScript
    check "required source xkbcomp binary missing" in stageScript
    check "required Adwaita icon data missing" in stageScript
    check "$STAGE_DIR/usr/share/icons/Adwaita" in stageScript
    check "required source xz binary missing" in stageScript
    check "required source liblzma SONAME missing" in stageScript
    check "return 1" in stageScript
