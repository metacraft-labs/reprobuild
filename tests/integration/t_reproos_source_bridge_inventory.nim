import std/[os, strutils, unittest]

const MigratedPackages = [
  "parted", "dosfstools", "lvm2", "gdisk", "less", "procps",
  "cryptsetup", "iproute2",
  "xkeyboard-config",
  "libxkbfile", "xkbcomp",
  "adwaita-icon-theme",
  "xz",
  "tar",
  "bash",
  "glibc",
  "coreutils",
  "grub",
  "kernel",
  "musl", "busybox",
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
  test "rootfs is package-free and migrated packages are required from source":
    let repoRoot = findRepoRoot()
    let baseScript = readFile(repoRoot / "recipes" / "reproos-iso" /
      "scripts" / "build-base-rootfs.sh")
    let stageScript = readFile(repoRoot / "recipes" / "reproos-iso" /
      "scripts" / "stage-de-rootfs.sh")

    let sourceBridges = shellArrayEntries(stageScript,
      "BASE_USERSPACE_RECIPES")
    check sourceBridges.len > 0

    for packageName in MigratedPackages:
      check packageName in sourceBridges

    let normalizedBaseScript = baseScript.toLowerAscii
    check "debian:" notin normalizedBaseScript
    check "docker" notin normalizedBaseScript
    check "apt-get" notin normalizedBaseScript
    check "dpkg" notin normalizedBaseScript
    check "pkg_list" notin normalizedBaseScript
    check "--sort=name" in baseScript
    check "--mtime=\"@${SOURCE_DATE_EPOCH}\"" in baseScript
    check "--owner=0" in baseScript
    check "--group=0" in baseScript
    check "ID=reproos" in baseScript
    check "live:x:1000:" in baseScript
    check "ln -s usr/bin \"$ROOTFS_DIR/bin\"" in baseScript
    check "ln -s bash \"$ROOTFS_DIR/usr/bin/sh\"" in baseScript
    check "tar --same-permissions" in stageScript
    check "required source mirror missing: $recipe" in stageScript
    check "required iproute2 ss binary missing" in stageScript
    check "$STAGE_DIR/usr/bin/ss" in stageScript
    check "required xkeyboard-config data missing" in stageScript
    check "$STAGE_DIR/usr/share/X11/xkb" in stageScript
    check "required source xkbcomp binary missing" in stageScript
    check "required Adwaita icon data missing" in stageScript
    check "$STAGE_DIR/usr/share/icons/Adwaita" in stageScript
    check "required source xz binary missing" in stageScript
    check "required source liblzma SONAME missing" in stageScript
    check "xz_source_lib" in stageScript
    check "failed to set source liblzma RPATH" in stageScript
    check "required source tar binary missing" in stageScript
    check "required source bash binary missing" in stageScript
    check "required source glibc ldconfig missing" in stageScript
    check "required source glibc runtime missing" in stageScript
    # Compatible source-built ELFs must use the source glibc at image runtime.
    check "SOURCE_GLIBC_LOADER" in stageScript
    check "SOURCE_GLIBC_VERSION" in stageScript
    check "source_runtime_elf" in stageScript
    check "source_glibc_supports_interpreter" in stageScript
    check "\"$SOURCE_GLIBC_LOADER\"" in stageScript
    check "required source coreutils binary missing" in stageScript
    check "required source kernel payload missing" in stageScript
    check "source kernel module tree is contaminated" in stageScript
    check "$STAGE_DIR/usr/lib/modules" in stageScript
    check "usr/lib|/usr/lib" in stageScript
    check "unsupported /lib symlink target" in stageScript
    check "return 1" in stageScript
