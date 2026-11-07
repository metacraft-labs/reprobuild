## Archives a recipe needs beside its one `fetch:` block, each pinned by
## URL and SHA-256.
##
## A recipe's `fetch:` block names ONE source. Some builds need more: the
## Nim fork vendors five source trees under `dist/` beside its own
## (reprobuild-packages `nim-fork`), and an installed prefix bundles
## runtime libraries taken from a distribution's `.deb` packages
## (reprobuild-pm Distribution-And-Packaging.md §5.3, decision C). Each of
## those is one edge from here: download into the project's fetch scratch,
## refuse the bytes unless they hash to the pin, unpack into a staging
## directory and move it into place, then write the verified-fetch stamp.
## The same shell fragments as a recipe's own fetch
## (`repro_project_dsl/shell_fetch`), so a pinned archive is acquired the
## way every source is.
##
## A `.deb` is an `ar` archive whose `data.tar.*` member is the package's
## file tree (https://man7.org/linux/man-pages/man5/deb.5.html). It is
## unpacked with `ar` and `tar` -- only the data member, so no maintainer
## script is even extracted -- rather than with `dpkg-deb`, which a
## path-mode build host need not have. Its pin is the `SHA256` field of the
## archive's `Packages` index, so the bytes used are the bytes the
## distribution signed.
##
## Non-cacheable, in the `fetch` pool, like every source fetch: the edge
## reaches the network, and its stamp says the archive was verified, not
## that the unpacked tree still exists.

import std/[os, strutils]

import repro_project_dsl
import repro_project_dsl/shell_fetch

type
  PinnedArchiveKind* = enum
    pakTarball  ## a tar archive (compression from the URL's extension)
    pakDeb      ## a Debian binary package: its `data.tar.*` member

  PinnedArchive* = object
    name*: string       ## the archive's name within the recipe (an id part)
    url*: string
    sha256*: string     ## lower-case hex
    kind*: PinnedArchiveKind
    stripComponents*: int
      ## leading path components a tarball's members drop (GitHub's tag and
      ## commit archives carry one); ignored for a `.deb`

const PinnedFetchScratchSubdir* = ".repro/fetch"

proc pinnedFetchActionId*(packageName, name: string): string =
  ## `pinned-fetch-<package>-<name>`, with every byte outside
  ## `[A-Za-z0-9._-]` an underscore.
  result = "pinned-fetch-"
  for ch in packageName & "-" & name:
    result.add(if ch.isAlphaNumeric or ch in {'-', '_', '.'}: ch else: '_')

proc archiveSuffix(url: string; kind: PinnedArchiveKind): string =
  if kind == pakDeb:
    return ".deb"
  var path = url
  for marker in ['?', '#']:
    let at = path.find(marker)
    if at >= 0:
      path.setLen(at)
  for suffix in [".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2",
                 ".tar.zst", ".tzst", ".tar"]:
    if path.toLowerAscii.endsWith(suffix):
      return suffix
  ".tar"

proc validatePinnedArchive(a: PinnedArchive) =
  if a.name.len == 0:
    raise newException(ValueError, "pinned archive: an empty name")
  if a.url.len == 0:
    raise newException(ValueError, "pinned archive '" & a.name &
      "': an empty URL")
  if a.sha256.len != 64 or not a.sha256.allCharsInSet({'0' .. '9', 'a' .. 'f'}):
    raise newException(ValueError, "pinned archive '" & a.name &
      "': the sha256 must be 64 lower-case hex digits, got '" & a.sha256 & "'")
  if a.stripComponents < 0:
    raise newException(ValueError, "pinned archive '" & a.name &
      "': stripComponents is negative")

proc pinnedFetchScript*(projectRoot: string; a: PinnedArchive;
                        extractDir: string): string =
  ## The edge's shell program. Exposed for the tests.
  validatePinnedArchive(a)
  let scratch = projectRoot / PinnedFetchScratchSubdir
  let archive = scratch / (a.sha256 & archiveSuffix(a.url, a.kind))
  let stamp = scratch / (a.sha256 & ".stamp")
  let staged = extractDir & ".repro-extract-" & a.sha256
  proc dq(value: string): string =
    value.replace("\\", "/").replace("\"", "\\\"")
  result = "set -e; "
  result.add("mkdir -p \"" & dq(scratch) & "\" \"" & dq(extractDir.parentDir) &
    "\"; ")
  result.add("rm -rf \"" & dq(staged) & "\"; ")
  result.add("mkdir -p \"" & dq(staged) & "\"; ")
  result.appendCurlDownload(archive, a.url)
  result.add("echo \"" & a.sha256 & "  " & dq(archive) &
    "\" | sha256sum -c -; ")
  case a.kind
  of pakTarball:
    result.appendTarExtraction(archive, staged, a.stripComponents)
  of pakDeb:
    # Only the `data.tar.*` member is taken out of the `ar` archive; GNU
    # tar detects its compression from the member's name.
    result.add("(cd \"" & dq(staged) & "\" && member= && " &
      "for m in $(ar t \"" & dq(archive) & "\"); do case $m in " &
      "data.tar*) member=$m;; esac; done && " &
      "[ -n \"$member\" ] && ar x \"" & dq(archive) & "\" \"$member\" && " &
      "tar -xf \"$member\" && rm -f \"$member\"); ")
  result.add("rm -rf \"" & dq(extractDir) & "\"; ")
  result.add("mv \"" & dq(staged) & "\" \"" & dq(extractDir) & "\"; ")
  result.appendVerifiedFetchStamp(stamp)

proc pinnedFetchStamp*(projectRoot: string; a: PinnedArchive): string =
  ## The stamp the fetch edge writes once the archive is verified and
  ## unpacked: the output a consumer orders after.
  projectRoot / PinnedFetchScratchSubdir / (a.sha256 & ".stamp")

proc emitPinnedFetchAction*(projectRoot, packageName: string;
                            a: PinnedArchive; extractDir: string):
    BuildActionDef =
  ## The fetch edge for `a`, unpacking into `extractDir`. One edge per
  ## package and archive name: a second call returns the edge the first
  ## registered.
  let id = pinnedFetchActionId(packageName, a.name)
  for existing in registeredBuildActions():
    if existing.id == id:
      return existing
  let script = pinnedFetchScript(projectRoot, a, extractDir)
  var tools = shellFetchToolIdentityRefs(["sha256sum"], archiveUrl = a.url)
  if a.kind == pakDeb:
    # The data member's compression: `xz` for Debian since trixie's
    # predecessors, `zstd` for Ubuntu; an undeclared one is inert.
    for tool in ["ar", "xz", "zstd"]:
      if tool notin tools:
        tools.add(tool)
  buildAction(
    id = id,
    call = inlineExecCall(@["sh", "-c", script], projectRoot),
    inputs = @[],
    outputs = @[pinnedFetchStamp(projectRoot, a)],
    pool = "fetch",
    cacheable = false,
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "pinned-fetch",
    env = shellFetchRuntimeEnv(),
    toolIdentityRefs = tools)
