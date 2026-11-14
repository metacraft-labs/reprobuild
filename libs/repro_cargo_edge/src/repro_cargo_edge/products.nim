## Final products of a cargo build, discovered from cargo's own JSON.
##
## A build tool that decides where its products go is asked, never predicted
## (Build-Engine-And-Scheduler.md, "Outputs a delegated build decides"). For
## cargo the answer is `--message-format=json`: one `compiler-artifact`
## message per unit, whose `executable` names an executable's final path and
## whose `filenames` name a library's outputs
## (https://doc.rust-lang.org/cargo/reference/external-tools.html#json-messages).
##
## FINAL means what leaves the build: the executables of the project's own
## packages (binaries and, for `cargo test --no-run`, test executables) and
## their `cdylib`, `dylib` and `staticlib` outputs. Registry and git
## dependencies, proc-macros, build scripts and the `rlib` intermediates are
## cargo's own business and live in the target directory, which is a
## tool-owned cache and not an output.

import std/[algorithm, json, strutils]

type
  CargoProducts* = object
    ## Feed it cargo's stdout line by line, then read `paths`.
    products: seq[string]
    units*: int            ## compiler-artifact messages seen
    freshUnits*: int       ## of which cargo reused (`"fresh": true`)
    skippedLines*: int     ## lines that were not cargo JSON messages
    includeRlibs*: bool    ## also report `rlib`s of the project's own crates

func isOwnPackage(packageId: string): bool =
  ## A package of the project itself (a path dependency or workspace member),
  ## as opposed to a registry or git dependency. Both spellings of the id
  ## start with the source kind (`path+file://...`, `registry+https://...`).
  packageId.startsWith("path+")

func addUnique(products: var seq[string]; path: string) =
  if path.len > 0 and path notin products:
    products.add path

proc feedLine*(p: var CargoProducts; line: string): bool {.discardable.} =
  ## Returns whether `line` was a cargo JSON message (a JSON object with a
  ## `reason`), so that a caller can pass everything else through. Anything
  ## else (rendered diagnostics, build script chatter, a test binary's output)
  ## is counted and ignored here.
  let text = line.strip()
  if text.len == 0 or text[0] != '{':
    if text.len > 0: inc p.skippedLines
    return false
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    inc p.skippedLines
    return false
  if node.kind != JObject or not node.hasKey("reason"):
    inc p.skippedLines
    return false
  result = true
  if node{"reason"}.getStr != "compiler-artifact":
    return
  inc p.units
  if node{"fresh"}.getBool:
    inc p.freshUnits
  if not isOwnPackage(node{"package_id"}.getStr):
    return
  var kinds: seq[string]
  let target = node{"target"}
  if not target.isNil and target.kind == JObject:
    for k in target{"kind"}: kinds.add k.getStr
  if "custom-build" in kinds or "proc-macro" in kinds:
    return
  if node{"executable"}.kind == JString:
    p.products.addUnique node{"executable"}.getStr
  for f in node{"filenames"}:
    let path = f.getStr
    let isFinalLibrary =
      path.endsWith(".so") or path.endsWith(".dylib") or
      path.endsWith(".dll") or path.endsWith(".a") or path.endsWith(".lib") or
      ".so." in path
    let wanted =
      ("cdylib" in kinds or "dylib" in kinds or "staticlib" in kinds) and
        isFinalLibrary
    let rlib = p.includeRlibs and path.endsWith(".rlib")
    if wanted or rlib:
      p.products.addUnique path

func paths*(p: CargoProducts): seq[string] =
  ## The products, sorted so that the answer does not depend on the order
  ## cargo scheduled its units in.
  result = p.products
  result.sort()

proc productsOf*(lines: openArray[string]; includeRlibs = false):
    CargoProducts =
  result.includeRlibs = includeRlibs
  for line in lines: result.feedLine line

func relativeTo*(path, base: string): string =
  ## `path` below `base` with `/` separators, else `path` unchanged.
  let slashed = path.replace('\\', '/')
  let prefix = base.replace('\\', '/').strip(chars = {'/'}, leading = false) & "/"
  if prefix.len > 1 and slashed.startsWith(prefix): slashed[prefix.len .. ^1]
  else: slashed

const FragmentHeader* = "repro-dynamic-graph-v1"

func renderOutputFragment*(actionId: string; outputs: openArray[string]):
    string =
  ## The dynamic-graph fragment that declares `outputs` as obligatory outputs
  ## of `actionId` (`output<TAB>action<TAB>path` records, the format the
  ## delegated-build conventions write). A path that cannot be written in
  ## that format is an error, never a silently altered path.
  result = FragmentHeader & "\n"
  for output in outputs:
    if '\t' in output or '\n' in output or '\r' in output:
      raise newException(ValueError,
        "output cannot be represented in a dynamic graph: " & output)
    result.add "output\t" & actionId & "\t" & output.replace('\\', '/') & "\n"
