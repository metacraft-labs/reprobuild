## D1 P2 helper: parse + lower the MVP ``recipes/reproos-mvp-config.nim``
## via the B1 parser and emit:
##
##   <out>/config.json   — a deterministic JSON dump of the parsed
##                          ``SystemConfig`` (kernel, cmdline, packages,
##                          users, services, mounts).
##   <out>/foreign.list  — TAB-separated ``<name>\t<distro>\t<snapshot>``
##                          one entry per Tier-3 foreign-bundle package.
##                          The bash build driver reads this to drive
##                          the harvest + manifest stages without
##                          re-parsing the .nim source.
##
## Usage:
##   lower_to_json --config <path> --out <json>
##
## Stand-alone Nim helper so the build driver doesn't need to embed
## the parser logic; reusing the existing ``parseSystemConfigFile`` keeps
## D1 honest about consuming B1's surface.

import std/[options, os, strutils]
import repro_system_apply

proc usage(): string =
  """Usage: lower_to_json --config <path> --out <json>

Emits:
  <json>                              the JSON dump of the parsed SystemConfig
  <dir(json)>/foreign.list            one TAB row per foreign-bundle package
"""

proc escJson(s: string): string =
  result = newStringOfCap(s.len + 4)
  for c in s:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    elif c.uint8 < 0x20:
      result.add("\\u00")
      const Hex = "0123456789abcdef"
      result.add(Hex[c.uint8 shr 4])
      result.add(Hex[c.uint8 and 0x0f])
    else:
      result.add(c)

proc dumpConfig(cfg: SystemConfig): string =
  var buf = "{\n"
  buf.add "  \"name\": \"" & escJson(cfg.name) & "\",\n"
  buf.add "  \"sourceFile\": \"" & escJson(cfg.sourceFile) & "\",\n"
  buf.add "  \"kernel\": \"" & escJson(cfg.kernel.name) & "\",\n"
  # Cmdline.
  buf.add "  \"kernel_cmdline\": ["
  for i, p in cfg.kernelCmdline.parts:
    if i > 0: buf.add ", "
    buf.add "\"" & escJson(p) & "\""
  buf.add "],\n"
  # Packages.
  buf.add "  \"packages\": ["
  for i, p in cfg.packages:
    if i > 0: buf.add ", "
    buf.add "{\"name\":\"" & escJson(p.name) &
      "\",\"tier\":\"" & $p.tier &
      "\",\"distro\":\"" & escJson(p.distro) &
      "\",\"snapshot\":\"" & escJson(p.snapshot) & "\"}"
  buf.add "],\n"
  # Users.
  buf.add "  \"users\": ["
  for i, u in cfg.users:
    if i > 0: buf.add ", "
    let uidStr = if u.uid.isSome: $u.uid.get else: ""
    buf.add "{\"name\":\"" & escJson(u.name) &
      "\",\"shell\":\"" & escJson(u.shell) &
      "\",\"home_dir\":\"" & escJson(u.homeDir) &
      "\",\"uid\":\"" & uidStr &
      "\",\"password_hash\":\"" & escJson(u.passwordHash) & "\"}"
  buf.add "],\n"
  # Services.
  buf.add "  \"services\": ["
  for i, s in cfg.services:
    if i > 0: buf.add ", "
    buf.add "{\"unit\":\"" & escJson(s.unit) &
      "\",\"state\":\"" & $s.state & "\"}"
  buf.add "],\n"
  # Mounts.
  buf.add "  \"mounts\": ["
  for i, m in cfg.mounts:
    if i > 0: buf.add ", "
    buf.add "{\"mountPoint\":\"" & escJson(m.mountPoint) &
      "\",\"source\":\"" & escJson(m.source) &
      "\",\"fstype\":\"" & escJson(m.fstype) &
      "\",\"options\":\"" & escJson(m.options.join(",")) & "\"}"
  buf.add "]\n"
  buf.add "}\n"
  buf

proc main() =
  let args = commandLineParams()
  var configPath = ""
  var outPath = ""
  var i = 0
  while i < args.len:
    case args[i]
    of "--config":
      inc i
      if i >= args.len: quit usage()
      configPath = args[i]
    of "--out":
      inc i
      if i >= args.len: quit usage()
      outPath = args[i]
    of "--help", "-h":
      echo usage(); return
    else:
      stderr.writeLine "unknown arg: " & args[i]
      quit usage()
    inc i

  if configPath.len == 0 or outPath.len == 0:
    stderr.writeLine "missing --config or --out"
    quit usage()

  let cfg = parseSystemConfigFile(configPath)

  createDir(parentDir(outPath))
  writeFile(outPath, dumpConfig(cfg))

  # foreign.list — one TAB row per foreign-bundle package.
  let foreignListPath = parentDir(outPath) / "foreign.list"
  var foreignBuf = ""
  for p in cfg.packages:
    if p.tier == ptForeignBundle:
      foreignBuf.add p.name & "\t" & p.distro & "\t" & p.snapshot & "\n"
  writeFile(foreignListPath, foreignBuf)
  echo "wrote ", outPath
  echo "wrote ", foreignListPath

when isMainModule:
  main()
