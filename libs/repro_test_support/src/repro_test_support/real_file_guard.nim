## Saving and restoring real files a test cannot keep away from.
##
## Tests write into scratch directories, never into the invoking user's real
## files. A few Windows legs may not be able to: PowerShell's per-user
## profiles live under the Documents folder the shell API reports
## (`SHGetFolderPathW` / `[Environment]::GetFolderPath('MyDocuments')`),
## which reads the user's registry
## (`HKCU\...\Explorer\User Shell Folders\Personal`). That value is
## normally `%USERPROFILE%\Documents`, expanded with the calling process's
## environment, so a test that redirects `USERPROFILE` moves the folder into
## its scratch home for the process under test and for the PowerShell it
## starts (observed on Windows 11, 2026-11-21). A value that names a folder
## absolutely (folder redirection, a synced Documents folder) is not moved
## by any environment variable, and redirecting it means editing that
## registry value or running as another user, both larger changes to the
## host than the one they would avoid.
##
## So a leg resolves the folder in the environment it gives the process
## under test, and saves first, and puts back after, only the files that
## still resolve outside its scratch directory. This module makes that as
## safe as it can be:
##
## * The saved bytes go to disk, under a journal directory, BEFORE the leg
##   touches anything, so a run that dies half way (killed, crashed, power
##   cut) leaves the originals recoverable rather than only in memory.
## * A journal that is already there means an earlier run died before it
##   restored. The next run then refuses to start, naming the journal, rather
##   than saving the half-modified files over the good copies.
## * `withRealFilesSaved` restores on every exit path (`finally`), including
##   a failing check or an exception.
## * Every file it saves and restores is printed on stderr, so a log says
##   which real files a run touched.
##
## The journal directory holds `manifest.txt` (one line per file:
## `<index>\t<existed 0|1>\t<dir existed 0|1>\t<path>`) and `<index>.saved`,
## the file's original bytes. Recovering by hand after a crash: copy each
## `<index>.saved` back to its path (delete the path where `existed` is 0),
## then delete the journal directory. A restore that succeeds deletes its
## journal and then the journal base (`repro-test-real-file-journal`) when no
## other journal is left in it, so after a clean run the base is gone too.

import std/[os, strutils]
when defined(windows):
  import std/winlean
else:
  import std/posix

type
  SavedRealFile = object
    path: string
    existed: bool
    dirExisted: bool

  RealFilesGuard* = object
    ## What `saveRealFiles` saved, and where its journal is.
    journal: string
    files: seq[SavedRealFile]

  RealFilesJournalExists* = object of IOError
    ## An earlier run left its journal: it did not restore.

const
  ManifestName = "manifest.txt"
  JournalBaseName = "repro-test-real-file-journal"
    ## The directory every `defaultRealFilesJournal` lives in.

proc removeDirIfEmpty(dir: string): bool =
  ## Removes `dir` only if it is empty, in one system call that fails on a
  ## non-empty directory (`rmdir` / `RemoveDirectoryW`), so a journal another
  ## run creates at the same moment is never removed with it. True when it
  ## was removed.
  when defined(windows):
    removeDirectoryW(newWideCString(dir)) != 0
  else:
    posix.rmdir(dir.cstring) == 0

proc pathsOutside*(paths: openArray[string]; dir: string): seq[string] =
  ## The `paths` that do not lie inside `dir`: the ones a leg that writes them
  ## must save first, because they are real files of the invoking user and
  ## not scratch. A path on another drive or share than `dir` is outside
  ## (`relativePath` cannot relate the two and returns the path itself, so
  ## `isRelativeTo` would call it inside). When in doubt a path counts as
  ## outside: saving a scratch file costs a copy, missing a real one costs
  ## the user's file.
  for p in paths:
    let rel =
      try: relativePath(p, dir)
      except CatchableError: ""
    let inside = rel.len > 0 and not rel.isAbsolute and rel != ".." and
      not rel.startsWith(".." & DirSep) and not rel.startsWith("../") and
      isAbsolute(p) and isAbsolute(dir)
    if not inside:
      result.add(p)

