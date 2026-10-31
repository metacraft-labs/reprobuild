## Staging a manifest's profile sources for the on-target compile.
##
## The agent compiles the profile a manifest carries, and the compiler
## needs files: the profile as a `.nim` module, and, since RDMF v3, the
## files the profile reads at compile time beside it, at the relative
## paths the profile names (`staticRead("locks/node-exporter.lock")`
## resolves against the directory of the source file that contains it;
## https://nim-lang.org/docs/system.html#staticRead%2Cstring). Deploy-Agent.md
## §"Field semantics", `profileFiles`.
##
## The staged tree is rebuilt from scratch on every tick. A file a previous
## manifest carried and the current one does not must not survive here: a
## `staticRead` that still finds yesterday's lock compiles a profile the
## producer did not publish.

import std/os

import ./manifest

proc stageProfileSources*(dir: string; profileText: string;
                          profileFiles: openArray[ProfileFile]): string =
  ## Write `profileText` as `dir/manifest_profile.nim` and every bundle
  ## file at `dir/<path>`, after removing whatever `dir` held. Returns the
  ## staged module's path. Every path is validated again here
  ## (`profileFilePathError`) although the decoder already did: this proc
  ## writes as root under `dir`, and a check beside a write is the one
  ## that cannot be bypassed by a caller that built the manifest in
  ## memory.
  validateProfileFiles(profileFiles)
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  result = dir / StagedProfileModule
  writeFile(result, profileText)
  for f in profileFiles:
    let target = dir / f.path
    createDir(parentDir(target))
    writeFile(target, f.content)
