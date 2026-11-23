## Workspace checkout and diffs (ReproOS-Agent-Harbor-Integration M3
## deliverables 2 and 4).
##
## A workspace is a git repository whose first commit, tagged
## `reproos-base`, is an exact copy of the recipe directory that produced
## the installed prefix (its definition files: `.repro/` and `build/` are
## build state and are left behind). The agent edits the copy; the change
## is `git diff reproos-base`. Nothing is ever edited in place: the store
## prefix is read-only and outside the workspace, and the catalog's recipe
## is only read. A change reaches the system only as a new build of the
## workspace's definition, never as a write to an installed path.
##
## Git runs with system and global configuration disabled and a fixed
## identity and date, so the base commit is a function of the recipe tree
## alone and no user hook or config can run.

import std/[os, osproc, streams, strtabs, strutils]

import repro_core/ambient_execution
import repro_core/link_target

import ./ownership

type
  CheckoutError* = object of CatchableError

  Checkout* = object
    root*: string        ## the workspace (git) root
    packageDir*: string  ## `root / recipeName`, where builds run
    baseCommit*: string
    ownership*: OwnershipRecord

const
  BaseTag* = "reproos-base"
  OwnershipFile* = ".reproos-agent/ownership"
  FixedDate = "2000-01-01T00:00:00Z"

proc gitEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if not k.startsWith("GIT_"):
      result[k] = v
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_CONFIG_GLOBAL"] = "/dev/null"
  result["GIT_AUTHOR_NAME"] = "ReproOS"
  result["GIT_AUTHOR_EMAIL"] = "agent@reproos.invalid"
  result["GIT_COMMITTER_NAME"] = "ReproOS"
  result["GIT_COMMITTER_EMAIL"] = "agent@reproos.invalid"
  result["GIT_AUTHOR_DATE"] = FixedDate
  result["GIT_COMMITTER_DATE"] = FixedDate

proc git*(root: string; args: openArray[string]): string =
  ## Run git in `root` without a shell; raise `CheckoutError` with its
  ## output on a non-zero exit.
  ##
  ## Ambient by necessity for now: the host runs the git of the active
  ## generation from PATH, with its configuration neutralised above. A
  ## typed execution profile for the host's tools is open follow-up work
  ## (recorded under M3 in the campaign file).
  let exe = uncontrolledFindExe("git")
  if exe.len == 0:
    raise newException(CheckoutError, "git is not on PATH")
  let p = uncontrolledStartProcess(exe, workingDir = root, args = @args,
                                   env = gitEnv(),
                                   options = {poStdErrToStdOut})
  defer: p.close()
  result = p.outputStream.readAll()
  if p.waitForExit() != 0:
    raise newException(CheckoutError, "git " & args.join(" ") & ": " & result)

proc copyDefinition(src, dst: string) =
  ## Copy the recipe's definition files, keeping symlinks as symlinks and
  ## the executable bit.
  for rel in recipeFiles(src):
    let s = src / rel
    let d = dst / rel
    createDir(d.parentDir)
    if symlinkExists(s):
      createSymlink(readSymlinkTarget(s), d)
    else:
      copyFileWithPermissions(s, d)

proc renderOwnership(r: OwnershipRecord): string =
  ## A plain `key=value` record of what the workspace was checked out from.
  ## Informational: the host keeps the authoritative record.
  for (k, v) in [("package", r.package), ("version", r.version),
                 ("prefix", r.prefixId), ("receipt", r.receiptDigest),
                 ("recipe", r.recipeName),
                 ("recipe-tree", r.recipeTreeDigest)]:
    result.add k & "=" & v & "\n"
  for p in r.pending:
    result.add "pending=" & p & "\n"

proc createCheckout*(rec: OwnershipRecord; root: string;
                     storeRoot = ""): Checkout =
  ## Check out `rec`'s recipe into the empty directory `root`. Refuses a
  ## recipe that lives inside the store (an installed path is never a
  ## definition) and a recipe that changed between ownership resolution
  ## and the copy.
  if storeRoot.len > 0:
    let store = expandFilename(storeRoot)
    let recipe = expandFilename(rec.recipeDir)
    if recipe == store or recipe.startsWith(store & DirSep):
      raise newException(CheckoutError,
        "recipe " & rec.recipeDir & " is inside the store")
  createDir(root)
  for _ in walkDir(root):
    raise newException(CheckoutError, "checkout root is not empty: " & root)
  let pkgDir = root / rec.recipeName
  copyDefinition(rec.recipeDir, pkgDir)
  if recipeTreeDigest(pkgDir) != rec.recipeTreeDigest:
    removeDir(root)
    createDir(root)
    raise newException(CheckoutError,
      "recipe " & rec.recipeDir & " changed while it was being checked out")
  # Build state stays out of the change.
  writeFile(root / ".gitignore", "/*/.repro/\n/*/build/\n/.reproos-agent/\n")
  createDir(root / ".reproos-agent")
  writeFile(root / OwnershipFile, renderOwnership(rec))
  discard git(root, ["init", "--quiet", "--initial-branch=change"])
  discard git(root, ["add", "--all"])
  discard git(root, ["commit", "--quiet", "--no-verify", "-m",
                     "base: " & rec.package & " " & rec.version])
  discard git(root, ["tag", BaseTag])
  result = Checkout(root: root, packageDir: pkgDir, ownership: rec,
                    baseCommit: git(root, ["rev-parse", BaseTag]).strip)

proc diffAgainstBase*(root: string): string =
  ## The workspace's change as a unified diff against the base commit,
  ## including files the agent created (as intent-to-add) and without
  ## rename detection, so every path appears under its own name.
  discard git(root, ["add", "--all", "--intent-to-add"])
  git(root, ["diff", "--no-color", "--no-ext-diff", "--no-renames",
             BaseTag])
