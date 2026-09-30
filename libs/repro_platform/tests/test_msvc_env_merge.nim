## The MSVC developer environment and an action's own environment are
## MERGED; neither replaces the other's search lists.
##
## WHAT BROKE. ``mergeActionEnvWithMsvc`` emitted the VsDevCmd variables first
## and the action's ``KEY=VALUE`` entries after them, and both consumers of the
## argv-style env resolve a duplicate key to its RIGHTMOST entry. An action
## that declares its own ``PATH`` (every typed-tool edge does — the engine
## prepends each tool's bin dir) therefore REPLACED the PATH that carried
## ``VC\Tools\MSVC\<ver>\bin\HostX64\x64``, while ``VCINSTALLDIR`` /
## ``VCToolsInstallDir`` / ``LIB`` / ``INCLUDE`` survived. The Rust ``cc``
## crate reads ``VCINSTALLDIR`` as "the environment is already configured",
## looks for ``cl.exe`` on PATH only, and failed:
##
##   zstd-sys: failed to find tool "cl.exe"
##
## on a Windows runner with Build Tools 14.44 installed (cardano and circom
## recorder lanes). The same happens when the engine itself runs inside an
## activated shell: the inherited PATH carries the MSVC entries and the
## action's declared PATH replaces it.
##
## WHAT IS ASSERTED, on the pure merge (``mergeActionEnvWithMsvcEnv``) and the
## pure ownership filter (``msvcOwnedEntries``):
##   1. An action PATH keeps its own entries FIRST (tool precedence) and gains
##      the MSVC-owned entries after them; ``cl.exe``'s directory is present.
##   2. Only MSVC-owned entries are added — an ambient entry VsDevCmd merely
##      passed through (``C:\Windows\System32``, ``C:\Git\usr\bin``) is not
##      smuggled into an action that declared its own PATH.
##   3. Entries are deduplicated case-insensitively and irrespective of a
##      trailing separator, and the key match is case-insensitive (``Path``).
##   4. LIB / INCLUDE / LIBPATH declared by an action are combined the same
##      way; a key the action does NOT declare is left to the dev-env value.
##   5. Non-list keys keep the documented contract: the action's value wins.
##   6. Unavailable dev env: the action env is returned unchanged.
##   7. The inherited-activation case: ownership is derived from the
##      inherited roots (``VSINSTALLDIR`` etc.), so a nested engine also keeps
##      ``cl.exe`` reachable.
##
## Platform-independent: both procs are pure string functions using Windows
## semantics (``;`` separator, case-insensitive), so this runs on every host.
## No mocks: the inputs are literal environments of the shape VsDevCmd emits.

import std/[strutils, tables, unittest]

import repro_platform

const
  VcBin = r"C:\BuildTools\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64"
  SdkBin = r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64"
  CargoBin = r"C:\tool-store\prefixes\cargo\bin"

proc valueOf(env: seq[string]; key: string): string =
  ## Rightmost-wins, case-insensitive — the consumers' resolution rule.
  result = ""
  for entry in env:
    let eq = entry.find('=')
    if eq > 0 and cmpIgnoreCase(entry[0 ..< eq], key) == 0:
      result = entry[eq + 1 .. ^1]

proc entriesOf(value: string): seq[string] =
  for part in value.split(';'):
    if part.len > 0: result.add(part)

proc devEnv(): MsvcDevEnv =
  var t = initTable[string, string]()
  t["VSINSTALLDIR"] = r"C:\BuildTools\"
  t["VCINSTALLDIR"] = r"C:\BuildTools\VC\"
  t["VCToolsInstallDir"] = r"C:\BuildTools\VC\Tools\MSVC\14.44.35207\"
  t["WindowsSdkDir"] = r"C:\Program Files (x86)\Windows Kits\10\"
  t["Path"] = VcBin & ";" & SdkBin & r";C:\Windows\System32;C:\Git\usr\bin"
  t["LIB"] = r"C:\BuildTools\VC\Tools\MSVC\14.44.35207\lib\x64;" &
    r"C:\Program Files (x86)\Windows Kits\10\lib\10.0.26100.0\ucrt\x64"
  t["INCLUDE"] = r"C:\BuildTools\VC\Tools\MSVC\14.44.35207\include"
  t["CC"] = "cl.exe"
  MsvcDevEnv(available: true, env: t)

