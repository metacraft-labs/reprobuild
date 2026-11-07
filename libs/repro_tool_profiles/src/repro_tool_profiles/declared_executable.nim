## The probe realization applies to a package's declared executable, and the
## reason it gives when the probe fails.
##
## A realized prefix is accepted only when the path the package DECLARES
## resolves inside it to something a consumer can actually use. There are four
## distinct ways that can fail, and before this module they were one: every
## caller reduced the answer to a string that was either the resolved path or
## empty, and every refusal message said the realization "lacks" the
## executable.
##
## That cost a real investigation. `python3`'s POSIX tarball arms declared
## ``python/bin/python3``, which in the pinned python-build-standalone archive
## is a relative SYMLINK to ``python3.12``. The realizer refuses a declared
## executable reached through a symlink, so provisioning downloaded the
## archive, verified its digest, extracted it, and then reported
##
##     tool-resolution failed: extracted tarball lacks executable
##     python/bin/python3
##
## about an archive that plainly contains that entry
## (reprobuild-pm/issues/2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md).
## Anyone reading that message goes looking for a missing file, which is the
## one thing that was not wrong.
##
## So the probe returns a VERDICT rather than a string, and ``reason`` renders
## it. ``executableInStorePath`` remains as the predicate-shaped wrapper its
## several callers want (a path, or "" when the prefix will not do), with the
## same accept/reject set it has always had.
##
## Provisioning-Contributions.md §"Conformance And Trust" requires that
## "executable probes ... pass" before a contribution is published, and
## §"A declared path that is present but symlinked is reported as such"
## requires the refusal to distinguish the two.

import std/[os, sequtils, strutils]

# ``extendedPath`` is the Windows ``\\?\`` long-path spelling every
# filesystem probe in this tree goes through; a declared path inside a store
# prefix is exactly the case that overruns MAX_PATH.
import repro_core/link_target
import repro_core/paths

type
  DeclaredExecutableVerdict* = enum
    ## Why a declared executable path is, or is not, usable inside a prefix.
    deOk = "ok"
      ## The declared path is a regular file inside the prefix, reached
      ## without traversing a symlink, and either carries an execute bit or
      ## is one of the data declarations below.
    deUnsafePath = "unsafe-path"
      ## The declaration itself is unusable: empty, absolute, or escaping the
      ## prefix through ``..``. Rejected without touching the filesystem.
    deSymlinkedPath = "symlinked-path"
      ## The declared path exists but a component of it is a symlink. Only
      ## reported when the caller asked for ``rejectSymlinks``.
    deMissing = "missing"
      ## No file at the declared path.
    deNotExecutable = "not-executable"
      ## The declared path is a file with no execute permission for anyone,
      ## and its extension does not mark it as a data declaration.

  DeclaredExecutableProbe* = object
    ## The outcome of probing one declared path against one prefix.
    verdict*: DeclaredExecutableVerdict
    declaredPath*: string
      ## The path as the package declared it, verbatim, so a message quotes
      ## what the author wrote rather than a normalized spelling of it.
    resolvedPath*: string
      ## Absolute path of the declared file. Populated only for ``deOk``.
    symlinkComponent*: string
      ## For ``deSymlinkedPath``: the prefix-relative component that is a
      ## symlink. It is not always the leaf — an intermediate directory can
      ## be the link, and then the leaf is innocent.
    symlinkTarget*: string
      ## For ``deSymlinkedPath``: what that component points at, as recorded
      ## in the link (so usually relative). "" when it could not be read.

const DataDeclarationExtensions* = [".pc", ".so", ".dll", ".a", ".h", ".hpp",
  ".cmake", ".json", ".xml", ".txt", ".ids", ".bin", ".onnx",
  ".js", ".mjs", ".cjs"]
  ## Extensions whose declarations are accepted WITHOUT the execute-permission
  ## requirement, because nothing ever spawns them.
  ##
  ## M9.R.14d.8b — data-file declarations (e.g. wayland-protocols's
  ## ``share/pkgconfig/wayland-protocols.pc``) point at non-executable
  ## files that exist only to verify the realization completed. Detect
  ## these by extension and accept them without the +x permission
  ## requirement; the consumer threads the parent prefix into
  ## PKG_CONFIG_PATH at build time rather than spawning the file
  ## directly.
  ## M9.R.15q.5.9 — hwdata ships ``share/hwdata/pnp.ids`` (the PnP
  ## vendor-ID database). Recognise ``.ids`` as a data declaration so
  ## the executable+permission check is skipped (the file is r--r--r--
  ## in the nix store).
  ## M9.R.15q.5.10 — ``.dll`` is the Windows sibling of ``.so`` and was
  ## missing from a list that already carried the POSIX one. The case that
  ## surfaced it: electron-builder's ``nsis-resources`` archive is a flat tree
  ## of plugin DLLs with no program in it at all, so the only anchor a
  ## declaration can name is a DLL, and a DLL is not something anyone spawns.
  ## Its absence here made the package's realize depend on Windows reporting
  ## execute permission for ordinary files rather than on a stated rule.
  ## M9.R.15q.5.11 — ``.bin`` and ``.onnx`` are MODEL WEIGHTS: a Whisper
  ## ``ggml-base.bin`` or a Piper voice's ``.onnx`` is a multi-megabyte blob
  ## that a runtime memory-maps and that nothing ever spawns. They arrive
  ## through ``archiveType = "raw"``, which copies a single downloaded file
  ## into the prefix under its declared name, so the declared path IS the
  ## payload and there is no program in the package to anchor on instead.
  ## M9.R.15q.5.12 — ``.js``/``.mjs``/``.cjs`` are SCRIPTS, and a script is
  ## the case ``launcher`` exists for: the declared path is the payload an
  ## interpreter runs, never a program the OS execs, so it carries no execute
  ## bit on any host. The launcher pair realize writes beside it is what ends
  ## up being invoked.

