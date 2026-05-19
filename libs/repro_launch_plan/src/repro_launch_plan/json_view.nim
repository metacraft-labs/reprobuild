## Best-effort JSON inspector for `LaunchPlan`. The JSON form is debug
## output only — the canonical persistent form is the RBLP envelope
## emitted by `codec.encodeLaunchPlan`. See the spec §"Serialization".

import std/[strutils]

import ./types

proc esc(text: string): string =
  result = newStringOfCap(text.len)
  for ch in text:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ord(ch) < 0x20:
        result.add("\\u" & toHex(ord(ch), 4))
      else:
        result.add(ch)

proc q(text: string): string = "\"" & esc(text) & "\""

proc strArrayJson(values: openArray[string]): string =
  var parts: seq[string] = @[]
  for v in values: parts.add(q(v))
  "[" & parts.join(",") & "]"

proc envBindingJson(eb: EnvBinding): string =
  "{\"name\":" & q(eb.name) & ",\"kind\":" & q($eb.kind) &
    ",\"value\":" & q(eb.value) & "}"

proc execBindingJson(eb: ExecutableBinding): string =
  "{\"logicalName\":" & q(eb.logicalName) &
    ",\"executablePath\":" & q(eb.executablePath) & "}"

proc envBindingsJson(values: openArray[EnvBinding]): string =
  var parts: seq[string] = @[]
  for v in values: parts.add(envBindingJson(v))
  "[" & parts.join(",") & "]"

proc execBindingsJson(values: openArray[ExecutableBinding]): string =
  var parts: seq[string] = @[]
  for v in values: parts.add(execBindingJson(v))
  "[" & parts.join(",") & "]"

proc launchPlanToJson*(plan: LaunchPlan): string =
  ## Render a stable JSON view. Field order is fixed so `repro launch-plan
  ## show` produces deterministic output for diffing.
  "{" &
    "\"schemaVersion\":" & $plan.schemaVersion &
    ",\"binding\":" & q($plan.binding) &
    ",\"exportedCommand\":" & q(plan.exportedCommand) &
    ",\"realizedPrefix\":" & q(plan.realizedPrefix) &
    ",\"executablePath\":" & q(plan.executablePath) &
    ",\"arguments\":" & strArrayJson(plan.arguments) &
    ",\"hasWorkingDirectory\":" & $plan.hasWorkingDirectory &
    ",\"workingDirectory\":" & q(plan.workingDirectory) &
    ",\"environmentBindings\":" & envBindingsJson(plan.environmentBindings) &
    ",\"executableBindings\":" & execBindingsJson(plan.executableBindings) &
    ",\"runtimeLibraryDirs\":" & strArrayJson(plan.runtimeLibraryDirs) &
    ",\"projectedRuntimeImage\":{\"present\":" &
      $plan.projectedRuntimeImage.present &
      ",\"imageId\":" & q(plan.projectedRuntimeImage.imageId) &
      ",\"relativePath\":" & q(plan.projectedRuntimeImage.relativePath) & "}" &
    ",\"executionProfile\":{\"present\":" &
      $plan.executionProfile.present &
      ",\"requires\":" & $plan.executionProfile.requires &
      ",\"checksumHex\":" & q(plan.executionProfile.checksumHex) & "}" &
    ",\"supportProfile\":{\"platform\":" & q(plan.supportProfile.platform) &
      ",\"arch\":" & q(plan.supportProfile.arch) &
      ",\"abi\":" & q(plan.supportProfile.abi) &
      ",\"osMinVersion\":" & q(plan.supportProfile.osMinVersion) & "}" &
    ",\"provenance\":{\"adapter\":" & q(plan.provenance.adapter) &
      ",\"packageId\":" & q(plan.provenance.packageId) &
      ",\"realizationHashHex\":" & q(plan.provenance.realizationHashHex) & "}" &
    "}"
