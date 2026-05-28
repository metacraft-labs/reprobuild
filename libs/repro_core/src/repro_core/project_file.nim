## Project-file filename resolution.
##
## The Reprobuild engine accepts two project-file names in a project
## directory:
##
## * ``repro.nim`` — the canonical name (preferred for new projects).
## * ``reprobuild.nim`` — the legacy name, supported as an alias.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"`repro.nim`
## ↔ `reprobuild.nim` alias" for the contract.
##
## Precedence: if both files exist in the same directory, ``repro.nim``
## wins and a one-line warning is emitted to stderr explaining that the
## ambiguity should be resolved by removing one of the two.
##
## This module is the single resolver every callsite that needs to find
## a project file in a directory should go through. The two filename
## constants are also exported so existing callsites that still hard-code
## ``"reprobuild.nim"`` for diagnostics, message text, or fixture
## generation continue to work without surprise.

import std/[os, strutils]

const
  CanonicalProjectFileName* = "repro.nim"
    ## The preferred (canonical) project-file name. New scaffolds, new
    ## examples, and new test fixtures SHOULD use this name.

  LegacyProjectFileName* = "reprobuild.nim"
    ## The legacy alias. Kept supported indefinitely — every existing
    ## ``reprobuild.nim`` in the ecosystem continues to work without any
    ## migration.

  ProjectFileNames* = [CanonicalProjectFileName, LegacyProjectFileName]
    ## Probing order: canonical first, legacy second. The first hit wins
    ## (see ``resolveProjectFile``). Iteration order is part of the
    ## contract — do NOT reorder.

type
  ProjectFileMatch* = object
    ## Result of probing a directory for a project file.
    ##
    ## ``path`` is empty when no project file is present. Callers should
    ## treat the empty-``path`` case as "no project file found" and use
    ## ``LegacyProjectFileName`` in diagnostic message text when they
    ## need to mention a representative filename (the legacy name is
    ## what every existing fixture and CI script still uses).
    path*: string
      ## Absolute or input-relative path to the resolved project file,
      ## or the empty string when none was found.
    fileName*: string
      ## The bare filename that matched (one of ``ProjectFileNames``),
      ## or the empty string when none was found. Callers can use this
      ## to print ``"<dir>/<fileName>"`` without re-computing the join.
    ambiguous*: bool
      ## ``true`` when BOTH ``repro.nim`` and ``reprobuild.nim`` exist in
      ## the same directory. The resolver picked ``repro.nim`` per the
      ## precedence rule; the caller is responsible for surfacing the
      ## ambiguity to the user (typically by calling
      ## ``warnIfAmbiguous``).

proc projectFileExists(path: string): bool =
  ## fileExists wrapper that consults the long-path-friendly form on
  ## Windows. Mirrors the pattern used by every existing project-file
  ## probe in the engine (``fileExists(extendedPath(...))``).
  when defined(windows):
    fileExists(path) or fileExists(r"\\?\" & path.replace('/', '\\'))
  else:
    fileExists(path)

proc resolveProjectFile*(projectRoot: string): ProjectFileMatch =
  ## Probe ``projectRoot`` for a project file. Returns a populated
  ## ``ProjectFileMatch`` if either ``repro.nim`` or ``reprobuild.nim``
  ## exists, with ``ambiguous=true`` when BOTH exist. Returns a
  ## default-initialised ``ProjectFileMatch`` (empty ``path`` / empty
  ## ``fileName``) when neither file is present.
  let canonical = projectRoot / CanonicalProjectFileName
  let legacy = projectRoot / LegacyProjectFileName
  let hasCanonical = projectFileExists(canonical)
  let hasLegacy = projectFileExists(legacy)
  if hasCanonical:
    ProjectFileMatch(
      path: canonical,
      fileName: CanonicalProjectFileName,
      ambiguous: hasLegacy)
  elif hasLegacy:
    ProjectFileMatch(
      path: legacy,
      fileName: LegacyProjectFileName,
      ambiguous: false)
  else:
    ProjectFileMatch()

proc projectFileIn*(projectRoot: string): string =
  ## Convenience wrapper around ``resolveProjectFile`` for callsites
  ## that only need the resolved path. Returns the empty string when no
  ## project file is present. Does NOT emit any warning even when both
  ## files exist — that's the caller's responsibility (call
  ## ``warnIfAmbiguous`` on the ``ProjectFileMatch`` if you want it).
  resolveProjectFile(projectRoot).path

proc ambiguousProjectFileMessage*(projectRoot: string): string =
  ## The exact warning text emitted when both ``repro.nim`` and
  ## ``reprobuild.nim`` are present. Exposed as a proc so tests can
  ## match against it without duplicating the wording.
  "warning: both " & CanonicalProjectFileName & " and " &
    LegacyProjectFileName & " exist in " & projectRoot &
    "; using " & CanonicalProjectFileName &
    " (ambiguous; remove one of these files)"

proc warnIfAmbiguous*(match: ProjectFileMatch; projectRoot: string) =
  ## Emit the canonical "both files present" warning to stderr when
  ## ``match.ambiguous`` is set. No-op otherwise. Idempotent at the
  ## call-site level — callers MAY de-duplicate per ``projectRoot`` if
  ## they expect to probe the same directory more than once.
  if match.ambiguous:
    stderr.writeLine(ambiguousProjectFileMessage(projectRoot))
