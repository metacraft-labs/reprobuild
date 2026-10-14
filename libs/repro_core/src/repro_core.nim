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

const ReprobuildVersion* {.strdefine.} = "0.2.5"
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

const ReprobuildSourceRevision* {.strdefine.} = ""
  ## The source revision (a git commit id, with a ``-dirty`` suffix when the
  ## tree carried uncommitted changes to tracked files) this image was built
  ## from, or ``""`` when the build did not say.
  ##
  ## ``ReprobuildVersion`` does not identify a build: two images reporting the
  ## same version can be hundreds of commits apart. Tools that record what
  ## produced an artifact (``repro home export``'s provenance) therefore carry
  ## the revision as well. It is injected at build time, never discovered at
  ## run time: ``scripts/build_apps.sh`` passes
  ## ``-d:ReprobuildSourceRevision=…`` from ``$REPROBUILD_SOURCE_REVISION`` or,
  ## failing that, from ``git rev-parse HEAD`` of the tree it builds; the Nix
  ## package sets the variable from the flake's revision, and the
  ## ``repro.nim`` app edges read the same variable.

proc sourceRevisionString*(): string =
  ## ``ReprobuildSourceRevision``; ``""`` means unknown.
  ReprobuildSourceRevision