suite "MSVC dev-env merge keeps the MSVC search lists":

  test "an action PATH keeps its own entries first and gains cl.exe's directory":
    let merged = mergeActionEnvWithMsvcEnv(devEnv(),
      @["PATH=" & CargoBin & r";C:\Windows\System32"])
    let path = entriesOf(valueOf(merged, "PATH"))
    check path.len >= 3
    check path[0] == CargoBin
    check VcBin in path
    check SdkBin in path

  test "only MSVC-owned entries are added to a declared PATH":
    let merged = mergeActionEnvWithMsvcEnv(devEnv(), @["PATH=" & CargoBin])
    let path = entriesOf(valueOf(merged, "PATH"))
    check r"C:\Git\usr\bin" notin path
    check r"C:\Windows\System32" notin path

  test "dedup is case-insensitive and ignores a trailing separator":
    let merged = mergeActionEnvWithMsvcEnv(devEnv(),
      @["Path=" & CargoBin & ";" & VcBin.toLowerAscii() & "\\"])
    let path = entriesOf(valueOf(merged, "PATH"))
    var vcCount = 0
    for p in path:
      if cmpIgnoreCase(p.strip(leading = false, chars = {'\\', '/'}),
          VcBin) == 0:
        inc vcCount
    check vcCount == 1
    check path[0] == CargoBin

  test "LIB and INCLUDE declared by the action are combined, not replaced":
    let merged = mergeActionEnvWithMsvcEnv(devEnv(),
      @[r"INCLUDE=C:\proj\include"])
    let inc = entriesOf(valueOf(merged, "INCLUDE"))
    check inc[0] == r"C:\proj\include"
    check r"C:\BuildTools\VC\Tools\MSVC\14.44.35207\include" in inc
    # Undeclared LIB: the dev-env value is what the action sees.
    check valueOf(merged, "LIB") == devEnv().env["LIB"]

  test "a non-list key keeps action-wins":
    let merged = mergeActionEnvWithMsvcEnv(devEnv(), @["CC=clang-cl.exe"])
    check valueOf(merged, "CC") == "clang-cl.exe"

  test "an unavailable dev env returns the action env unchanged":
    let action = @["PATH=" & CargoBin, "X=1"]
    check mergeActionEnvWithMsvcEnv(MsvcDevEnv(available: false), action) ==
      action

  test "an inherited activation keeps cl.exe reachable too":
    # A nested engine: the activation lives in the INHERITED environment and
    # the cached dev env carries no table. Ownership comes from the inherited
    # roots; the PATH to draw from is the inherited one.
    let inherited = inheritedMsvcDevEnv(
      path = VcBin & r";C:\Windows\System32;" & SdkBin,
      roots = @[r"C:\BuildTools\", r"C:\Program Files (x86)\Windows Kits\10\"])
    check inherited.available
    let merged = mergeActionEnvWithMsvcEnv(inherited, @["PATH=" & CargoBin])
    let path = entriesOf(valueOf(merged, "PATH"))
    check path[0] == CargoBin
    check VcBin in path
    check SdkBin in path
    check r"C:\Windows\System32" notin path

  test "msvcOwnedEntries keeps only entries under an MSVC root":
    let owned = msvcOwnedEntries(
      VcBin & r";C:\Windows;c:\buildtools\common7\ide;C:\BuildToolsX\bin",
      @[r"C:\BuildTools\"])
    check owned == @[VcBin, r"c:\buildtools\common7\ide"]
