## Source-only package resolution: the probe that decides whether a checkout
## can satisfy the import a recipe is about to compile.
##
## ## What a "source-only package" is here
##
## A handful of Nim packages reach reprobuild's compiles as a `--path:` into a
## checkout rather than as a producer edge: third-party trees that exist only
## as a flake input materialized into the store (`nimcrypto`, `nim-bearssl`),
## and workspace repositories that do not yet declare a `library` the `uses:`
## block could bind to. Each is named by an environment variable the dev shell
## exports, with a short list of on-disk candidates behind it.
##
## ## The probe is a MARKER, and the marker is the module the build imports
##
## A resolver decides "is this directory the package?" by testing for one file
## inside it. Which file that is, is the whole correctness of the mechanism:
##
## * A marker at the package ROOT is satisfied by every revision ever
##   published, including revisions that predate the module tree the consumer
##   imports. Such a probe ACCEPTS a checkout that cannot satisfy the import,
##   and the build then dies several layers down on `cannot open file:
##   <module>` — a message naming the module rather than the wrong checkout
##   that lacks it.
## * A marker at the MODULE the consumer imports rejects exactly what the
##   compiler would reject, at the point where the directory is still in hand
##   and can be named.
##
## `nim-bearssl` is the worked example and the reason this module exists.
## `libs/repro_deploy_agent` imports `bearssl/abi/consttypes`; `bearssl.nim`
## sits at the root of EVERY revision of the package. `BearsslModuleMarker`
## below is therefore the module, not the root file, and
## `scripts/source_paths.sh` — the resolver the shell build path uses — spells
## the same string for the same reason. The two must agree, because they
## resolve the same dependency for the same build;
## `tests/unit/t_bearssl_probe_marker_is_the_imported_module.nim` is what
## holds them together.
##
## ## An explicitly named checkout is used or refused, never substituted
##
## When `$<ENV>` is set and the directory it names does not carry the marker,
## this resolver RAISES. It does not fall through to the next candidate.
## Quietly substituting a different checkout for the one the caller named is
## how a wrong checkout comes to be used in the first place: it hides a stale
## pin in whatever set the variable, and the operator never learns their value
## was ignored.
##
## ## There is no /nix/store scan, deliberately
##
## An earlier form of this resolver ended with a last-resort scan of
## `/nix/store` for a directory whose name contained `nim-bearssl-`. It is
## removed, and not as a trade-off against "a non-dev-shell build can then
## find nothing":
##
## * It cannot find the PINNED tree. reprobuild's flake declares nim-bearssl
##   as a non-flake `git+https` input, so the revision the lock names
##   materializes as `/nix/store/<hash>-source`. No store path produced by
##   this repository's own pin carries `nim-bearssl-` in its name, so the
##   fragment cannot match it.
## * Every path the scan CAN return therefore belongs to some other
##   derivation's pin, at whatever revision that derivation happens to want,
##   selected by directory iteration order. On this fleet that is a real tree
##   at a real revision — and the revision predates the module tree, so the
##   scan's answer was precisely the one the compiler rejects.
##
## The authoritative non-dev-shell route is the one above it: the flake
## devShell attribute, read with `nix eval`, which yields the pin. A host with
## no `nix` has no `/nix/store` to scan either, so nothing is lost.

import std/[os, strutils]

import repro_core/ambient_execution

const BearsslModuleMarker* = "bearssl/abi/consttypes.nim"
  ## The module `libs/repro_deploy_agent/src/repro_deploy_agent/secrets.nim`
  ## imports (`bearssl/abi/consttypes`), and therefore the only file whose
  ## presence proves a nim-bearssl checkout can satisfy this repository's
  ## import of it. Spelled with forward slashes so the one string can be
  ## compared byte-for-byte against the shell resolvers that declare it;
  ## `fileExists` accepts that spelling on every platform reprobuild targets.

proc nixDevShellSourcePath*(envName, marker: string): string =
  ## The value this repository's flake devShell exports for ``envName``, when
  ## the directory it names carries ``marker``. Empty when there is no flake
  ## here, no usable ``nix``, or the exported tree fails the marker.
  ##
  ## This is the AUTHORITATIVE fallback: the attribute's value comes from the
  ## flake's locked input, so it is the revision the lock names rather than
  ## whatever a store scan would turn up.
  when defined(windows):
    ""
  else:
    if not fileExists("flake.nix"):
      return ""
    let systemResult = uncontrolledExecCmdEx(
      "nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null")
    if systemResult.exitCode != 0:
      return ""
    let system = systemResult.output.strip()
    if system.len == 0:
      return ""
    let valueResult = uncontrolledExecCmdEx(
      "nix eval --raw '.#devShells." & system & ".default." & envName &
      "' 2>/dev/null")
    if valueResult.exitCode != 0:
      return ""
    let candidate = valueResult.output.strip()
    if candidate.len > 0 and fileExists(candidate / marker):
      return candidate
    ""

