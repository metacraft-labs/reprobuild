## Setting values read with systemd's own grammar.
##
## A check that branches on a unit setting must read the value as systemd
## does, or a value systemd treats one way is judged another: systemd reads
## ``PermissionsStartOnly=y`` as true and ignores ``ProtectSystem=Strict``
## (its enum values are case-sensitive), keeping the earlier assignment.
##
## Each parser returns a ``SettingRead``:
##
## - ``srValid``: systemd accepts the value; ``value`` is what it means;
## - ``srIgnored``: systemd logs the line and ignores it ("Failed to parse
##   ..., ignoring"), so the setting keeps its earlier assignment (or its
##   default) -- the caller must not change its state;
## - ``srReset``: an empty assignment, which resets the setting to its
##   default.
##
## Sources: systemd ``src/basic/parse-util.c`` ``parse_boolean()``
## (https://github.com/systemd/systemd/blob/v257/src/basic/parse-util.c),
## ``src/core/load-fragment.c`` ``config_parse_bool``/
## ``config_parse_protect_system`` and ``src/shared/conf-parser.c``
## (https://github.com/systemd/systemd/blob/v257/src/core/load-fragment.c),
## ``protect_system_from_string()`` in ``src/core/namespace.c`` (a boolean
## first, then the case-sensitive table ``no yes full strict``).

import std/strutils

const
  ValuesMutation {.strdefine: "reproAddonMutation".} = ""
    ## The falsifying build this is (``repro_addon/mutations``), if any.
  ValuesAsText = ValuesMutation in ["reach-values-as-text",
                                    "reach-values-as-text-without-live-check"]
    ## ``reach-values-as-text`` (falsifying build): round 4's reading --
    ## booleans from ``yes true 1 on`` only (case-insensitive), the enum
    ## lower-cased. ``reach-values-as-text-without-live-check`` reads the
    ## same, and also leaves out a full apply's live cross-check
    ## (``repro_infra/apply``), which would refuse the conversion gate's
    ## probe as systemd loaded it.

type
  SettingRead* = enum
    srValid, srIgnored, srReset

  ProtectSystemMode* = enum
    psNo, psYes, psFull, psStrict

proc parseSystemdBoolean*(raw: string; value: var bool): SettingRead =
  ## ``parse_boolean()``: case-insensitive ``1 yes y true t on`` and
  ## ``0 no n false f off``; anything else is ignored. An empty value is
  ## not a boolean either (``config_parse_bool`` ignores it).
  let v = raw.strip()
  when ValuesAsText:
    if v.toLowerAscii() in ["yes", "true", "1", "on"]:
      value = true
      return srValid
    value = false
    return srValid
  case v.toLowerAscii()
  of "1", "yes", "y", "true", "t", "on":
    value = true
    srValid
  of "0", "no", "n", "false", "f", "off":
    value = false
    srValid
  else:
    srIgnored

proc parseProtectSystem*(raw: string; mode: var ProtectSystemMode): SettingRead =
  ## ``ProtectSystem=``: empty resets to ``no``; a boolean (``yes`` or
  ## ``no``); else exactly ``no``, ``yes``, ``full`` or ``strict``
  ## (case-sensitive); anything else is ignored.
  let v = raw.strip()
  when ValuesAsText:
    mode = if v.toLowerAscii() == "strict": psStrict else: psNo
    return srValid
  if v.len == 0:
    mode = psNo
    return srReset
  var b: bool
  if parseSystemdBoolean(v, b) == srValid:
    mode = if b: psYes else: psNo
    return srValid
  case v
  of "full": mode = psFull
  of "strict": mode = psStrict
  else: return srIgnored
  srValid
