## The thin cargo edge: run one cargo invocation, learn its final products
## from cargo's JSON messages, and say what they are.
##
## Cargo stays the build system. The target directory is cargo's own
## incremental state, a TOOL-OWNED CACHE that the edge neither declares as an
## output nor clears (Tool-Owned-Caches.md): a build that wiped it before each
## run would recompile every unit, which is the cost of declaring it opaque.
## What the edge declares is the small thing cargo can answer: the final
## products, read from `--message-format=json` after the build, never
## predicted from cargo's naming rules (Build-Engine-And-Scheduler.md,
## "Outputs a delegated build decides").
##
## WIDTH. cargo is the jobserver of its own rustc and build-script processes,
## sized by `-j`. The edge passes the width it is given as `-j` and does not
## serve tokens of its own (Build-Engine-And-Scheduler.md, Integration tiers,
## Cargo, records why).
##
## OUTPUT. cargo's JSON goes to the edge, not to the terminal; its rendered
## diagnostics and progress stay on stderr, which `--message-format=
## json-render-diagnostics` keeps for cargo to render. A line of stdout that
## is not JSON (a test binary's output, a build script's chatter) is passed
## through to stdout unchanged.

import std/[os, strutils]
when defined(posix):
  import std/posix
else:
  # `readLine(Stream, var string)` on `Process.outputStream` lives in
  # std/streams, which std/osproc does not re-export.
  import std/[osproc, streams]
import ./products

type
  CargoEdgeOptions* = object
    cargo*: seq[string]
      ## The cargo command: program, then its arguments (`cargo build ...`).
    width*: int
      ## Passed to cargo as `-j`; 0 leaves cargo's own default.
    productsFile*: string
      ## Where the final products are listed (one path per line). Empty: not
      ## written.
    fragmentFile*: string
      ## Where the dynamic-graph fragment declaring the products as the
      ## outputs of `actionId` is written. Empty: not written.
    actionId*: string
    relativeTo*: string
      ## Products are written relative to this directory when they are below
      ## it. Empty: as cargo reported them.
    includeRlibs*: bool

  CargoEdgeResult* = object
    exitCode*: int
    products*: seq[string]
    units*: int
    freshUnits*: int

const
  JsonMessageFormat* = "--message-format=json-render-diagnostics"

func subcommandIndex*(cargo: openArray[string]): int =
  ## The position of cargo's subcommand: after the program and an optional
  ## `+toolchain`. -1 when there is none.
  var i = 1
  if i < cargo.len and cargo[i].startsWith("+"): inc i
  while i < cargo.len and cargo[i].startsWith("-") and
      cargo[i] notin ["--"]:
    # A global option before the subcommand. Options that take a separate
    # value (`-C dir`, `--config x`) are the cases that need the pair.
    if cargo[i] in ["-C", "--config", "--color", "-Z"]: i += 2 else: inc i
  if i < cargo.len and not cargo[i].startsWith("-"): i else: -1

func hasMessageFormat*(cargo: openArray[string]): bool =
  for arg in cargo:
    if arg == "--message-format" or arg.startsWith("--message-format="):
      return true

func messageFormatIsJson*(cargo: openArray[string]): bool =
  ## Whether the message format cargo was given is one of the JSON ones.
  var i = 0
  while i < cargo.len:
    let arg = cargo[i]
    var value = ""
    if arg == "--message-format" and i + 1 < cargo.len:
      value = cargo[i + 1]
    elif arg.startsWith("--message-format="):
      value = arg["--message-format=".len .. ^1]
    if value.len > 0:
      return value.startsWith("json")
    inc i
  false

func withEdgeArguments*(cargo: openArray[string]; width: int): seq[string] =
  ## `cargo` with the message format and the width the edge needs, placed
  ## right after the subcommand so that they are not read as arguments of the
  ## program cargo runs (`cargo run -- args`, `cargo test -- --nocapture`).
  ## An argument the caller already gave is left alone.
  result = @cargo
  let at = subcommandIndex(cargo)
  if at < 0: return
  var inserted: seq[string]
  if not hasMessageFormat(cargo):
    inserted.add JsonMessageFormat
  var hasJobs = false
  for arg in cargo:
    if arg == "--": break
    if arg == "-j" or arg == "--jobs" or arg.startsWith("-j") and
        arg.len > 2 and arg[2 .. ^1].allCharsInSet(Digits) or
        arg.startsWith("--jobs="):
      hasJobs = true
  if width > 0 and not hasJobs:
    inserted.add "-j"
    inserted.add $width
  result = @cargo[0 .. at] & inserted & @cargo[at + 1 .. ^1]

