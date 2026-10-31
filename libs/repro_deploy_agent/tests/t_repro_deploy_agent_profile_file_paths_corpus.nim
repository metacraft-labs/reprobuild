## The RDMF v3 bundle-path rules, held to the corpus the producer uses.
##
## Governing spec: ``reprobuild-pm/spec/Deploy-Agent.md`` §Strictness and
## §"Field semantics" (`profileFiles`), and §"Implementations and
## conformance": the Nim agent and the Python producer in infra are two
## implementations of one format, and a rule they disagree on is a manifest
## one side emits and the other refuses. The producer's validator
## (`infra/services/repro-deploy-manifest/render-deploy-manifest.py`,
## `profile_file_path_error` / `validate_profile_files`) is fed the corpus
## `infra/services/repro-deploy-manifest/profile-file-paths.corpus` by
## `infra/tests/unit/test-deploy-manifest.sh` case 16. This test feeds a
## VERBATIM copy of that corpus to the Nim side.
##
## The copy is `fixtures/profile-file-paths.corpus`, taken from infra branch
## `feat/rpi2-addon-host` at `c2e2fe66`, SHA-256
## `CorpusSha256` below. The first case asserts the copy still has that
## digest, so a change to either copy without the other is a red test here
## (and, with the same digest recorded on the infra side, there).
##
## Corpus format (from its header): one case per TAB-separated line —
## `ok <path>` / `bad <path>` judge one path alone; `setok` / `setbad`
## judge a set whose members are each valid alone. Escapes: `\t`, `\0`,
## `\\`; the field `<empty>` is the empty string. Blank and `#` lines are
## ignored. No mocks: the real validator, the real file.

import std/[os, strutils, unittest]

import repro_deploy_agent
import nimcrypto/[hash, sha2]

const
  CorpusPath = currentSourcePath.parentDir / "fixtures" /
    "profile-file-paths.corpus"
  CorpusSha256 = "3f0506e9d0e83b12e462f2ab1137acfc9b07a266420b5b0b69e59d9c5fa5e02d"

proc unescapeField(raw: string): string =
  if raw == "<empty>":
    return ""
  var i = 0
  while i < raw.len:
    if raw[i] == '\\' and i + 1 < raw.len:
      case raw[i + 1]
      of 't': result.add('\t')
      of '0': result.add('\0')
      of '\\': result.add('\\')
      else:
        result.add(raw[i]); result.add(raw[i + 1])
      i += 2
    else:
      result.add(raw[i])
      inc i

proc setVerdict(paths: seq[string]): string =
  ## "" when the set is accepted, else the refusal.
  var files: seq[ProfileFile]
  for p in paths:
    files.add(ProfileFile(path: p, content: "x"))
  try:
    validateProfileFiles(files)
    ""
  except DeployManifestCodecError as e:
    e.msg

suite "RDMF v3 bundle paths: the shared corpus":
  test "the fixture is the verbatim copy the header names":
    check fileExists(CorpusPath)
    let digest = toLowerAscii($sha256.digest(readFile(CorpusPath)))
    checkpoint "fixture sha256: " & digest
    check digest == CorpusSha256

  test "every corpus verdict is the Nim validator's verdict":
    var cases = 0
    for rawLine in readFile(CorpusPath).splitLines():
      let line = rawLine
      if line.strip().len == 0 or line.strip().startsWith("#"):
        continue
      let fields = line.split('\t')
      check fields.len >= 2
      let kind = fields[0]
      var paths: seq[string]
      for f in fields[1 .. ^1]:
        paths.add(unescapeField(f))
      inc cases
      case kind
      of "ok":
        check paths.len == 1
        checkpoint "ok: " & paths[0].escape()
        check profileFilePathError(paths[0]) == ""
        check setVerdict(paths) == ""
      of "bad":
        check paths.len == 1
        checkpoint "bad: " & paths[0].escape()
        check profileFilePathError(paths[0]) != ""
        check setVerdict(paths) != ""
      of "setok":
        checkpoint "setok: " & $paths
        for p in paths:
          check profileFilePathError(p) == ""
        check setVerdict(paths) == ""
      of "setbad":
        checkpoint "setbad: " & $paths
        for p in paths:
          check profileFilePathError(p) == ""
        check setVerdict(paths) != ""
      else:
        checkpoint "unknown corpus kind: " & kind
        check false
    # The copy at the recorded digest holds 29 cases; a different count is a
    # truncated read or a corpus the digest check above already refused.
    check cases == 29
