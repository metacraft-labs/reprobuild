## Dotfiles-Migration-Completion M0 — claude-code realizations smoke test.
##
## GM4b: the two-version ``claudeCodeCatalog`` record (2.1.169 + 2.1.170) is
## now a set of ``tarball`` realizations of ``package `claude-code``` — the
## canonical definition the engine links (``package_registry``). This test
## asserts that those realizations are well-formed, that the realization
## selection a recipe or profile runs (``selectTarballRecord``) picks the
## right one for each declared (version, cpu, os) slice, that the old default
## (2.1.169) is still what an unpinned reference selects, and that the name
## lookup keeps its documented case + separator sensitivity.

import std/[options, strutils, unittest]

import repro_interface_artifacts
import repro_dsl_stdlib/package_registry
import repro_home_apply/package_catalog

const ExpectedVersions = ["2.1.170", "2.1.169"]

# Every (version, platform) slice declared. Held as a static list so the
# test fails loudly if a future edit drops a slice without updating it.
const ExpectedSlices = [
  (version: "2.1.170", cpu: pcX86_64,  os: poWindows),
  (version: "2.1.170", cpu: pcAArch64, os: poWindows),
  (version: "2.1.170", cpu: pcX86_64,  os: poLinux),
  (version: "2.1.170", cpu: pcAArch64, os: poLinux),
  (version: "2.1.170", cpu: pcX86_64,  os: poMacos),
  (version: "2.1.170", cpu: pcAArch64, os: poMacos),
  (version: "2.1.169", cpu: pcX86_64,  os: poWindows),
  (version: "2.1.169", cpu: pcAArch64, os: poWindows),
  (version: "2.1.169", cpu: pcX86_64,  os: poLinux),
  (version: "2.1.169", cpu: pcAArch64, os: poLinux),
  (version: "2.1.169", cpu: pcX86_64,  os: poMacos),
  (version: "2.1.169", cpu: pcAArch64, os: poMacos),
]

proc isHex64(s: string): bool =
  if s.len != 64: return false
  for ch in s:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

let records = profileToolUse("claude-code").useDef.tarballProvisioning

proc selectSlice(version: string; cpu: PlatformCpu; os: PlatformOs):
    tuple[ok: bool; record: InterfaceTarballProvisioning] =
  let choice = selectTarballRecord(records,
    realizationTargetFor(cpu, os, baselineMicroarchLevel(cpu)), version)
  if choice.status != kcSelected:
    return (false, InterfaceTarballProvisioning())
  (true, records[choice.index])

suite "Dotfiles-Migration-Completion M0 — claude-code realizations":

  test "the definition is linked and lists both expected versions":
    check isLinkedPackage("claude-code")
    check records.len == ExpectedSlices.len
    var sawVersions: seq[string] = @[]
    for r in records:
      if r.detail.version notin sawVersions:
        sawVersions.add(r.detail.version)
    check sawVersions.len == 2
    for expected in ExpectedVersions:
      check expected in sawVersions

  test "every declared (version, platform) slice selects cleanly":
    for slice in ExpectedSlices:
      let pick = selectSlice(slice.version, slice.cpu, slice.os)
      check pick.ok
      if not pick.ok:
        echo "MISSING slice: " & slice.version & " " & $slice.cpu & "/" &
          $slice.os
        continue
      check pick.record.url.len > 0
      check isHex64(pick.record.sha256)
      check pick.record.detail.version == slice.version
      # A raw distribution never carries an inner extract path; the
      # upstream ships a single bare binary, realized by the `uses:` edge.
      check pick.record.detail.extractPath == ""
      check pick.record.archiveType == "raw"
      check archiveInstallerFeatures(pick.record).len == 0

  test "an unpinned reference selects the former default version":
    # The retired catalog's default was its LAST record (2.1.169); GM4b's
    # conversion lists it first, and an unpinned reference takes the first
    # eligible realization in declaration order.
    for cpu in [pcX86_64, pcAArch64]:
      for os in [poWindows, poLinux, poMacos]:
        let pick = selectSlice("", cpu, os)
        check pick.ok
        check pick.record.detail.version == "2.1.169"

  test "Windows slices declare claude.exe; non-Windows declare claude":
    for slice in ExpectedSlices:
      let pick = selectSlice(slice.version, slice.cpu, slice.os)
      check pick.ok
      if not pick.ok: continue
      if slice.os == poWindows:
        check pick.record.executablePath == "claude.exe"
      else:
        check pick.record.executablePath == "claude"

  test "URLs follow the upstream GCS prefix + per-platform suffix":
    const Prefix = "https://storage.googleapis.com/" &
      "claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/" &
      "claude-code-releases/"
    for r in records:
      check r.url.startsWith(Prefix)
      check r.url.contains("/" & r.detail.version & "/")
      if r.os == "windows":
        check r.url.endsWith("/claude.exe")
      else:
        check r.url.endsWith("/claude")

  test "every declared platform slice has a unique URL":
    var seenUrls: seq[string] = @[]
    for r in records:
      check r.url notin seenUrls
      seenUrls.add(r.url)

  test "name lookup: case + separator sensitivity":
    # Package names are case-sensitive and separator-sensitive (kebab vs
    # snake). The negative forms are unknown names.
    check profileToolUse("claude-code").known
    check not profileToolUse("CLAUDE-CODE").known
    check not profileToolUse("Claude-Code").known
    check not profileToolUse("claude_code").known
    check profileToolUse("claude_code").useDef.tarballProvisioning.len == 0
