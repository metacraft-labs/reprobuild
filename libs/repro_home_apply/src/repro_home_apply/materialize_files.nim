## Stage generated files into `$HOME` (apply pipeline step 8a).
##
## Two materialization paths live here:
##
##   1. Package-driven files (Phase A): the M59 stdlib emits a list of
##      `(target-path, content-bytes)` entries during plan synthesis;
##      this module writes each through a staging-then-rename so the
##      target file appears atomically. The bytes are also hashed into
##      the M56 CAS so the activation manifest can record the content
##      digest for drift detection.
##
##   2. Stow files (Phase B): see `./stow.nim` + `./suppression.nim`.
##      The decision tree (symlink → junction → copy) lives in those
##      modules; this module exposes only the `materializeStowEntry`
##      helper they call.
##
## Both paths produce a `GeneratedFile` manifest record handed back to
## the pipeline orchestrator.

import std/[os, strutils]

import blake3
import repro_home_generations
import repro_local_store

import ./errors
import ./plan

type
  StagedFileRecord* = object
    ## One materialized file's recorded state.
    absoluteOutputPath*: string
    sourceKind*: PlannedGeneratedFileSource
    contributingPackage*: string
    stowSource*: string
    preWriteDigest*: Digest256
    hasPreWriteDigest*: bool
    postWriteDigest*: Digest256
    ownershipPolicy*: GeneratedFileOwnership

proc digestBytes(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc atomicWriteBytes(dst: string; content: openArray[byte]) =
  ## Stage at `<dst>.repro.tmp` then move into place.
  let parent = parentDir(dst)
  if parent.len > 0:
    createDir(parent)
  let tmp = dst & ".repro.tmp"
  var text = newString(content.len)
  for i, b in content:
    text[i] = char(b)
  writeFile(tmp, text)
  if fileExists(dst):
    try:
      removeFile(dst)
    except OSError as err:
      raiseMaterializeFailed(dst,
        "could not remove pre-existing target before atomic rename: " &
        err.msg)
  try:
    moveFile(tmp, dst)
  except OSError as err:
    raiseMaterializeFailed(dst,
      "could not move staging file '" & tmp & "' into place: " &
      err.msg)

proc readPreWriteDigest(dst: string): tuple[has: bool; digest: Digest256] =
  ## Capture the pre-existing content's BLAKE3-256 so rollback can
  ## restore it on `EUserEditDetected` paths.
  if not fileExists(dst):
    return (false, default(Digest256))
  let raw = readFile(dst)
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  (true, digestBytes(buf))

proc materializePackageOutput*(planned: PlannedGeneratedFile): StagedFileRecord =
  ## Phase A entry point: write the package-supplied content into the
  ## target path. The target is assumed `owned` (the package owns the
  ## file; no merging). Future milestones add `merged` and
  ## `existing-preserved` policy paths.
  result.absoluteOutputPath = planned.absoluteOutputPath
  result.sourceKind = planned.sourceKind
  result.contributingPackage = planned.contributingPackage
  result.ownershipPolicy = gfoOwned
  let pre = readPreWriteDigest(planned.absoluteOutputPath)
  result.hasPreWriteDigest = pre.has
  if pre.has:
    result.preWriteDigest = pre.digest
  atomicWriteBytes(planned.absoluteOutputPath, planned.contentBytes)
  result.postWriteDigest = digestBytes(planned.contentBytes)

proc deleteRemovedFile*(absoluteOutputPath: string) =
  ## Remove a file that was present in the previous generation but is
  ## absent from the current plan. Called by the pipeline when the
  ## diff identifies a `removed` file. The function never raises if
  ## the file is already absent (intent and reality already agree).
  if not fileExists(absoluteOutputPath) and
     not symlinkExists(absoluteOutputPath):
    return
  try:
    removeFile(absoluteOutputPath)
  except OSError as err:
    raiseMaterializeFailed(absoluteOutputPath,
      "could not remove generated file: " & err.msg)
