## DSL-port M9.R.3 — optional ``library <name>: api:`` block surface.
##
## Pins the typed consumer-facing metadata declared inside a library
## artifact's body via the new ``api:`` block:
##
##   * Scalar fields: ``pkgConfig`` / ``soname`` / ``sover`` /
##     ``linkKind`` / ``languageStandard``.
##   * CMake PUBLIC/PRIVATE listing pairs: ``headers:`` /
##     ``privateHeaders:`` / ``links:`` / ``privateLinks:`` /
##     ``defines:`` / ``privateDefines:`` / ``compileOptions:`` /
##     ``privateCompileOptions:``.
##
## Coverage:
##
##   1. A populated ``api:`` block round-trips every recognised field
##      through ``registeredLibraryApi``.
##   2. PUBLIC + PRIVATE keying populates separate slots (``headers``
##      vs ``privateHeaders``).
##   3. ``links:`` records bare identifiers as their stringified names.
##   4. ``library libFoo: discard`` does NOT raise; the accessor returns
##      ``declared == false`` for that ``(pkg, lib)`` pair.
##   5. All fields inside ``api:`` are individually optional — a recipe
##      with only ``pkgConfig`` leaves every other slot at its
##      default-zero / empty-seq value.
##   6. ``linkKind`` enum parsing round-trips for ``static`` / ``shared``
##      / ``both``.
##   7. Variant-conditional ``links:`` content lands the chosen branch
##      in the registry — the macro splices the variant-conditional
##      ``case`` expression verbatim so the resolved variant value at
##      registration time drives the recorded identifier.

import std/[unittest]

import repro_project_dsl

# ---------------------------------------------------------------------------
# Fixture 1 — every recognised field populated.
# ---------------------------------------------------------------------------

package m9r3FullApi:
  library libFoo:
    api:
      pkgConfig "libfoo"
      soname  "foo"
      sover   "2.0.0"
      linkKind shared
      languageStandard cxx_std_17

      headers:
        "include/foo.h"
        "include/foo/types.h"
      privateHeaders:
        "src/internal"

      links:
        libZlib
      privateLinks:
        libInternalHelper

      defines:
        "FOO_API_VERSION=2"
      privateDefines:
        "DEBUG_INTERNAL=1"

      compileOptions:
        "-fvisibility=hidden"
      privateCompileOptions:
        "-Werror"

# ---------------------------------------------------------------------------
# Fixture 2 — bare-body library (no ``api:`` block).
# ---------------------------------------------------------------------------

package m9r3BareLibrary:
  library libBare:
    discard

# ---------------------------------------------------------------------------
# Fixture 3 — only ``pkgConfig`` set; every other slot stays empty.
# ---------------------------------------------------------------------------

package m9r3PkgConfigOnly:
  library libPkgOnly:
    api:
      pkgConfig "libpkgonly"

# ---------------------------------------------------------------------------
# Fixture 4 — ``linkKind static``.
# ---------------------------------------------------------------------------

package m9r3LinkKindStatic:
  library libStaticOnly:
    api:
      linkKind static

# ---------------------------------------------------------------------------
# Fixture 5 — ``linkKind both``.
# ---------------------------------------------------------------------------

package m9r3LinkKindBoth:
  library libBothLib:
    api:
      linkKind both

# ---------------------------------------------------------------------------
# Fixture 6 — variant-conditional ``links:`` content.
#
# Declare a ``sslBackend`` variant with default ``"openssl"`` and use a
# ``case`` expression inside the ``links:`` body. The macro splices the
# control flow verbatim into the registration block so the resolved
# variant value drives which identifier reaches the registry. We do
# NOT override the variant here (no CLI parse) — the default arm
# (``openssl``) wins, so ``libOpenssl`` is the recorded link.
# ---------------------------------------------------------------------------

package m9r3VariantLinks:
  config:
    ## @variant
    sslBackend: string = "openssl"

  library libCryptoUser:
    api:
      links:
        case sslBackend.value:
        of "openssl": libOpenssl
        of "boringssl": libBoringssl
        else: libNone