proc unsafeRelativePath*(value: string): bool =
  ## Whether ``value`` is unusable as a prefix-relative declaration: empty,
  ## absolute, or escaping the prefix through ``..``.
  let normalized = value.replace('\\', '/')
  if normalized.len == 0 or normalized.startsWith("/"):
    return true
  for part in normalized.split('/'):
    if part == "..":
      return true

proc symlinkComponentOf*(root, relativePath: string):
    tuple[component, target: string] =
  ## The first component of ``relativePath`` under ``root`` that is a symlink,
  ## with what it points at. ``component`` is "" when no component is one.
  ##
  ## Walks every component rather than stat-ing the leaf, because an
  ## intermediate directory can be the link: the declaration is equally
  ## unrealizable then, and naming the leaf would send the reader to the wrong
  ## file.
  var current = root
  var walked = ""
  for part in relativePath.replace('\\', '/').split('/'):
    if part.len == 0 or part == ".":
      continue
    current = current / part
    walked = if walked.len == 0: part else: walked & "/" & part
    try:
      if getFileInfo(extendedPath(current), followSymlink = false).kind in
          {pcLinkToFile, pcLinkToDir}:
        var target = ""
        try:
          target = readSymlinkTarget(extendedPath(current))
        except OSError, IOError:
          discard
        return (component: walked, target: target)
    except OSError:
      discard
  (component: "", target: "")

proc pathContainsSymlink*(root, relativePath: string): bool =
  ## Whether any component of ``relativePath`` under ``root`` is a symlink.
  symlinkComponentOf(root, relativePath).component.len > 0

proc isDataDeclaration*(declaredExecutablePath: string): bool =
  ## Whether the declaration names a payload nothing spawns, and so is
  ## accepted without the execute-permission requirement. See
  ## ``DataDeclarationExtensions``.
  let lower = declaredExecutablePath.toLowerAscii
  for ext in DataDeclarationExtensions:
    if lower.endsWith(ext) or lower.contains(ext & "."):
      return true
  false

proc probeDeclaredExecutable*(storePath, declaredExecutablePath: string;
                              rejectSymlinks = false):
    DeclaredExecutableProbe =
  ## Probe ``declaredExecutablePath`` inside ``storePath`` and say what is
  ## wrong when something is. The accept set is exactly
  ## ``executableInStorePath``'s, which is implemented on top of this.
  result.declaredPath = declaredExecutablePath
  if declaredExecutablePath.unsafeRelativePath:
    result.verdict = deUnsafePath
    return
  if rejectSymlinks:
    let link = symlinkComponentOf(storePath, declaredExecutablePath)
    if link.component.len > 0:
      result.verdict = deSymlinkedPath
      result.symlinkComponent = link.component
      result.symlinkTarget = link.target
      return
  let candidate = storePath / declaredExecutablePath
  if not fileExists(extendedPath(candidate)):
    result.verdict = deMissing
    return
  if declaredExecutablePath.isDataDeclaration:
    result.verdict = deOk
    result.resolvedPath = absolutePath(candidate)
    return
  if {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
      it in getFilePermissions(extendedPath(candidate))):
    result.verdict = deOk
    result.resolvedPath = absolutePath(candidate)
    return
  result.verdict = deNotExecutable

proc reason*(probe: DeclaredExecutableProbe): string =
  ## The clause a refusal message carries, so the four verdicts read
  ## differently where they used to read identically. Written to follow a
  ## subject naming the realization: "extracted tarball " & probe.reason.
  case probe.verdict
  of deOk:
    "carries executable " & probe.declaredPath
  of deUnsafePath:
    "declares an unsafe executable path " & probe.declaredPath
  of deSymlinkedPath:
    "declares executable " & probe.declaredPath & ", which is present but " &
      "reached through a symlink (" & probe.symlinkComponent &
      (if probe.symlinkTarget.len > 0: " -> " & probe.symlinkTarget else: "") &
      "); declare the regular file it resolves to"
  of deMissing:
    # Unchanged wording: the genuinely-absent case is the one this message
    # was always right about, and existing reports quote it.
    "lacks executable " & probe.declaredPath
  of deNotExecutable:
    "declares executable " & probe.declaredPath & ", which is present but " &
      "carries no execute permission"

proc executableInStorePath*(storePath, declaredExecutablePath: string;
                            rejectSymlinks = false): string =
  ## The absolute path of the declared executable inside ``storePath``, or ""
  ## when the prefix will not do. The predicate-shaped view of
  ## ``probeDeclaredExecutable``, for the callers that only choose between
  ## prefixes and have no message to write.
  probeDeclaredExecutable(storePath, declaredExecutablePath,
    rejectSymlinks).resolvedPath
