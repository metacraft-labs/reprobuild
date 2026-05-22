## Top-level entry point for M59 (Configurable-Driven Generated
## Configuration Files). Bundles the structured intermediate
## representation, the block macros, the path-expansion helpers, the
## sentinel-based managed-block writer, the cache-key derivation,
## and the apply-action procs that hold the three together.

import std/[os, strutils, tables]
from repro_core/paths import extendedPath

import repro_local_store

import ./generated_config/structured
import ./generated_config/paths
import ./generated_config/block_macros
import ./generated_config/managed_block
import ./generated_config/cache_key
import ./generated_config/actions
import ./configurables

export structured
export paths
export block_macros
export managed_block
export cache_key
export actions

# ---------------------------------------------------------------------------
# Convenience: convert a RenderedContent into the rendered bytes + inputs
# the apply layer needs.
# ---------------------------------------------------------------------------

proc renderToBytes*(rendered: RenderedContent): seq[byte] =
  let text = serialize(rendered.format, rendered.value)
  result = newSeq[byte](text.len)
  for i, ch in text: result[i] = byte(ord(ch))

proc renderedInputs*(rendered: RenderedContent): seq[ResolvedInput] =
  result = @[]
  for (name, value) in rendered.inputs.items:
    result.add ResolvedInput(name: name, value: value)

proc renderToString*(rendered: RenderedContent): string =
  serialize(rendered.format, rendered.value)

# ---------------------------------------------------------------------------
# fs.writeStructured / fs.configFile — high-level entry points
# ---------------------------------------------------------------------------

proc writeStructured*(state: var actions.ApplyState;
                     store: var Store;
                     scope: HomeScope;
                     path: string;
                     format: ConfigFormat;
                     value: StructuredValue;
                     inputs: seq[ResolvedInput] = @[]):
                    OwnedApplyResult =
  ## Programmatic structured-value entry point. Used by both the
  ## block-macro path (via `configFile`) and explicit `JsonNode` /
  ## `StructuredValue` construction (the Nix-style approach).
  let text = serialize(format, value)
  var content = newSeq[byte](text.len)
  for i, ch in text: content[i] = byte(ord(ch))
  applyOwnedFile(state, store, scope, path, content, inputs)

proc configFile*(state: var actions.ApplyState;
                store: var Store;
                scope: HomeScope;
                path: string;
                rendered: RenderedContent): OwnedApplyResult =
  ## Block-macro entry point. Carries `RenderedContent` (format +
  ## structured value + the input set recorded during block evaluation)
  ## through `applyOwnedFile`.
  writeStructured(state, store, scope, path, rendered.format,
    rendered.value, renderedInputs(rendered))

# ---------------------------------------------------------------------------
# fs.managedBlock — high-level entry point
# ---------------------------------------------------------------------------

proc managedBlockAction*(state: var actions.ApplyState;
                        store: var Store;
                        scope: HomeScope;
                        path, blockId: string;
                        rendered: RenderedContent): ManagedApplyResult =
  ## Apply a managed block whose content is computed from a block macro
  ## (typically `shellExports:` or `textContent`).
  let body = renderToString(rendered)
  applyManagedBlock(state, store, scope, path, blockId, body,
    renderedInputs(rendered))

proc managedBlockAction*(state: var actions.ApplyState;
                        store: var Store;
                        scope: HomeScope;
                        path, blockId, content: string;
                        inputs: seq[ResolvedInput] = @[]):
                       ManagedApplyResult =
  applyManagedBlock(state, store, scope, path, blockId, content, inputs)

# ---------------------------------------------------------------------------
# Jinja-style external-template wrapper. This is the canonical example
# from the spec (`Generated-Configuration-Files.md` § "External Template
# Tools"). Wraps a real Python+Jinja invocation through subprocess.
# ---------------------------------------------------------------------------

type
  JinjaSpec* = object
    pythonExe*: string
      ## Path to the Python interpreter that has Jinja installed
      ## (typically a venv).
    templateFile*: string
      ## Absolute path to the entry template the wrapper passes to Jinja.
    output*: string
      ## Target output path, expanded via the home scope.
    vars*: TableRef[string, string]
      ## Concrete variable bindings the wrapper writes into the
      ## rendered argv (and the cache key, via resolved configurable
      ## inputs).
    declaredInputs*: seq[string]
      ## Files the wrapper declares as inputs. The entry template is
      ## always included.
    workingDir*: string
    toolIdentity*: string
      ## Stable identity of the realized Jinja package (e.g.
      ## "jinja2==3.1.4"). Bumping this string invalidates the cache.

