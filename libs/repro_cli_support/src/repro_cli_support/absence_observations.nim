## repro_cli_support/absence_observations.nim -- absence observations in a test
## certificate (Test-Certificates.md, "Absence observations").
##
## A test that looks for a file and finds none observes the file's absence. A
## failed lookup of a path that is absent from the committed tree and absent on
## disk at test time is bound into the certificate as `absent`, so that a
## verifier who checks out `content` finds the path absent too, and creating the
## file afterwards invalidates the certificate.
##
## Pure, with no imports beyond the standard library, so the rule is tested
## without the certificate machinery. The certificate record and the verifier
## call these two procs; nothing here issues or signs anything.

import std/[algorithm, os, sets, strutils]

proc repositoryRelative(repositoryRoot, path: string): string =
  ## ``path`` relative to ``repositoryRoot``, or "" when it does not lie inside
  ## the repository. Both sides are normalised, so a trailing separator or a
  ## ``./`` does not matter.
  let root = repositoryRoot.normalizedPath().strip(leading = false, chars = {'/', '\\'})
  let full = path.normalizedPath()
  if root.len == 0 or full.len <= root.len + 1:
    return ""
  if not full.startsWith(root) or full[root.len] notin {DirSep, AltSep}:
    return ""
  full[root.len + 1 .. ^1]

proc presentNow(absolutePath: string): bool =
  ## True when something exists at the path now, as a file, a directory or a
  ## symbolic link (a dangling link is present: it names something).
  fileExists(absolutePath) or dirExists(absolutePath) or
    symlinkExists(absolutePath)

proc bindableAbsences*(failedLookups: openArray[string];
                       repositoryRoot: string;
                       trackedPaths: HashSet[string]): seq[string] =
  ## The repository-relative paths a certificate binds as `absent`: the failed
  ## lookups that lie inside the repository, are not tracked, and are absent
  ## now. A lookup of a path outside the repository is not bound here (it is
  ## judged like other out-of-repository reads), and a tracked path that is
  ## absent is a deletion, which the content already names.
  var seen = initHashSet[string]()
  for path in failedLookups:
    let relative = repositoryRelative(repositoryRoot, path)
    if relative.len == 0 or relative in trackedPaths:
      continue
    if presentNow(repositoryRoot / relative):
      continue
    if not seen.containsOrIncl(relative):
      result.add(relative)
  result.sort(system.cmp[string])

proc absenceViolations*(boundAbsences: openArray[string];
                        repositoryRoot: string): seq[string] =
  ## The bound absences a verifier finds present now: each one is a file a test
  ## consumed as absent and that has since appeared, which invalidates the
  ## certificate. Empty means every bound absence still holds.
  for relative in boundAbsences:
    if presentNow(repositoryRoot / relative):
      result.add(relative)
  result.sort(system.cmp[string])
