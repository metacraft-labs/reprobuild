## DSL-port M9.N Batch C.1 acceptance — ``shell()`` action surface for
## ``build:`` blocks.
##
## Pins the registry round-trip for the ``shell()`` runtime proc:
##
##   * recording a shell command auto-fills ``packageName`` and
##     ``artifactName`` from the active build context;
##   * sequential calls within the same artifact get monotonic
##     auto-generated ids ``<pkg>-<artifact>-<seq>``;
##   * the registry returns rows in declaration order (cross-artifact
##     order is preserved on a per-package basis);
##   * ``cwd`` defaults to empty (the convention resolves to
##     ``<projectRoot>/src/`` at emit time);
##   * an explicit ``id`` is recorded verbatim;
##   * the package-level ``build:`` form uses ``"package"`` as the
##     artifact-name token in synthesised ids.
##
## The registry consumer (``from-source-custom`` convention) lives in
## ``libs/repro_standard_provider/src/repro_standard_provider/conventions/
## from_source_custom.nim`` and has its own gate test next to the other
## convention tests.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — pulls ``Executable`` into scope for the typed
# slot vars the ``package`` macro injects for the executable artifacts
# below.
import repro_dsl_stdlib/types

# Recipe-side declaration: one package with TWO executables, each
# carrying a small ``build:`` block that records shell actions. The
# module-init sequence runs every block once and populates the registry
# before the test cases below open.
package shellActionPkg:
  nativeBuildDeps:
    "gcc >=11"
    "pkg-config"
    "gcc >=12"
  buildDeps:
    "zlib"
    "pkg-config"

  executable firstTool:
    build:
      shell "tar -xf $fetch -C $extracted"
      shell "cp -r $extracted/lib $out/"
  executable secondTool:
    build:
      shell "python3 configure.py --bootstrap", id = "secondTool-bootstrap"
      shell "install -Dm755 ninja $out/bin/ninja"
  build:
    shell "echo package-level-action"

suite "DSL-port M9.N Batch C.1 — shell() action registry":

  test "registry returns the full declaration-order sequence":
    let rows = registeredShellActions("shellActionPkg")
    # 5 calls total: 1 package-level + 2 for firstTool + 2 for secondTool.
    # The ``package`` macro emits the package-level ``build:`` block
    # FIRST (via ``emitM4BuildActions``), then artifact-scoped blocks
    # (via ``emitM4ArtifactBuildLowering``), so the registry order is
    # ``[package-level, firstTool x 2, secondTool x 2]``.
    check rows.len == 5

  test "shell() auto-fills packageName and artifactName from context":
    let rows = registeredShellActions("shellActionPkg")
    # Package-level ``build:`` block runs first — artifactName is empty.
    check rows[0].packageName == "shellActionPkg"
    check rows[0].artifactName == ""
    # firstTool's artifact-scoped block — both rows.
    check rows[1].packageName == "shellActionPkg"
    check rows[1].artifactName == "firstTool"
    check rows[2].packageName == "shellActionPkg"
    check rows[2].artifactName == "firstTool"
    # secondTool's artifact-scoped block — both rows.
    check rows[3].packageName == "shellActionPkg"
    check rows[3].artifactName == "secondTool"
    check rows[4].packageName == "shellActionPkg"
    check rows[4].artifactName == "secondTool"

  test "shell() records the command verbatim":
    let rows = registeredShellActions("shellActionPkg")
    check rows[0].command == "echo package-level-action"
    check rows[1].command == "tar -xf $fetch -C $extracted"
    check rows[2].command == "cp -r $extracted/lib $out/"
    check rows[3].command == "python3 configure.py --bootstrap"
    check rows[4].command == "install -Dm755 ninja $out/bin/ninja"

  test "auto-generated ids carry a monotonic per-artifact sequence":
    let rows = registeredShellActions("shellActionPkg")
    # Package-level row uses ``"package"`` as the artifact token because
    # the active artifactName is empty.
    check rows[0].id == "shellActionPkg-package-1"
    # firstTool — two shell() calls, both omit ``id``, get seq 1 + 2.
    check rows[1].id == "shellActionPkg-firstTool-1"
    check rows[2].id == "shellActionPkg-firstTool-2"
    # secondTool — first call supplies an explicit id (verbatim), then
    # the next omitted-id call gets seq 1 (the explicit-id row does NOT
    # advance the counter for this artifact).
    check rows[3].id == "secondTool-bootstrap"
    check rows[4].id == "shellActionPkg-secondTool-1"

  test "cwd defaults to empty (resolved by convention at emit time)":
    let rows = registeredShellActions("shellActionPkg")
    for r in rows:
      check r.cwd == ""

  test "deps and outputs default to empty seqs":
    let rows = registeredShellActions("shellActionPkg")
    let emptyStrSeq: seq[string] = @[]
    for r in rows:
      check r.deps == emptyStrSeq
      check r.outputs == emptyStrSeq

  test "custom shell actions inherit unique declared dependency identities":
    # This used to pin the whole seq to ``@["sh", "gcc", "pkg-config",
    # "zlib"]``. That pin is no longer expressible as one literal, for
    # two independent reasons, and neither is a regression:
    #
    #   * ``dslPortCustomShellToolIdentityRefs`` seeds the interpreter
    #     identity plus the core utilities every generated shell action
    #     runs, and it reads ``registeredNativeBuildDeps``, which is
    #     documented (dsl_port_runtime.nim) as "the COMPLETE build-time
    #     tool set: the recipe's own ``nativeBuildDeps:`` entries plus
    #     whatever reprobuild's fetch and install-mirror emitters need in
    #     order to run their generated scripts". Those emitters declare
    #     their commands on purpose — install_mirror_resolver.nim: "Keep
    #     these explicit so sealed action profiles never depend on
    #     ambient PATH".
    #   * That generated set is platform-conditional
    #     (``typedInstallMirrorShellTools`` adds eleven more names under
    #     ``when defined(linux)``), so any exact literal here would be
    #     green on one host and red on another — the failure mode that
    #     got the M2 env migration test retired.
    #
    # So this case pins what its NAME claims and what no other case
    # covers: identities are inherited from both dep blocks, deduped,
    # and stripped of their version constraints. The recipe above
    # declares ``gcc`` twice (different constraints) and ``pkg-config``
    # in both blocks precisely so those two collapses are observable.
    let refs = dslPortCustomShellToolIdentityRefs("shellActionPkg")

    # The shell stays the command interpreter identity.
    check refs.len > 0
    check refs[0] == "sh"

    # Every declared dependency is inherited, by bare name.
    for dep in ["gcc", "pkg-config", "zlib"]:
      check dep in refs

    # Constraints never survive into an identity ref.
    for r in refs:
      check ' ' notin r
      check '>' notin r
      check '<' notin r
      check '=' notin r

    # Unique: ``gcc`` (declared twice) and ``pkg-config`` (declared in
    # both blocks) each appear once, and so does everything else.
    var seen: seq[string] = @[]
    for r in refs:
      check r notin seen
      seen.add(r)

  test "registry is empty for packages that never called shell()":
    let rows = registeredShellActions("noSuchPackage")
    check rows.len == 0
