## `versions:` entry values take an EXPRESSION, not only a string literal.
##
## The body loop skipped any assignment whose right-hand side was not
## `nnkStrLit` / `nnkRStrLit` / `nnkTripleStrLit`, so
##
##     sourceRevision = AptJammyAdapterVersion
##
## compiled, emitted nothing, and registered an EMPTY revision. Silent, and
## indistinguishable afterwards from a version entry that simply omitted the
## field.
##
## This is the largest instance of the pattern in the tree: `versions:` appears
## in 404 files carrying ~865 assignments. It is also the one with visible
## scar tissue — recipes carry comments of the form "keep the version string in
## sync with `<Const>` in the stdlib module" (see
## `recipes/packages/adapters/apt-jammy/repro.nim`). The const already existed;
## the DSL could not accept it, so the value was pasted and a human was asked
## to keep the two aligned. That comment is a workaround for this defect.
##
## The values are now spliced verbatim into the emitted `registerVersion(...)`
## call and evaluated by the compiler.

import std/[unittest]

import repro_project_dsl

# The shape the recipes' sync comments are asking for: declare the identity
# once, reference it from the entry.
const
  AdapterVersion = "23.13.9"
  UpstreamHost = "https://www.freedesktop.org/software/accountsservice"

func tarballUrl(host, name, version: string): string =
  host & "/" & name & "-" & version & ".tar.xz"

package versionExprPkg:
  versions:
    "23.13.9":
      sourceRevision = AdapterVersion
      sourceUrl = tarballUrl(UpstreamHost, "accountsservice", AdapterVersion)
      sourceRepository =
        "https://gitlab.freedesktop.org/accountsservice/accountsservice"

package versionMixedPkg:
  versions:
    "1.0.0":
      # a literal and an expression in the same body
      sourceRevision = "refs/tags/v1.0.0"
      sourceChecksum = "sha256-" & "cccc"
    "2.0.0":
      sourceRevision = AdapterVersion

suite "versions: entry values accept expressions":
  test "a const reaches sourceRevision":
    let vs = registeredVersions("versionExprPkg")
    check vs.len == 1
    check vs[0].sourceRevision == "23.13.9"

  test "a func call reaches sourceUrl":
    check registeredVersions("versionExprPkg")[0].sourceUrl ==
      "https://www.freedesktop.org/software/accountsservice/" &
      "accountsservice-23.13.9.tar.xz"

  test "a literal in the same entry is unaffected":
    check registeredVersions("versionExprPkg")[0].sourceRepository ==
      "https://gitlab.freedesktop.org/accountsservice/accountsservice"

  test "the version key itself still registers":
    check registeredVersions("versionExprPkg")[0].version == "23.13.9"

  test "literals and expressions mix within one entry":
    let vs = registeredVersions("versionMixedPkg")
    check vs.len == 2
    check vs[0].sourceRevision == "refs/tags/v1.0.0"
    check vs[0].sourceChecksum == "sha256-cccc"

  test "declaration order across entries is preserved":
    let vs = registeredVersions("versionMixedPkg")
    check vs[0].version == "1.0.0"
    check vs[1].version == "2.0.0"
    check vs[1].sourceRevision == "23.13.9"

  test "an omitted field is still the empty string":
    # The emitted default moved from a macro-time "" to the emitted source
    # `""`; it must still arrive as an empty string, not as unset garbage.
    check registeredVersions("versionMixedPkg")[1].sourceUrl == ""
    check registeredVersions("versionMixedPkg")[1].sourceChecksum == ""