proc defaultRealFilesJournal*(label: string): string =
  ## A journal directory for `label`, outside every directory a test saves
  ## from: under `%LOCALAPPDATA%` on Windows, the XDG state directory
  ## elsewhere. Read from this process's environment, which tests do not
  ## redirect (they redirect the environment of the processes they start).
  let base =
    when defined(windows): getEnv("LOCALAPPDATA", getHomeDir() / "AppData" /
      "Local")
    else: getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  base / JournalBaseName / label

proc saveRealFiles*(paths: openArray[string]; journal: string):
    RealFilesGuard =
  ## Copies each of `paths` (present or not) into `journal` and returns what
  ## `restoreRealFiles` needs. Raises `RealFilesJournalExists`, touching
  ## nothing, when `journal` is already there. With no `paths` it saves
  ## nothing and writes no journal.
  if paths.len == 0:
    return
  if dirExists(journal) or fileExists(journal):
    raise newException(RealFilesJournalExists,
      "a previous run did not restore the real files it saved: the " &
      "journal " & journal & " is still there. Put each <n>.saved back to " &
      "the path " & ManifestName & " names for it (delete that path where " &
      "the second column is 0), delete the journal, then run again")
  result.journal = journal
  createDir(journal)
  var manifest = ""
  for i, path in paths:
    let f = SavedRealFile(path: path, existed: fileExists(path),
      dirExisted: dirExists(parentDir(path)))
    if f.existed:
      copyFile(path, journal / ($i & ".saved"))
    manifest.add($i & "\t" & (if f.existed: "1" else: "0") & "\t" &
      (if f.dirExisted: "1" else: "0") & "\t" & path & "\n")
    result.files.add(f)
    stderr.writeLine("real-file-guard: saved " & path &
      (if f.existed: "" else: " (absent)") & " to " & journal)
  # The manifest last: a journal without one holds nothing to restore yet.
  writeFile(journal / ManifestName, manifest)

proc restoreRealFiles*(guard: RealFilesGuard) =
  ## Puts every saved file back byte for byte, removes those that did not
  ## exist and the directories the leg created (when empty), then deletes
  ## the journal. A file it cannot restore is reported and the journal is
  ## kept, so the next run refuses until someone restores it.
  if guard.journal.len == 0:
    return
  var failed = false
  for i, f in guard.files:
    try:
      if f.existed:
        createDir(parentDir(f.path))
        copyFile(guard.journal / ($i & ".saved"), f.path)
      elif fileExists(f.path):
        removeFile(f.path)
      stderr.writeLine("real-file-guard: restored " & f.path &
        (if f.existed: "" else: " (removed: it was absent)"))
    except CatchableError as err:
      failed = true
      stderr.writeLine("real-file-guard: could NOT restore " & f.path &
        ": " & err.msg & "; its original is in " & guard.journal)
  if failed:
    raise newException(IOError, "real files not restored; see " &
      guard.journal / ManifestName)
  for f in guard.files:
    let dir = parentDir(f.path)
    if not f.dirExisted and dirExists(dir):
      var empty = true
      for _ in walkDir(dir):
        empty = false
        break
      if empty:
        removeDir(dir)
  removeDir(guard.journal)
  # The journal base too, once no journal is left in it: a check that the
  # base is absent then shows that every run restored what it saved.
  let base = parentDir(guard.journal)
  if base.extractFilename == JournalBaseName and dirExists(base):
    discard removeDirIfEmpty(base)

template withRealFilesSaved*(paths: openArray[string]; journal: string;
                             body: untyped) =
  ## Runs `body` with `paths` saved to `journal` first and restored after,
  ## on every exit path.
  let realFilesGuard = saveRealFiles(paths, journal)
  try:
    body
  finally:
    restoreRealFiles(realFilesGuard)