proc writeIfChanged(path, text: string) =
  ## Write only when the content differs: the file is an input of what
  ## consumes it, and a rewrite with the same bytes still moves its change
  ## time (Ninja's `restat`).
  createDir(parentDir(absolutePath(path)))
  if fileExists(path):
    try:
      if readFile(path) == text: return
    except IOError:
      discard
  writeFile(path, text)

proc removeIfPresent(path: string) =
  if path.len > 0 and fileExists(path):
    removeFile(path)

const ProductsHeader* = "repro-cargo-products-v1"

when defined(posix):
  proc runStreaming(command: seq[string]; products: var CargoProducts): int =
    ## Run `command` with its stdout piped to us and everything else
    ## inherited; feed each stdout line to `products` and pass the lines that
    ## are not cargo messages through to stdout.
    var fds: array[2, cint]
    if pipe(fds) != 0:
      stderr.writeLine "repro cargo run: pipe failed: " &
        osErrorMsg(osLastError())
      return 1
    let argv = allocCStringArray(command)
    stdout.flushFile()
    stderr.flushFile()
    let pid = fork()
    if pid < 0:
      stderr.writeLine "repro cargo run: fork failed: " &
        osErrorMsg(osLastError())
      return 1
    if pid == 0:
      discard dup2(fds[1], 1)
      discard close(fds[0])
      discard close(fds[1])
      discard execvp(command[0].cstring, argv)
      let message = "repro cargo run: cannot run " & command[0] & "\n"
      discard write(2, message.cstring, message.len)
      exitnow(127)
    discard close(fds[1])
    var input: File
    if not open(input, FileHandle(fds[0]), fmRead):
      return 1
    var line: string
    while input.readLine(line):
      if not products.feedLine(line) and line.len > 0:
        stdout.writeLine line
    stdout.flushFile()
    input.close()
    var status: cint = 0
    while waitpid(pid, status, 0) < 0:
      if errno != EINTR: return 1
    if WIFSIGNALED(status): 128 + int(WTERMSIG(status))
    else: int(WEXITSTATUS(status))
else:
  proc runStreaming(command: seq[string]; products: var CargoProducts): int =
    ## No pipe-only-stdout spawn here: stderr is merged, so cargo's rendered
    ## diagnostics arrive on the same stream and are passed through.
    let process = startProcess(command[0], args = command[1 .. ^1],
      options = {poUsePath, poStdErrToStdOut})
    var line: string
    let output = process.outputStream
    while output.readLine(line):
      if not products.feedLine(line) and line.len > 0:
        stdout.writeLine line
    result = process.waitForExit()
    process.close()

proc runCargoEdge*(options: CargoEdgeOptions): CargoEdgeResult =
  ## Run cargo and write what the edge declares. On a failed build nothing is
  ## left behind: a previous answer is removed, never kept, so a consumer
  ## cannot read the products of a build that no longer exists.
  if options.cargo.len == 0:
    raise newException(ValueError, "no cargo command given")
  if hasMessageFormat(options.cargo) and not messageFormatIsJson(options.cargo):
    raise newException(ValueError,
      "the edge reads cargo's JSON messages: --message-format must be a " &
      "json format, not the one given")
  var collected: CargoProducts
  collected.includeRlibs = options.includeRlibs
  let command = withEdgeArguments(options.cargo, options.width)
  result.exitCode = runStreaming(command, collected)
  result.units = collected.units
  result.freshUnits = collected.freshUnits
  if result.exitCode != 0:
    removeIfPresent(options.productsFile)
    removeIfPresent(options.fragmentFile)
    return
  var paths: seq[string]
  for product in collected.paths:
    # A product cargo named must exist: an obligation, not a hope.
    if not fileExists(product):
      raise newException(IOError,
        "cargo reported the product " & product & " but it does not exist")
    paths.add(if options.relativeTo.len > 0:
      product.relativeTo(options.relativeTo) else: product)
  result.products = paths
  if options.productsFile.len > 0:
    writeIfChanged(options.productsFile,
      ProductsHeader & "\n" & paths.join("\n") &
        (if paths.len > 0: "\n" else: ""))
  if options.fragmentFile.len > 0:
    if options.actionId.len == 0:
      raise newException(ValueError,
        "a fragment needs the id of the action whose outputs it declares")
    writeIfChanged(options.fragmentFile,
      renderOutputFragment(options.actionId, paths))