proc sourceOnlyPackagePath*(envName: string; candidates: openArray[string];
                            marker: string; remedy = ""):
    tuple[path: string; env: seq[(string, string)]] =
  ## Resolve the source-only package provisioned through ``$envName`` to a
  ## directory that carries ``marker``, together with the environment entry a
  ## consuming action must inherit so the compile sees the same tree.
  ##
  ## Resolution order: ``$envName``, then ``candidates`` in declaration order,
  ## then the flake devShell attribute.
  ##
  ## AN UNRESOLVED INPUT IS FATAL, NOT DROPPED. This helper used to return
  ## ``("", @[])`` and callers used to skip it with ``if pkg.path.len > 0``, so
  ## a dependency that resolved nowhere produced no message at all — the build
  ## simply went on without it and failed later somewhere that named a Nim
  ## module instead of the missing checkout.
  let fromEnv = getEnv(envName)
  if fromEnv.len > 0:
    if fileExists(fromEnv / marker):
      return (fromEnv, @[(envName, fromEnv)])
    # Named, and wrong. See the module header: this is an error rather than a
    # reason to look elsewhere.
    raise newException(OSError,
      "$" & envName & "=" & fromEnv & " does not carry `" & marker &
      "`, so it cannot satisfy the import this repository compiles against " &
      "— that checkout predates the module tree reprobuild needs. This is " &
      "refused rather than silently replaced by another candidate: " &
      "substituting a different checkout for the one you named would hide " &
      "the stale pin in whatever set $" & envName & ". Remedy: unset $" &
      envName & " to use the dev shell's pinned input, or point it at a " &
      "checkout that carries `" & marker & "`.")
  for candidate in candidates:
    if fileExists(candidate / marker):
      return (candidate, @[(envName, candidate)])
  let fromFlake = nixDevShellSourcePath(envName, marker)
  if fromFlake.len > 0:
    return (fromFlake, @[(envName, fromFlake)])
  # Every probe missed. Say which probes, with what they were looking for and
  # how to satisfy them, instead of returning an empty path the caller cannot
  # distinguish from "this input is not needed here".
  var tried: seq[string] = @["$" & envName & " (unset)"]
  for candidate in candidates:
    tried.add(candidate)
  tried.add("the flake devShell attribute `." & "#devShells.<system>." &
    "default." & envName & "`")
  raise newException(OSError,
    "reprobuild's recipe could not resolve the source-only dependency " &
    "provisioned through $" & envName & ". Every candidate was probed " &
    "for `" & marker & "` and none carried it: " & tried.join("; ") &
    ". This dependency is an input of every Nim compile this recipe " &
    "declares, so it cannot be skipped: dropping it here is what makes " &
    "the failure surface later as `cannot open file: <some module>` in " &
    "a place that does not name the missing checkout. Remedy: " &
    (if remedy.len > 0: remedy
     else: "enter this repository's dev shell (`nix develop`, or " &
       "`scripts/dev-shell.sh`), which exports $" & envName &
       " from the flake's pinned input; or set $" & envName &
       " to a checkout that carries `" & marker & "`."))

proc workspaceRelativeSourcePath*(path, projectRoot: string): string =
  ## The spelling of a resolved source root that a compile's COMMAND LINE and
  ## DECLARED ENVIRONMENT should carry: relative to ``projectRoot`` when the
  ## directory is a workspace sibling, ``path`` unchanged otherwise.
  ##
  ## ## Why the spelling matters
  ##
  ## Every ``--path:`` element and every declared environment value is part of
  ## an action's weak fingerprint (Incremental-Invalidation.md §"Step 1"). A
  ## source root that is ALSO an input of every compile therefore decides,
  ## by its NAME alone, whether every compile in the graph can be served from
  ## the cache. Spelled ``/nix/store/<hash>-source/src`` — the content-hashed
  ## store path of the flake input — it changed on every sibling commit and
  ## every pin bump, and each such change made every one of the ~1,866
  ## ``.#test-builds`` compiles miss, including the ones that never import
  ## the sibling. Spelled ``../io-mon/src`` it is the same string at every
  ## revision of that sibling, and what invalidates a compile is what the
  ## compile actually READ from it: the strong fingerprint's observed path
  ## set (§"Step 3").
  ##
  ## Relative rather than absolute so that two worktrees laid out the same
  ## way — each beside its own siblings — compute the same weak key.
  ##
  ## ## What is left alone
  ##
  ## * A relative ``path``: it already is the spelling (the recipe's own
  ##   ``../<sibling>`` candidates).
  ## * A path outside ``projectRoot``'s parent directory: a store path is
  ##   already stable per pin (and is what a checkout with no siblings — CI —
  ##   compiles), and an explicit checkout elsewhere is left as its owner
  ##   named it.
  ## * Anything when the parent directory is the filesystem root, where
  ##   "inside the workspace" would mean "anywhere".
  ##
  ## The consumer resolves the relative spelling against the action's working
  ## directory, which is ``projectRoot`` for every edge this applies to: Nim
  ## resolves a command-line ``--path:`` against its current directory, and
  ## ``config.nims`` resolves the declared value both for ``fileExists`` (the
  ## process directory) and for ``switch("path", …)`` (the directory of
  ## ``config.nims``, which is ``projectRoot``).
  if path.len == 0 or projectRoot.len == 0 or not path.isAbsolute or
      not projectRoot.isAbsolute:
    return path
  let root = normalizedPath(projectRoot)
  let workspace = root.parentDir
  if workspace.len == 0 or workspace == root or
      workspace.parentDir.len == 0 or workspace.parentDir == workspace:
    return path
  let target = normalizedPath(path)
  if not target.isRelativeTo(workspace):
    return path
  relativePath(target, root, sep = '/')
