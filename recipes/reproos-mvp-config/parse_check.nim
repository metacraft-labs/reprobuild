## Quick parse-time validation of the D1 MVP config.
## Run with:
##   nim c -r --threads:on --hints:off --warnings:off \
##     recipes/reproos-mvp-config/_parse_check.nim
##
## Verifies the recipes/reproos-mvp-config.nim source passes B1's
## parser without error and surfaces 5 foreign-package entries.

import std/[os, strutils]
import repro_system_apply

const ConfigPath = currentSourcePath().parentDir.parentDir / "reproos-mvp-config.nim"

proc main() =
  let cfg = parseSystemConfigFile(ConfigPath)
  echo "system name: ", cfg.name
  echo "kernel:      ", cfg.kernel.name
  echo "cmdline:     ", cfg.kernelCmdline.parts.join(" ")
  echo "packages:    ", cfg.packages.len
  var foreign = 0
  for p in cfg.packages:
    let tag = $p.tier
    let extra = if p.distro.len > 0:
      " [distro=" & p.distro & " snapshot=" & p.snapshot & "]"
    else: ""
    echo "  - ", p.name, " (", tag, ")", extra
    if p.tier == ptForeignBundle:
      inc foreign
  echo "foreign-bundle count: ", foreign
  echo "users:       ", cfg.users.len
  for u in cfg.users:
    echo "  - ", u.name, " shell=", u.shell
  echo "services:    ", cfg.services.len
  for s in cfg.services:
    echo "  - ", s.unit, " ", $s.state
  echo "mounts:      ", cfg.mounts.len
  for m in cfg.mounts:
    echo "  - ", m.mountPoint, " ", m.source, " ", m.fstype
  if foreign != 5:
    quit("FAIL: expected 5 foreign-bundle packages, got " & $foreign)
  echo "PASS"

when isMainModule:
  main()
