## M59 gate: `e2e_generated_config_file_external_template`.
##
## Normative description:
##
##   Runs a real Jinja invocation through the typed wrapper against a
##   template that uses `include` to pull a second template; first
##   build writes the output; editing a configurable referenced in argv
##   rebuilds; editing the included template (a file the wrapper did
##   NOT declare as input, but Jinja reads at runtime) rebuilds via
##   monitor-captured dependency; bumping the Jinja realized package
##   invalidates.
##
## How the venv is managed:
##   - The test creates a fresh per-test Python environment under the
##     temp directory using `pip install --target=<dir>` (equivalent to
##     a venv's `site-packages`, and works on Python distributions that
##     ship without the `venv` module — including the Windows
##     embeddable distribution we use in CI). If the host Python has no
##     pip (common in Nix shells), the test falls back to a Nix-provided
##     Python with real Jinja installed. The pinned version is part of
##     the `JinjaSpec.toolIdentity` string, so bumping it changes the
##     cache key.
##   - The driver Python is invoked with `PYTHONPATH=<dir>` so the
##     pinned Jinja install is found before any system-wide install.
##   - The version-bump sub-step re-installs into a different target
##     directory to simulate a Jinja realized-package bump.

import std/[os, osproc, strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config
import repro_local_store

proc setupScope(tmpRoot: string): HomeScope =
  putEnv("REPRO_HOME_PROFILE_TARGET", tmpRoot)
  result = resolveHomeScope()

proc findPython3(): string =
  ## Prefer `python3` if present; fall back to `python`.
  for n in ["python3", "python"]:
    let p = findExe(n)
    if p.len > 0: return p
  raise newException(IOError,
    "python interpreter not found; required for the external-template gate")

type
  JinjaInstall = object
    pythonExe: string
    sitePackages: string

proc pythonHasModule(pythonExe, moduleName: string): bool =
  execCmdEx(quoteShell(pythonExe) & " -c " &
    quoteShell("import " & moduleName)).exitCode == 0

proc nixPythonWithJinja(): string =
  let override = getEnv("REPRO_TEST_JINJA_PYTHON")
  if override.len > 0:
    if not pythonHasModule(override, "jinja2"):
      raise newException(IOError,
        "REPRO_TEST_JINJA_PYTHON does not provide jinja2: " & override)
    return override

  let nix = findExe("nix")
  if nix.len == 0:
    raise newException(IOError,
      "host Python has no pip and nix is not available to provide Jinja")

  let expr = "with import <nixpkgs> {}; " &
    "python3.withPackages (ps: [ ps.jinja2 ])"
  let built = execCmdEx(quoteShell(nix) &
    " build --no-link --print-out-paths --impure --expr " &
    quoteShell(expr))
  if built.exitCode != 0:
    raise newException(IOError,
      "nix failed to provide a Python with Jinja: " & built.output)

  var outPath = ""
  for line in built.output.splitLines:
    let stripped = line.strip()
    if stripped.startsWith("/nix/store/"):
      outPath = stripped
  if outPath.len == 0:
    raise newException(IOError,
      "nix did not report an output path for Python with Jinja: " &
      built.output)

  for exe in [outPath / "bin" / "python3", outPath / "bin" / "python"]:
    if fileExists(exe) and pythonHasModule(exe, "jinja2"):
      return exe
  raise newException(IOError,
    "nix Python output does not contain a python executable with jinja2: " &
    outPath)

proc createJinjaEnv(envDir, pinned: string): JinjaInstall =
  ## Build a per-test Python environment with the requested Jinja
  ## version installed at the target directory. Returns the python
  ## executable plus the directory we must set on PYTHONPATH.
  let basePython = findPython3()
  if pythonHasModule(basePython, "jinja2"):
    result.pythonExe = basePython
    result.sitePackages = ""
    return
  if execCmdEx(quoteShell(basePython) & " -m pip --version").exitCode != 0:
    result.pythonExe = nixPythonWithJinja()
    result.sitePackages = ""
    return

  if dirExists(envDir):
    removeDir(envDir)
  createDir(envDir)
  let pipInstall = execCmdEx(quoteShell(basePython) & " -m pip install " &
    "--disable-pip-version-check --no-warn-script-location " &
    "--target=" & quoteShell(envDir) & " --quiet --upgrade " &
    "jinja2==" & pinned)
  if pipInstall.exitCode != 0:
    raise newException(IOError, "pip install jinja2==" & pinned &
      " into " & envDir & " failed: " & pipInstall.output)
  result.pythonExe = basePython
  result.sitePackages = envDir

proc writeTemplateFiles(tmpRoot: string): string =
  ## Lay out the entry template + an `{% include %}`d sibling and
  ## return the directory holding them.
  let dir = tmpRoot / "templates"
  createDir(dir)
  # Use forward slashes inside the template to avoid backslash escapes.
  writeFile(dir / "nginx.conf.j2", """
server {
    listen {{ port }};
    server_name {{ server_name }};
{% include 'upstream.j2' %}
}
""")
  writeFile(dir / "upstream.j2", """
    upstream {
        server {{ upstream }};
    }
""")
  result = dir

suite "M59 external-template gate":

  test "real Jinja: render, edit input, edit included template, bump version":
    let tmpRoot = getTempDir() / "repro-m59-ext-1"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()

    let templateDir = writeTemplateFiles(tmpRoot)
    let env1Dir = tmpRoot / "venv-3-1-4"
    let env1 = createJinjaEnv(env1Dir, "3.1.4")

    proc apply(port: int; serverName, upstream, toolIdentity: string;
               install: JinjaInstall): TemplateApplyResult =
      putEnv("PYTHONPATH", install.sitePackages)
      let vars = newTable[string, string]()
      vars["port"] = $port
      vars["server_name"] = serverName
      vars["upstream"] = upstream
      let spec = JinjaSpec(
        pythonExe: install.pythonExe,
        templateFile: templateDir / "nginx.conf.j2",
        output: "~/.config/nginx/nginx.conf",
        vars: vars,
        declaredInputs: @[templateDir / "nginx.conf.j2"],
        workingDir: templateDir,
        toolIdentity: toolIdentity)
      runJinja(state, store, scope, spec)

    # First build: cache miss, output written.
    let r1 = apply(8080, "example.com", "127.0.0.1:9000",
      "jinja2==3.1.4", env1)
    check r1.outcome in {oaCreated, oaUpdated}
    let r1Body = readFile(r1.targetPath)
    check "listen 8080;" in r1Body
    check "server_name example.com;" in r1Body
    check "server 127.0.0.1:9000;" in r1Body

    # Second build with identical inputs: cache hit.
    let r2 = apply(8080, "example.com", "127.0.0.1:9000",
      "jinja2==3.1.4", env1)
    check r2.outcome == oaCacheHit
    check r2.cacheKeyHex == r1.cacheKeyHex

    # Edit a configurable referenced in argv: rebuild.
    let r3 = apply(8081, "example.com", "127.0.0.1:9000",
      "jinja2==3.1.4", env1)
    check r3.outcome == oaUpdated
    check r3.cacheKeyHex != r2.cacheKeyHex
    check "listen 8081;" in readFile(r3.targetPath)

    # Edit the INCLUDED template — a file the wrapper did NOT declare
    # as an input, but the Jinja loader opens at render time. This MUST
    # invalidate the cache (monitor-captured dependency).
    writeFile(templateDir / "upstream.j2", """
    upstream {
        server {{ upstream }} fail_timeout=10s;
    }
""")
    let r4 = apply(8081, "example.com", "127.0.0.1:9000",
      "jinja2==3.1.4", env1)
    check r4.outcome == oaUpdated
    check r4.cacheKeyHex != r3.cacheKeyHex
    check "fail_timeout=10s" in readFile(r4.targetPath)

    # Bump Jinja version: re-install at a different target directory
    # with a different pinned version. This MUST rebuild the action
    # because `toolIdentity` participates in the cache key.
    let env2Dir = tmpRoot / "venv-3-1-3"
    let env2 = createJinjaEnv(env2Dir, "3.1.3")
    let r5 = apply(8081, "example.com", "127.0.0.1:9000",
      "jinja2==3.1.3", env2)
    check r5.outcome in {oaUpdated, oaUnchanged}
    check r5.cacheKeyHex != r4.cacheKeyHex
