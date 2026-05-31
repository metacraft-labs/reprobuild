## M2.5 (Realize-Closure-And-Catalog-Expansion) hermetic gate for the
## `adapterPreference:` DSL block parser. Covers both the text-form
## parser (`repro_home_intent/parser.nim`) AND the closed-set / error
## paths. The macro-form / text-form parity assertion lives in a
## sibling bridge test (`test_m25_adapter_preference_text_macro_parity.nim`).
##
## The contract this gate enforces, from the M2.5 spec:
##
##   * a profile WITHOUT an `adapterPreference:` block parses to an
##     empty per-OS table on the AST (`Profile.adapterPreference.len ==
##     0`), signaling "use the M65 platform default at resolve time".
##   * a profile WITH a block carrying all three recognized OS keys
##     populates a 3-entry table; chain order is preserved verbatim
##     (the parser does NOT canonicalize chain order).
##   * a profile with a partial block (e.g. only `windows:`) populates
##     just that key; the resolve-time fallback to the M65 platform
##     default for the other OSes is asserted in the plumbing gate
##     (`test_m25_adapter_preference_plumbed.nim`).
##   * `macos` is parsed and canonicalized to `darwin` so a single
##     resolve-time lookup suffices.
##   * an unknown OS key (e.g. `freebsd:`) raises `EUnstructured` with
##     the offending token + the closed-set in the diagnostic.
##   * an unknown adapter name (e.g. `[scoop, nonsense]`) raises
##     `EUnstructured` with the offending token + the closed-set in the
##     diagnostic.
##   * an empty list (`windows: []`) parses to a present-but-empty
##     chain; the resolve-time fallback for an empty seq is asserted in
##     the plumbing gate (the parser itself accepts the shape — a
##     present-empty seq is distinguishable from "absent" in the AST
##     table only via `OrderedTable.hasKey`, which both branches
##     deliberately preserve).