suite "DSL-port M9.R.3 — optional library api: block":

  test "every api: field round-trips through registeredLibraryApi":
    let api = registeredLibraryApi("m9r3FullApi", "libFoo")
    check api.declared == true
    check api.pkgConfig == "libfoo"
    check api.soname == "foo"
    check api.sover == "2.0.0"
    check api.linkKind == llkShared
    check api.languageStandard == "cxx_std_17"
    check api.headers == @["include/foo.h", "include/foo/types.h"]
    check api.privateHeaders == @["src/internal"]
    check api.links == @["libZlib"]
    check api.privateLinks == @["libInternalHelper"]
    check api.defines == @["FOO_API_VERSION=2"]
    check api.privateDefines == @["DEBUG_INTERNAL=1"]
    check api.compileOptions == @["-fvisibility=hidden"]
    check api.privateCompileOptions == @["-Werror"]

  test "PUBLIC / PRIVATE keying lands in separate slots":
    # The same fixture pins the cross-bleed property — PUBLIC content
    # never leaks into the PRIVATE slot and vice versa.
    let api = registeredLibraryApi("m9r3FullApi", "libFoo")
    check api.headers.len == 2
    check api.privateHeaders.len == 1
    check api.headers != api.privateHeaders
    check api.links == @["libZlib"]
    check api.privateLinks == @["libInternalHelper"]
    check api.defines == @["FOO_API_VERSION=2"]
    check api.privateDefines == @["DEBUG_INTERNAL=1"]
    check api.compileOptions == @["-fvisibility=hidden"]
    check api.privateCompileOptions == @["-Werror"]

  test "links: registers bare identifiers as string names":
    # ``libZlib`` is a bare identifier in source — the registry stores
    # the stringified name; symbol resolution happens at consumer-side
    # later (deferred to M9.R.5 / M9.R.6).
    let api = registeredLibraryApi("m9r3FullApi", "libFoo")
    check api.links == @["libZlib"]
    check api.privateLinks == @["libInternalHelper"]

  test "library libFoo: discard does NOT register an api: row":
    # The accessor never raises on an unknown (pkg, lib) pair — it
    # returns the default-zero record with ``declared == false``. The
    # bare-body library is the canonical "no api: block" case.
    let api = registeredLibraryApi("m9r3BareLibrary", "libBare")
    check api.declared == false
    check api.pkgConfig.len == 0
    check api.headers.len == 0
    check api.links.len == 0
    check api.linkKind == llkUnset

  test "fields inside api: are individually optional":
    let api = registeredLibraryApi("m9r3PkgConfigOnly", "libPkgOnly")
    check api.declared == true
    check api.pkgConfig == "libpkgonly"
    # Every other field stays at its default-zero / empty-seq value.
    check api.soname.len == 0
    check api.sover.len == 0
    check api.linkKind == llkUnset
    check api.languageStandard.len == 0
    check api.headers.len == 0
    check api.privateHeaders.len == 0
    check api.links.len == 0
    check api.privateLinks.len == 0
    check api.defines.len == 0
    check api.privateDefines.len == 0
    check api.compileOptions.len == 0
    check api.privateCompileOptions.len == 0

  test "linkKind enum parses for static / shared / both":
    # ``shared`` is already pinned by the full-api fixture.
    check registeredLibraryApi("m9r3FullApi", "libFoo").linkKind == llkShared
    check registeredLibraryApi("m9r3LinkKindStatic",
                                "libStaticOnly").linkKind == llkStatic
    check registeredLibraryApi("m9r3LinkKindBoth",
                                "libBothLib").linkKind == llkBoth

  test "variant-conditional links: lands the resolved branch":
    # ``sslBackend`` defaults to ``"openssl"``; the ``case`` arm picks
    # the matching identifier (``libOpenssl``) so the registry stores
    # the stringified branch leaf.
    let api = registeredLibraryApi("m9r3VariantLinks", "libCryptoUser")
    check api.declared == true
    check api.links == @["libOpenssl"]
    # The non-default branches did NOT contribute.
    check "libBoringssl" notin api.links
    check "libNone" notin api.links

  test "unknown (pkg, lib) pairs return default-zero records":
    let api = registeredLibraryApi("m9r3DoesNotExist", "libNoSuchLib")
    check api.declared == false
    check api.pkgConfig.len == 0
    check api.linkKind == llkUnset
