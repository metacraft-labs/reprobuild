import repro_core/types
import repro_core/paths
import repro_core/process_specs
import repro_core/dependency_gathering
import repro_core/entropy_blessings
import repro_core/edge_determinism
import repro_core/parallel
import repro_core/codec
import repro_core/dep_graph
import repro_core/project_file
import repro_core/nim_dep_scanner
import repro_core/cpp_dep_scanner
import repro_core/rust_dep_scanner
import repro_core/go_dep_scanner
import repro_core/python_dep_scanner
import repro_core/jsts_dep_scanner
import repro_core/convention_attribution
import repro_core/injected_libraries

export types
export paths
export process_specs
export dependency_gathering
export entropy_blessings
export edge_determinism
export parallel
export codec
export dep_graph
export project_file
export nim_dep_scanner
export cpp_dep_scanner
export rust_dep_scanner
export go_dep_scanner
export python_dep_scanner
export jsts_dep_scanner
export convention_attribution
export injected_libraries

const ReprobuildVersion* {.strdefine.} = "0.2.18"
  ## The release version this image reports through ``repro --version``.
  ##
  ## M5 SELF-HOST: a ``{.strdefine.}`` rather than a bare literal so ONE
  ## source tree can produce the several reprobuild images a multi-version
  ## store holds (``nim c -d:ReprobuildVersion=0.1.4 …``). The default is the
  ## release literal, so an ordinary build -- and ``tests/unit/t_version.nim``,
  ## which cross-checks it against ``reprobuild.nimble`` -- is unchanged.
  ## The version is what a project PINS (``uses: "reprobuild >=X"`` -> the
  ## committed ``repro.lock``), so it has to be settable by the build that
  ## produces the artifact being pinned rather than only by editing a file.

proc versionString*(): string =
  ReprobuildVersion

when defined(reproGeneratedSourceRevision):
  # The graph route. The ``reprobuild.apps.source-revision`` edge in
  # ``repro.nim`` writes this module (``scripts/source_revision.sh
  # --nim-module``) and the engine edge puts its directory on ``--path``.
  # Importing it, rather than passing the value as ``-d:``, is what makes the
  # revision a monitored INPUT of the compile: the content of the file keys
  # the engine edge, so a new commit rebuilds the engine and an unchanged one
  # leaves it a cache hit. (``staticRead`` cannot take its place: it resolves
  # a relative path against this module's directory, not the build's cwd.)
  import reprobuild_source_revision
  const generatedSourceRevision = reprobuildGeneratedSourceRevision
else:
  const generatedSourceRevision = ""

const ReprobuildSourceRevision* {.strdefine.} = generatedSourceRevision
  ## The source revision (a git commit id, with a ``-dirty`` suffix when the
  ## tree carried uncommitted changes to tracked files) this image was built
  ## from, or ``""`` when the build did not say.
  ##
  ## ``ReprobuildVersion`` does not identify a build: two images reporting the
  ## same version can be hundreds of commits apart. Tools that record what
  ## produced an artifact (``repro home export``'s provenance) therefore carry
  ## the revision as well. It is injected at build time, never discovered at
  ## run time, and ``scripts/source_revision.sh`` is the one derivation of it
  ## (``$REPROBUILD_SOURCE_REVISION`` when set, else ``git rev-parse HEAD`` of
  ## the tree, else unknown). Two routes carry the answer in:
  ##
  ## * ``scripts/build_apps.sh`` (``just build``, the Nix package) passes
  ##   ``-d:ReprobuildSourceRevision=…``, which wins over the default below;
  ## * the ``repro.nim`` engine edge defines ``reproGeneratedSourceRevision``
  ##   and compiles in the module its probe edge generated (above).
  ##
  ## The Nix package and the release workflow set the variable (the former's
  ## sandbox has no ``.git``); on the graph route the probe reads it when the
  ## probe ACTION runs, not when the recipe is evaluated.

proc sourceRevisionString*(): string =
  ## ``ReprobuildSourceRevision``; ``""`` means unknown.
  ReprobuildSourceRevision