import std/[os, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_intent

const ProfileWithFullAdapterPreference = """
import repro/profile

profile "with-full-pref":
  adapterPreference:
    windows: [scoop, builtin, path]
    linux: [nix, builtin, path]
    darwin: [nix, path]

  activity default:
    just
"""

const ProfileWithPartialAdapterPreference = """
import repro/profile

profile "with-windows-only-pref":
  adapterPreference:
    windows: [scoop, builtin, path]

  activity default:
    just
"""

const ProfileWithMacosAlias = """
import repro/profile

profile "macos-alias":
  adapterPreference:
    macos: [nix, path]

  activity default:
    just
"""

const ProfileWithoutAdapterPreference = """
import repro/profile

profile "no-pref":
  activity default:
    just
"""

const ProfileWithEmptyChain = """
import repro/profile

profile "empty-chain":
  adapterPreference:
    windows: []

  activity default:
    just
"""

const ProfileWithUnknownOs = """
import repro/profile

profile "unknown-os":
  adapterPreference:
    freebsd: [path]

  activity default:
    just
"""

const ProfileWithUnknownAdapter = """
import repro/profile

profile "unknown-adapter":
  adapterPreference:
    windows: [scoop, nonsense]

  activity default:
    just
"""

const ProfileWithDuplicateOs = """
import repro/profile

profile "dup-os":
  adapterPreference:
    windows: [scoop]
    windows: [path]

  activity default:
    just
"""

proc writeAndParse(dir, name, body: string): Profile =
  let path = dir / name
  writeFile(extendedPath(path), body)
  loadProfile(path)

suite "M2.5 adapterPreference DSL — text-parser parse paths":

  test "test_m25_adapter_preference_parse_absent_block":
    let dir = createTempDir("m25-pref-absent-", "")
    defer: removeDir(dir)
    let p = writeAndParse(dir, "home.nim",
      ProfileWithoutAdapterPreference)
    check p.root.kind == nkProfileRoot
    # Empty table when the block is absent — signals "fall back to M65
    # platform default at resolve time" per the M2.5 spec.
    check p.adapterPreference.len == 0

  test "test_m25_adapter_preference_parse_present_all_three":
    let dir = createTempDir("m25-pref-full-", "")
    defer: removeDir(dir)
    let p = writeAndParse(dir, "home.nim",
      ProfileWithFullAdapterPreference)
    check p.adapterPreference.len == 3
    check "windows" in p.adapterPreference
    check "linux" in p.adapterPreference
    check "darwin" in p.adapterPreference
    # Chain order preserved verbatim — the parser does NOT canonicalize.
    check p.adapterPreference["windows"] == @["scoop", "builtin", "path"]
    check p.adapterPreference["linux"]   == @["nix", "builtin", "path"]
    check p.adapterPreference["darwin"]  == @["nix", "path"]

  test "test_m25_adapter_preference_parse_partial_windows_only":
    let dir = createTempDir("m25-pref-partial-", "")
    defer: removeDir(dir)
    let p = writeAndParse(dir, "home.nim",
      ProfileWithPartialAdapterPreference)
    check p.adapterPreference.len == 1
    check "windows" in p.adapterPreference
    check "linux"  notin p.adapterPreference
    check "darwin" notin p.adapterPreference
    check p.adapterPreference["windows"] == @["scoop", "builtin", "path"]

  test "test_m25_adapter_preference_parse_macos_alias_canonicalized":
    let dir = createTempDir("m25-pref-macos-", "")
    defer: removeDir(dir)
    let p = writeAndParse(dir, "home.nim",
      ProfileWithMacosAlias)
    # `macos` aliases to `darwin` at parse time so resolve-time
    # lookups use a single canonical key.
    check p.adapterPreference.len == 1
    check "darwin" in p.adapterPreference
    check "macos" notin p.adapterPreference
    check p.adapterPreference["darwin"] == @["nix", "path"]

  test "test_m25_adapter_preference_parse_empty_chain_accepted":
    # The parser accepts `windows: []` as a present-but-empty chain.
    # The resolve-time path (`resolveAdapterChainFor`) treats an empty
    # seq the same as a missing key: fall back to the M65 platform
    # default. The AST still records the key so a future "why is this
    # the default chain?" introspection can distinguish "operator
    # wrote an empty list" from "operator wrote no entry".
    let dir = createTempDir("m25-pref-empty-", "")
    defer: removeDir(dir)
    let p = writeAndParse(dir, "home.nim",
      ProfileWithEmptyChain)
    check p.adapterPreference.len == 1
    check "windows" in p.adapterPreference
    check p.adapterPreference["windows"].len == 0

  test "test_m25_adapter_preference_parse_unknown_os_key_fails_closed":
    let dir = createTempDir("m25-pref-bad-os-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), ProfileWithUnknownOs)
    var caught = false
    try:
      discard loadProfile(path)
    except EUnstructured as e:
      caught = true
      check "freebsd" in e.seen
      # The diagnostic must enumerate the closed set so the operator
      # can spot a typo without reading the spec.
      check "windows" in e.expected
      check "linux" in e.expected
      check "darwin" in e.expected
    check caught

  test "test_m25_adapter_preference_parse_unknown_adapter_fails_closed":
    let dir = createTempDir("m25-pref-bad-adapter-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), ProfileWithUnknownAdapter)
    var caught = false
    try:
      discard loadProfile(path)
    except EUnstructured as e:
      caught = true
      check "nonsense" in e.seen
      # The diagnostic must enumerate the closed adapter set so the
      # operator can spot a typo.
      check "builtin" in e.expected
      check "scoop" in e.expected
      check "nix" in e.expected
      check "path" in e.expected
    check caught

  test "test_m25_adapter_preference_parse_duplicate_os_fails_closed":
    let dir = createTempDir("m25-pref-dup-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), ProfileWithDuplicateOs)
    var caught = false
    try:
      discard loadProfile(path)
    except EUnstructured as e:
      caught = true
      check "second" in e.seen or "windows" in e.seen
    check caught