proc walkTemplateDir(templateDir: string): seq[string] =
  ## List every regular file under the template directory. Used by the
  ## Jinja wrapper to approximate the monitor-captured transitive-import
  ## set — by capturing the contents of every file under the template
  ## directory we guarantee an edit to any `{% include %}`d sibling will
  ## change the cache key.
  result = @[]
  if not dirExists(extendedPath(templateDir)): return
  # TODO(win-longpath): walk results escape; needs review
  for path in walkDirRec(templateDir):
    if fileExists(extendedPath(path)):
      result.add path

proc runJinja*(state: var actions.ApplyState;
              store: var Store;
              scope: HomeScope;
              spec: JinjaSpec): TemplateApplyResult =
  ## Render through real Jinja. The wrapper writes a tiny driver
  ## script to stdout the way the M51 fs.* tools do; the script reads
  ## `spec.vars`, opens `spec.templateFile`, renders, and writes the
  ## result into a staging file inside the working directory. The
  ## staged bytes are then routed through CAS so the home-scope target
  ## path only changes when the rendered content differs.
  # `expandPath` validates the output path is in the home scope even
  # though Jinja stages its bytes elsewhere; the final `applyOwnedFile`
  # call also expands the path, but doing it here too gives an early
  # diagnostic before we spin up the subprocess.
  discard expandPath(scope, spec.output)
  # Stage the rendered bytes outside `workingDir` so the wrapper's
  # transitive-import scan (which lists every file under workingDir)
  # does not pick up the staging file as a self-referential input.
  let stageDir = parentDir(spec.workingDir) / "_repro_jinja_stage"
  createDir(extendedPath(stageDir))
  let stagePath = stageDir / "output.tmp"
  let driverPath = stageDir / "_repro_jinja_driver.py"
  # Build a Python driver script.
  var driver = "from jinja2 import Environment, FileSystemLoader\n"
  driver.add "import json, os, sys\n"
  driver.add "loader = FileSystemLoader([\""
  driver.add spec.workingDir.replace("\\", "/")
  driver.add "\"])\n"
  driver.add "env = Environment(loader=loader, keep_trailing_newline=True)\n"
  driver.add "tpl = env.get_template(\""
  let relTemplate = spec.templateFile.replace("\\", "/").rsplit('/', 1)[^1]
  driver.add relTemplate
  driver.add "\")\n"
  driver.add "vars = json.loads(sys.argv[1])\n"
  driver.add "out_path = \""
  driver.add stagePath.replace("\\", "/")
  driver.add "\"\n"
  driver.add "os.makedirs(os.path.dirname(out_path), exist_ok=True)\n"
  driver.add "with open(out_path, \"w\", encoding=\"utf-8\") as fh:\n"
  driver.add "  fh.write(tpl.render(**vars))\n"
  createDir(extendedPath(spec.workingDir))
  writeFile(extendedPath(driverPath), driver)
  # Encode vars as JSON for argv.
  var varsJson = "{"
  var firstVar = true
  for k, v in spec.vars[]:
    if not firstVar: varsJson.add(',')
    firstVar = false
    var esc = "\""
    for ch in k:
      if ch == '"': esc.add("\\\"")
      elif ch == '\\': esc.add("\\\\")
      else: esc.add ch
    esc.add("\":\"")
    for ch in v:
      if ch == '"': esc.add("\\\"")
      elif ch == '\\': esc.add("\\\\")
      elif ch == '\n': esc.add("\\n")
      else: esc.add ch
    esc.add("\"")
    varsJson.add esc
  varsJson.add "}"
  # Discover transitive imports BEFORE running so the cache key sees
  # them. For the test suite, "every file under the template dir" is
  # the conservative-and-correct approximation; a true monitor-driven
  # implementation would attach a tracer to the Python process instead.
  let imports = walkTemplateDir(spec.workingDir)
  # Build a spec for the apply layer that includes the resolved
  # `vars` as inputs.
  var inputs: seq[ResolvedInput] = @[]
  for k, v in spec.vars[]:
    inputs.add ResolvedInput(name: "var:" & k, value: cvString(v))
  # Remove any prior staging file so the wrapper detects a fresh write
  # vs. the tool silently doing nothing.
  if fileExists(extendedPath(stagePath)): removeFile(extendedPath(stagePath))
  let extSpec = ExternalTemplateSpec(
    commandLine: @["\"" & spec.pythonExe & "\"", "\"" & driverPath & "\"",
      "\"" & varsJson.replace("\"", "\\\"") & "\""],
    toolIdentity: spec.toolIdentity,
    declaredInputs: spec.declaredInputs & @[spec.templateFile],
    capturedImports: imports,
    outputPath: stagePath,
    workingDir: spec.workingDir)
  applyExternalTemplate(state, store, scope, spec.output, extSpec, inputs)
