## Dotfiles-Migration-Completion M0 — claude-code catalog smoke test.
##
## Asserts that the two-version ``claudeCodeCatalog`` (2.1.169 + 2.1.170)
## is structurally well-formed, resolves cleanly for each declared
## (cpu, os) slice across both versions, and round-trips through the
## ``catalog_registry`` lookup with the documented case + separator
## sensitivity contract.

import std/[options, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/packages/claude_code
import repro_dsl_stdlib/catalog_registry

const ExpectedVersions = ["2.1.170", "2.1.169"]

# Per the M0 brief: every (version, platform) slice declared in the
# catalog. Held as a static list so the test fails loudly if a future
# edit drops a slice without updating the expectation.
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

suite "Dotfiles-Migration-Completion M0 — claude-code catalog":

  test "catalog is non-empty and lists both expected versions":
    check claudeCodeCatalog.len == 2
    var sawVersions: seq[string] = @[]
    for vp in claudeCodeCatalog:
      sawVersions.add(vp.version)
    for expected in ExpectedVersions:
      check expected in sawVersions

  test "validateCatalog returns no errors":
    let errors = validateCatalog(claudeCodeCatalog)
    if errors.len > 0:
      for e in errors: echo "validateCatalog error: " & e
    check errors.len == 0

  test "every declared (version, platform) slice resolves cleanly":
    for slice in ExpectedSlices:
      let pick = selectVersion(claudeCodeCatalog, slice.version)
      check pick.found
      if not pick.found:
        echo "MISSING version: " & slice.version
        continue
      # validateVersionedProvisioning per-version (the M0 brief: "real
      # validateVersionedProvisioning calls").
      let perVpErrors = validateVersionedProvisioning(pick.entry)
      if perVpErrors.len > 0:
        for e in perVpErrors:
          echo "validateVersionedProvisioning error (" &
            slice.version & "): " & e
      check perVpErrors.len == 0
      let sel = selectPlatformBinary(pick.entry, slice.cpu, slice.os)
      check sel.found
      if not sel.found:
        echo "MISSING slice: " & slice.version & " " &
          $slice.cpu & "/" & $slice.os
        continue
      let pb = sel.binary
      check pb.url.len > 0
      check pb.sha256.len == 64
      check isHex64(pb.sha256)
      # afRaw never carries an inner extract_path; the upstream
      # distribution is a single bare binary.
      check pb.extract_path == ""

  test "Windows slices declare claude.exe; non-Windows declare claude":
    for slice in ExpectedSlices:
      let pick = selectVersion(claudeCodeCatalog, slice.version)
      check pick.found
      if not pick.found: continue
      let sel = selectPlatformBinary(pick.entry, slice.cpu, slice.os)
      check sel.found
      if not sel.found: continue
      # bin_relpath is the resolved binary path. Windows uses the parent
      # ``bin_relpath`` (@["claude.exe"]); non-Windows slices use the
      # per-platform ``bin_relpath_override`` (@["claude"]).
      let pb = sel.binary
      if slice.os == poWindows:
        check pick.entry.bin_relpath == @["claude.exe"]
        # No override on Windows.
        check pb.bin_relpath_override.len == 0
      else:
        check pb.bin_relpath_override == @["claude"]

  test "no slice carries an inner extract_path (afRaw distribution)":
    for vp in claudeCodeCatalog:
      check vp.archive_format == afRaw
      check vp.install_method == imExtract
      for pb in vp.platforms:
        check pb.extract_path == ""
        # No per-platform archive override either — afRaw is uniform.
        check not pb.has_archive_format_override

  test "URLs follow the upstream GCS prefix + per-platform suffix":
    const Prefix = "https://storage.googleapis.com/" &
      "claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/" &
      "claude-code-releases/"
    for vp in claudeCodeCatalog:
      for pb in vp.platforms:
        check pb.url.startsWith(Prefix)
        check pb.url.contains("/" & vp.version & "/")
        if pb.os == poWindows:
          check pb.url.endsWith("/claude.exe")
        else:
          check pb.url.endsWith("/claude")

  test "every declared platform slice has a unique URL":
    var seenUrls: seq[string] = @[]
    for vp in claudeCodeCatalog:
      for pb in vp.platforms:
        check pb.url notin seenUrls
        seenUrls.add(pb.url)

  test "registry lookup: getCatalog('claude-code') returns the catalog":
    let opt = getCatalog("claude-code")
    check opt.isSome
    if opt.isSome:
      check opt.get().len == claudeCodeCatalog.len

  test "registry lookup: case + separator sensitivity":
    # Documented contract: registry keys are case-sensitive and
    # separator-sensitive (kebab vs snake). Both negative forms must
    # return none.
    check getCatalog("CLAUDE-CODE").isNone
    check getCatalog("Claude-Code").isNone
    check getCatalog("claude_code").isNone

  test "isRegistered reports true for claude-code":
    check isRegistered("claude-code")
    check not isRegistered("claude_code")
