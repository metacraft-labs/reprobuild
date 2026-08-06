## DSL regression — an artifact may share its name with one of the
## package's own tool dependencies (the self-hosting-tool shape).
##
## ``recipes/packages/source/make/repro.nim`` declares
## ``package makeSource:`` with ``executable make:`` AND
## ``nativeBuildDeps: "make >=4"`` — GNU make's ``./configure && make
## && make install`` cycle needs a pre-existing ``make`` to drive it,
## so the self-dep is deliberate (and the same shape recurs for every
## self-hosting build tool: ninja built by ninja, cmake by cmake, a
## compiler by itself).
##
## That combination used to fail to COMPILE with::
##
##   Error: redefinition of 'make'; previous declaration here: (3, 32)
##
## Two emissions of the ``package`` macro both landed the identifier
## ``make`` in the recipe's module scope:
##
##   1. ``usesImportCode`` (``macros_a.nim``) emits a dependency-only
##      import for each bundled-stdlib selector in ``nativeBuildDeps:``
##      / ``runtimeDeps:``. The bare form ``from
##      repro_dsl_stdlib/packages/make import <marker>`` still binds the
##      MODULE symbol ``make`` into the importing scope — Nim keeps the
##      module name available as a qualifier even for selective ``from``
##      imports. (The bogus ``(3, 32)`` in the old error is that
##      statement's position inside the macro's ``parseStmt`` string, not
##      a position in the recipe.)
##   2. ``emitM9R2cArtifactSlots`` (``macros_b.nim``) emits the typed
##      artifact slot ``var make {.inject, used.}: Executable`` for
##      ``executable make:``.
##
## The fix aliases the dependency-only import (``... as
## make_dep_module``) so the module binding never occupies the artifact
## namespace. This test pins BOTH halves of the contract: the recipe
## shape compiles, the artifact slot is what the bare name resolves to,
## AND the dependency module still gets initialised (its package
## definition reaches the registry) — so the collision cannot be
## "fixed" by simply dropping the import.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

# The exact upstream shape: artifact ``make`` + self-dep ``make``.
package makeSelfHostPkg:
  nativeBuildDeps:
    "gcc >=11"
    "make >=4"
  executable make:
    discard

# A second bundled-stdlib selector, to show the fix is not specific to
# the ``make`` module in particular.
package ninjaSelfHostPkg:
  nativeBuildDeps:
    "ninja >=1.11"
  executable ninja:
    discard

suite "DSL — artifact name may equal a tool-dependency name":

  test "self-named artifact registers under the declaring package":
    let arts = registeredArtifacts("makeSelfHostPkg")
    check arts.len == 1
    check arts[0].artifactName == "make"
    check arts[0].kind == dakExecutable
    check arts[0].packageName == "makeSelfHostPkg"

  test "the self-dep survives in the native-build-dep registry":
    # The dep must NOT be silently dropped to dodge the collision.
    check registeredNativeBuildDeps("makeSelfHostPkg") ==
      @["gcc >=11", "make >=4"]

  test "the bare name resolves to the injected artifact slot":
    # If the dependency-only import still bound the module symbol
    # ``make`` this module would not compile at all; if the artifact
    # slot injection had been suppressed instead, these field accesses
    # would fail to resolve. Both emissions must coexist.
    check make.cli.executableName == ""
    check make.installPrefix == ""

  test "the dependency module is still initialised despite the alias":
    # ``from <stdlib>/make as make_dep_module import <marker>`` runs the
    # stdlib module's init, which registers ``package make:``. Assert the
    # registration landed so the aliasing cannot regress into "just drop
    # the import".
    var sawMake = false
    var sawNinja = false
    for pkg in registeredPackages():
      if pkg.packageName == "make": sawMake = true
      elif pkg.packageName == "ninja": sawNinja = true
    check sawMake
    check sawNinja

  test "the shape generalises to a second bundled selector":
    let arts = registeredArtifacts("ninjaSelfHostPkg")
    check arts.len == 1
    check arts[0].artifactName == "ninja"
    check registeredNativeBuildDeps("ninjaSelfHostPkg") == @["ninja >=1.11"]
    check ninja.installPrefix == ""
