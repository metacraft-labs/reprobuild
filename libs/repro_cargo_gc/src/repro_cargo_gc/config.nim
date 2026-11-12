## Where the janitor's thresholds come from.
##
## Two knobs, both PROVISIONAL (the defaults are a conservative suggestion
## pending tuning against real workloads):
##
##   keep sets   how many recent live sets protect their units   (default 3)
##   min age     how long a no-longer-live unit survives          (default 14d)
##
## Precedence, highest first, the same shape as the other user-level settings
## (`certificate_store.certificateStoreRetention`):
##
##   1. a flag               --keep-sets N        --min-age 14d
##   2. the environment      REPRO_CARGO_GC_KEEP_SETS   REPRO_CARGO_GC_MIN_AGE
##   3. the user config      [cargo_gc] keep_sets = 3 / min_age = "14d" in
##                           $XDG_CONFIG_HOME/reprobuild/config.toml (else
##                           $HOME/.config/reprobuild/config.toml)
##   4. the defaults
##
## A malformed value is reported and the next source is used: a janitor that
## cannot read its setting must not guess a more aggressive one.

import std/[os, strutils, tables]
import toml_serialization
import toml_serialization/types as toml_types
import ./types

type
  EnvReader* = proc (name: string): string {.closure.}

  ResolvedGcConfig* = object
    config*: GcConfig
    keepSource*: ConfigSource
    minAgeSource*: ConfigSource
    problems*: seq[string]

proc parseDuration*(text: string): tuple[ok: bool; seconds: int64] =
  ## `30s`, `90m`, `36h`, `14d`, `2w`, or `0`. A number with no unit is
  ## refused (days or seconds would both be plausible readings).
  let t = text.strip()
  if t == "0": return (true, 0'i64)
  if t.len < 2: return
  let factor =
    case t[^1]
    of 's': 1'i64
    of 'm': 60'i64
    of 'h': 3600'i64
    of 'd': 86400'i64
    of 'w': 7 * 86400'i64
    else: 0'i64
  if factor == 0: return
  try:
    let n = parseBiggestInt(t[0 ..< t.len - 1])
    if n >= 0: return (true, n * factor)
  except ValueError:
    discard

proc parseKeep(text: string): tuple[ok: bool; keep: int] =
  try:
    let n = parseInt(text.strip())
    if n >= 1: return (true, n)
  except ValueError:
    discard

proc userConfigPath*(env: EnvReader): string =
  let xdg = env("XDG_CONFIG_HOME")
  if xdg.len > 0 and xdg.isAbsolute: xdg / "reprobuild" / "config.toml"
  elif env("HOME").len > 0: env("HOME") / ".config" / "reprobuild" / "config.toml"
  else: ""

proc readUserConfig(env: EnvReader; keep, minAge: var string;
                    problems: var seq[string]) =
  let path = userConfigPath(env)
  if path.len == 0 or not fileExists(path): return
  try:
    let root = Toml.decode(readFile(path), TomlValueRef)
    if root.kind notin {TomlKind.Table, TomlKind.InlineTable} or
        not root.tableVal[].hasKey("cargo_gc"): return
    let section = root.tableVal[]["cargo_gc"]
    if section.kind notin {TomlKind.Table, TomlKind.InlineTable}: return
    let t = section.tableVal[]
    if t.hasKey("keep_sets"):
      case t["keep_sets"].kind
      of TomlKind.Int: keep = $t["keep_sets"].intVal
      else: keep = "?"
    if t.hasKey("min_age"):
      case t["min_age"].kind
      of TomlKind.String: minAge = t["min_age"].stringVal
      else: minAge = "?"
  except CatchableError as err:
    problems.add path & ": " & err.msg & "; ignoring the file"

proc resolveGcConfig*(env: EnvReader; flagKeep = ""; flagMinAge = ""):
    ResolvedGcConfig =
  result.config = defaultGcConfig()
  result.keepSource = csDefault
  result.minAgeSource = csDefault
  var fileKeep, fileMinAge: string
  readUserConfig(env, fileKeep, fileMinAge, result.problems)
  # Lowest precedence first; each valid layer overwrites the previous one.
  for (source, label, keepText, ageText) in [
      (csUserConfig, "[cargo_gc] in the user config", fileKeep, fileMinAge),
      (csEnvironment, "$REPRO_CARGO_GC_*", env("REPRO_CARGO_GC_KEEP_SETS"),
        env("REPRO_CARGO_GC_MIN_AGE")),
      (csFlag, "flag", flagKeep, flagMinAge)]:
    if keepText.len > 0:
      let k = parseKeep(keepText)
      if k.ok:
        result.config.keepSets = k.keep
        result.keepSource = source
      else:
        result.problems.add "keep sets from " & label & " is '" & keepText &
          "', not a positive integer; ignored"
    if ageText.len > 0:
      let a = parseDuration(ageText)
      if a.ok:
        result.config.minAgeSeconds = a.seconds
        result.minAgeSource = source
      else:
        result.problems.add "min age from " & label & " is '" & ageText &
          "', not a duration like 30m, 36h, 14d or 0; ignored"

proc describe*(r: ResolvedGcConfig): string =
  "keep-sets=" & $r.config.keepSets & " (" & $r.keepSource & "), min-age=" &
    $r.config.minAgeSeconds & "s (" & $r.minAgeSource & ")"
