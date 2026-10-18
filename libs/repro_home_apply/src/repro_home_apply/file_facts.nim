## The values a home file is compared on, and the planner rule that uses
## them for a stow file and an `fs.userFile` resource naming one path.
##
## Host facts (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
## §Host facts) compare a file on two fields, `mode` and `digest`. The same
## two fields decide whether a stow file and an `fs.userFile` resource that
## the planner would both write to one `$HOME` path describe the same file
## (Home-Profile-Intent-Layer.md §Stow-Style Dotfile Support, "A stow file and
## an `fs.userFile` on one path"):
##
## * they agree -- the resource writes the file and the stow file is not
##   materialized at that path, so the path has one writer;
## * they disagree -- the plan is refused before anything is written, naming
##   the path, both sources and every field that differs.
##
## The helpers live here rather than in `host_facts` because the planner
## (`pipeline`) needs them and `host_facts` is built on the planner.

import std/[os, sets, strutils, tables]
from repro_core/paths import extendedPath

import nimcrypto/sha2 as factsSha2

import repro_home_resources

import ./errors
import ./plan
import ./stow

proc sha256Digest*(content: openArray[byte]): string =
  ## `sha256:<lower-case hex>` of `content`.
  var ctx: factsSha2.sha256
  ctx.init()
  if content.len > 0:
    ctx.update(content)
  "sha256:" & ($ctx.finish()).toLowerAscii()

proc sha256Digest*(content: string): string =
  var bytes = newSeq[byte](content.len)
  for i, ch in content:
    bytes[i] = byte(ord(ch))
  sha256Digest(bytes)

proc homeRelativeId*(path, homeDir: string): string =
  ## `~/<rel>` for a path under `homeDir` (separators normalised to `/`),
  ## the path itself otherwise. Separators repeated after the home prefix
  ## are one: `getHomeDir()` ends in a separator and an `fs.userFile`
  ## `hostFile = "~/x"` is expanded by concatenation, so the planner holds
  ## `<home>//x` for the path a stow file names `<home>/x`.
  let p = path.replace('\\', '/')
  let h = homeDir.replace('\\', '/').strip(leading = false, chars = {'/'})
  if p == h:
    return "~"
  if h.len > 0 and p.startsWith(h & "/"):
    let rel = p[h.len + 1 .. ^1].strip(trailing = false, chars = {'/'})
    return if rel.len == 0: "~" else: "~/" & rel
  p

proc linkedMode*(path: string): string =
  ## The mode a link to `path` is reported with: whether it is executable.
  ## A link's permission bits are its target's, and a Nix store target is
  ## read-only, so the facts carry only what both sides can mean by a
  ## linked file: `0755` (executable by its owner) or `0644`.
  try:
    if fpUserExec in getFilePermissions(extendedPath(path)):
      return "0755"
  except OSError:
    discard
  "0644"

proc userFileDigest*(r: Resource): string =
  ## The digest of the bytes an `fs.userFile` resource would write, or ""
  ## when they are produced by a command at apply time (no producer can
  ## know them before; host facts report such a digest as `null`).
  doAssert r.kind == rkFsUserFile
  if r.userFileContentFromCommand.len > 0: ""
  else: sha256Digest(r.userFileContent)

proc stowOrigin*(stowSourcePath, profileDir: string): string =
  ## How a stow file is named to the reader: `stow <package>/<rel>`, the
  ## path under the profile (the host-facts `origin`).
  "stow " & stowSourcePath.relativePath(profileDir).replace('\\', '/')

proc resourceOrigin*(address: string): string =
  ## How a resource is named to the reader (the host-facts `origin`).
  "resource " & address

proc stowTargetIds*(entries: seq[StowEntry]; homeDir: string):
    HashSet[string] =
  ## The host-facts ids (`~/<rel>`) of the paths `entries` materialize.
  for e in entries:
    result.incl homeRelativeId(e.targetAbsolutePath, homeDir)

proc handedToStow*(rb: RecordedBinding; desired: DesiredSet;
                   stowIds: HashSet[string]; homeDir: string): bool =
  ## True when a previous generation's `fs.userFile` binding is no longer
  ## desired and its path is a stow target of this generation: the stow file
  ## took the path over (typically an agreeing resource that was removed),
  ## so the binding is released rather than destroyed. Destroying it would
  ## delete the path, which by then holds the new stow link.
  rb.kind == rkFsUserFile and rb.address notin desired.resources and
    homeRelativeId(rb.resourceId, homeDir) in stowIds

