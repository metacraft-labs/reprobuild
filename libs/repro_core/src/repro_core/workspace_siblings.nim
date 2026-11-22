## repro_core/workspace_siblings.nim
##
## WHERE IS THE WORKSPACE SIBLING NAMED ``<name>``? -- the one answer every
## part of reprobuild gives when a recipe names another project of its
## workspace by its bare name:
##
##   * a recipe's declared packages (the nested ``uses: "<name>"`` form), whose
##     root and ``src`` go on every compile of the recipe
##     (``declaredPackageRoots`` in ``repro_interface_artifacts``, and the
##     ``internal resolve-package`` verb a recipe's macro expansion calls);
##   * the workspace-producer import, which imports a sibling project's
##     ``repro.nim`` for a ``uses:`` selector at macro expansion
##     (``workspaceProducerLocation`` in the project DSL);
##   * the command line's ``<pkg>:<target>`` selector (``findSiblingProjectFile``
##     in ``repro_cli_support``).
##
## Each of them used to walk the directories with its own loop, and the loops
## had drifted: the package resolver probed only the direct sibling
## ``../<name>``, while the other two walked up the ancestors. A recipe deep in
## its repository (``reproos/repro/workflows.nim``) then had its producer
## imported from the workspace root while the package declaration of the same
## name put nothing on its compile path. They now all call
## ``nearestWorkspaceSibling``.
##
## The rule: starting at the directory that holds the naming file, probe
## ``<ancestor>/<name>`` for each PROPER ancestor, nearest first, at most
## ``MaxWorkspaceSiblingDepth`` levels; the first that is a directory is the
## sibling. The first probe is the direct-sibling convention
## (``../<name>`` beside the repository); walking further up finds a project
## checked out at the workspace root from a file several directories below
## it. A closer directory of that name always shadows a farther one, and a
## directory that is found is the answer even when it holds no project file:
## one name resolves to one directory for every caller, and a caller that
## needs a ``repro.nim`` there reports its absence rather than walking past
## it to a different checkout.
##
## PURE: directory-existence checks and nothing else. No daemon, no lock, no
## process. It runs inside the compiler's VM during a recipe's macro
## expansion as well as in the engine, so it must stay callable from both.

import std/os
from ./paths import extendedPath

const MaxWorkspaceSiblingDepth* = 16
  ## How many ancestors the walk probes. Bounds the walk on a pathological
  ## path; a real workspace is a handful of levels deep.

type WorkspaceSibling* = tuple
  ## A resolved sibling: ``dir`` is the sibling's directory and
  ## ``workspaceRoot`` the ancestor it was found under (the directory that
  ## holds the naming project and the sibling side by side). Both are empty
  ## when nothing resolved.
  workspaceRoot, dir: string

proc isWorkspaceSiblingName*(name: string): bool =
  ## Whether ``name`` can name a sibling at all: non-empty, one path component
  ## (no ``/``, ``\`` or ``:``), and not ``.`` or ``..``. A name that fails
  ## this never reaches the file system.
  if name.len == 0 or name == "." or name == "..":
    return false
  for ch in name:
    if ch == '/' or ch == '\\' or ch == ':':
      return false
  true

proc siblingDirExists(path: string): bool =
  when nimvm:
    dirExists(path)
  else:
    dirExists(extendedPath(path))

proc nearestWorkspaceSibling*(anchorDir, name: string): WorkspaceSibling =
  ## The sibling ``name`` of the project whose naming file sits in
  ## ``anchorDir``, by the rule in the module documentation. ``anchorDir`` is
  ## used as given (pass an absolute directory: a relative one is walked only
  ## as far as its own components reach). Empty when ``name`` is not a
  ## sibling name or no ancestor holds a directory of that name.
  if anchorDir.len == 0 or not isWorkspaceSiblingName(name):
    return
  var dir = anchorDir
  for _ in 0 ..< MaxWorkspaceSiblingDepth:
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      return
    let candidate = parent / name
    if siblingDirExists(candidate):
      return (workspaceRoot: parent, dir: candidate)
    dir = parent
