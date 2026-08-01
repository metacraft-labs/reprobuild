## L3 PUBLISH-SCOPE provider-mode fixture.
##
## A hand-authored ``build:`` block that produces a package's declared
## ``executable`` member (its PUBLIC INTERFACE) via the ``nim.c`` alias.
## The recipe is compiled with ``--define:reproProviderMode`` by
## ``t_l3_build_block_public_interface_tagged_in_provider_mode.nim`` and
## consumed as a NON-main import so ``runPackageProvider`` does not seize
## the process; the test drives ``buildPackageFragment`` directly.
##
## The point under test: under ``reproProviderMode`` the per-artifact
## ``build:`` body-splice is gated off and ``buildL3pubPackage`` (the
## flattened executor) is the sole path that runs. The L3 fix restores
## the M4 per-artifact context frame around each artifact's flattened
## body (``collectBuildStatements`` → ``wrapArtifactBuildBody``) so
## ``nim.c``'s ``maybeTagPublicInterface`` attributes the edge to the
## owning ``(package, member)`` and tags the DECLARED executable member.

import std/options
import repro_project_dsl

package l3pub:
  uses:
    "nim >=2.2 <3.0"

  # A DECLARED public-interface executable whose materialising edge is a
  # hand-authored ``nim.c`` call. This edge MUST be tagged for
  # binary-cache publication in provider mode.
  executable publicTool:
    build:
      discard nim.c(source = "src/publicTool.nim", binary = "publicTool")

  # A DECLARED public-interface executable that opts OUT via
  # ``publish = false``. Even though it is a declared member its edge
  # must stay UNTAGGED — proves the explicit override is honoured on the
  # provider path.
  executable optedOutTool:
    build:
      discard nim.c(source = "src/optedOutTool.nim", binary = "optedOutTool",
                    publish = some(false))

  # A package-level ``build:`` edge (NOT nested inside a declared
  # ``executable``/``library``). It has no owning public-interface
  # member, so it must stay UNTAGGED.
  build:
    discard nim.c(source = "src/helper.nim", binary = "internalHelper")
