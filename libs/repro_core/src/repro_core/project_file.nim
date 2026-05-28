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
## Precedence: it is an error to have BOTH files in the same directory.
## ``resolveProjectFile`` raises ``ProjectFileAmbiguousError`` when both
## names exist; callers either let the error propagate to the CLI's
## top-level handler (which prints the message and exits non-zero) or
## catch it explicitly.
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

  ProjectFileAmbiguousError* = object of CatchableError
    ## Raised by ``resolveProjectFile`` when both ``repro.nim`` and
    ## ``reprobuild.nim`` exist in the same directory. The message text
    ## names both files plus the directory and tells the user to remove
    ## the legacy ``reprobuild.nim`` (we are migrating toward
    ## ``repro.nim`` as the canonical name).

proc projectFileExists(path: string): bool =
  ## fileExists wrapper that consults the long-path-friendly form on
  ## Windows. Mirrors the pattern used by every existing project-file
  ## probe in the engine (``fileExists(extendedPath(...))``).
  when defined(windows):
    fileExists(path) or fileExists(r"\\?\" & path.replace('/', '\\'))
  else:
    fileExists(path)

proc ambiguousProjectFileMessage*(projectRoot: string): string =
  ## The exact text raised when both ``repro.nim`` and ``reprobuild.nim``
  ## are present. Exposed as a proc so tests can match against it without
  ## duplicating the wording. NOTE: no leading ``"error: "`` — the CLI
  ## top-level handler already prefixes ``"repro <subcommand>: error: "``
  ## when it catches a propagated ``CatchableError``; including ``error:``
  ## here would surface as a confusing ``"error: error: ..."`` to the
  ## user. Pure-library callers that want a leading ``error:`` should add
  ## one explicitly.
  "both " & CanonicalProjectFileName & " and " &
    LegacyProjectFileName & " exist in " & projectRoot &
    "; remove " & LegacyProjectFileName &
    " (the canonical name is " & CanonicalProjectFileName & ")"

proc resolveProjectFile*(projectRoot: string): ProjectFileMatch =
  ## Probe ``projectRoot`` for a project file. Returns a populated
  ## ``ProjectFileMatch`` if either ``repro.nim`` or ``reprobuild.nim``
  ## exists. Returns a default-initialised ``ProjectFileMatch`` (empty
  ## ``path`` / empty ``fileName``) when neither file is present.
  ##
  ## **Raises** ``ProjectFileAmbiguousError`` when BOTH files exist —
  ## the spec (Three-Mode-Convention-System.md §"`repro.nim` ↔
  ## `reprobuild.nim` alias") declares this an error, not a warning.
  let canonical = projectRoot / CanonicalProjectFileName
  let legacy = projectRoot / LegacyProjectFileName
  let hasCanonical = projectFileExists(canonical)
  let hasLegacy = projectFileExists(legacy)
  if hasCanonical and hasLegacy:
    raise newException(ProjectFileAmbiguousError,
      ambiguousProjectFileMessage(projectRoot))
  if hasCanonical:
    ProjectFileMatch(
      path: canonical,
      fileName: CanonicalProjectFileName)
  elif hasLegacy:
    ProjectFileMatch(
      path: legacy,
      fileName: LegacyProjectFileName)
  else:
    ProjectFileMatch()

proc projectFileIn*(projectRoot: string): string =
  ## Convenience wrapper around ``resolveProjectFile`` for callsites
  ## that only need the resolved path. Returns the empty string when no
  ## project file is present. Raises ``ProjectFileAmbiguousError`` when
  ## both names coexist (same contract as ``resolveProjectFile``).
  resolveProjectFile(projectRoot).path