proc removeUnchangedUserFile*(rb: RecordedBinding): bool =
  ## Before the stow step links a path that a removed `fs.userFile` handed
  ## over (`handedToStow`), remove the file that resource wrote, so the
  ## stow file is linked rather than adopted as a stale copy. Removes only
  ## a regular file (never a link) whose bytes are still exactly the ones
  ## the binding recorded writing. A file the user edited since is left,
  ## and the stow step then treats it as it treats any pre-existing
  ## target. Returns true when the file was removed.
  let path = rb.resourceId
  try:
    if symlinkExists(extendedPath(path)) or
        not fileExists(extendedPath(path)):
      return false
    let raw = readFile(extendedPath(path))
    var bytes = newSeq[byte](raw.len)
    for i, ch in raw:
      bytes[i] = byte(ord(ch))
    if digestOfBytes(bytes) != rb.postWriteDigest:
      return false
    removeFile(extendedPath(path))
    true
  except OSError, IOError:
    false

type
  StowResourceResolution* = object
    files*: seq[PlannedGeneratedFile]
      ## The planned files without the stow files a resource writes.
    stowEntries*: seq[StowEntry]
      ## The stow entries to materialize, likewise.
    diagnostics*: seq[StowDiagnostic]
      ## One `IStowSameAsResource` per stow file a resource took over.

proc showDigest(d: string): string =
  if d.len == 0: "unknown until apply (content from a command)" else: d

proc resolveStowResourceOverlap*(files: seq[PlannedGeneratedFile];
                                 stowEntries: seq[StowEntry];
                                 resources: DesiredSet;
                                 profileDir, homeDir: string):
    StowResourceResolution =
  ## Apply the one-writer rule to every `$HOME` path that both a planned
  ## stow file (in `files`) and an `fs.userFile` resource in `resources`
  ## name. Paths are matched on their host-facts id (`~/<rel>`).
  ##
  ## Raises `EApplyPlanFailed` (via `raisePlanFailed`) listing every
  ## disagreeing pair when any pair disagrees on `mode` or `digest`; a
  ## resource whose content comes from a command never agrees (its bytes
  ## are not known before apply). Performs only reads (the stow source's
  ## permission bits); the caller has written nothing yet.
  var byId = initOrderedTable[string, Resource]()
  for _, r in resources.resources:
    if r.kind == rkFsUserFile:
      byId[homeRelativeId(r.userFileHostPath, homeDir)] = r
  var takenOver = initTable[string, bool]()   # stow target -> resource wins
  var conflicts: seq[string]
  for g in files:
    if g.sourceKind != pgfsStowFile:
      continue
    let id = homeRelativeId(g.absoluteOutputPath, homeDir)
    if id notin byId:
      continue
    let r = byId[id]
    let stowMode = linkedMode(g.stowSourcePath)
    let stowDigest = sha256Digest(g.contentBytes)
    let resDigest = userFileDigest(r)
    var differing: seq[string]
    if stowMode != r.userFileMode:
      differing.add "mode (" & stowMode & " vs " & r.userFileMode & ")"
    if resDigest != stowDigest:
      differing.add "digest (" & stowDigest & " vs " &
        showDigest(resDigest) & ")"
    if differing.len > 0:
      conflicts.add "`" & id & "` is written by " &
        stowOrigin(g.stowSourcePath, profileDir) & " and by " &
        resourceOrigin(r.address) & ", which disagree on " &
        differing.join(" and ")
    else:
      takenOver[g.absoluteOutputPath] = true
      result.diagnostics.add StowDiagnostic(
        severity: dsInfo,
        code: sdIStowSameAsResource,
        path: g.absoluteOutputPath,
        message: "IStowSameAsResource: " &
          stowOrigin(g.stowSourcePath, profileDir) & " is not linked at `" &
          id & "`: " & resourceOrigin(r.address) &
          " writes the same file (same mode and digest)")
  if conflicts.len > 0:
    raisePlanFailed("a stow file and an `fs.userFile` resource name the " &
      "same path and disagree; make them carry the same bytes and mode, " &
      "or remove one: " & conflicts.join("; "))
  for g in files:
    if g.sourceKind == pgfsStowFile and g.absoluteOutputPath in takenOver:
      continue
    result.files.add g
  for e in stowEntries:
    if e.targetAbsolutePath in takenOver:
      continue
    result.stowEntries.add e
