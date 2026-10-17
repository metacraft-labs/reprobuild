## Shared helpers for the gates that compare the Nix helper library
## (`nix/lib`, exported by the flake as `reprobuild.lib`) with what
## Reprobuild itself does: `t_e2e_nix_reads_data_like_profile.nim` and
## `t_e2e_nix_reads_intent_like_export.nim`.
##
## The Nix side is evaluated by the REAL `nix` (`nix eval --json --impure`),
## importing this checkout's `nix/lib` directly -- the same files the flake
## exports, without copying the whole checkout into the store for each
## evaluation. The arguments travel through a JSON file, so no value is ever
## spliced into Nix source as text.
##
## Processes are spawned from argv, never through a shell.

import std/[json, os, strutils, tempfiles]

import repro_test_support

const NixLibProjectRoot = currentSourcePath().parentDir().parentDir().
  parentDir().parentDir()

proc nixPath*(path: string): string =
  ## A Nix expression for the absolute filesystem path `path`, valid for any
  ## characters it contains.
  "(/. + " & escapeJson(path) & ")"

proc nixLibExpr*(): string =
  ## The helper library as the flake builds it, minus the catalogs (these
  ## gates do not resolve realizations).
  "(import " & nixPath(NixLibProjectRoot / "nix" / "lib") & " { })"

proc nixEvalJson*(body: string; args: JsonNode): JsonNode =
  ## Evaluate `body`, a Nix function of one argument, applied to `args`, and
  ## return its value as JSON. Raises with nix's stderr when the evaluation
  ## fails.
  let (argsFile, argsPath) = createTempFile("gm5-nix-args-", ".json")
  argsFile.write($args)
  argsFile.close()
  defer: removeFile(argsPath)
  let expr = "(" & body & ") (builtins.fromJSON (builtins.readFile " &
    nixPath(argsPath) & "))"
  let res = runProgramSplit("nix", ["eval", "--json", "--impure",
    "--extra-experimental-features", "nix-command flakes", "--expr", expr])
  if res.code != 0:
    raise newException(OSError, "nix eval failed (exit " & $res.code &
      "):\n" & res.stderr & "\nexpression:\n" & expr)
  parseJson(res.stdout)
