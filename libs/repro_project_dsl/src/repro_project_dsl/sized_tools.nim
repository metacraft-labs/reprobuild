## The width of an action that starts a parallel tool.
##
## A build tool that runs its own children in parallel (cargo and the rustc
## processes under it, a Nim compile and the C compilers it starts, make,
## ninja, cmake --build, meson compile, a test binary's worker threads) is a
## process tree, not one process. An edge for it that asks for the one-slot
## default is admitted as one slot and then uses every core the tool finds, so
## moving a project onto Reprobuild would not bound it.
##
## So the standard library's typed tools are SIZED: the edge a typed call
## records asks RunQuota for a width RANGE and names the flag through which the
## tool takes its parallelism. The engine writes the GRANTED width after that
## flag when the lease is granted (``repro_runquota.applyGrantedWidth``), so
## the tool runs exactly as wide as RunQuota allows and not as wide as the
## host is.
##
## WHY A FLAG AND NOT A JOBSERVER. Every tool in the table below is either the
## jobserver of its own children (cargo, make, ninja, cmake --build and meson
## compile hand their children a jobserver sized by the flag, so a build
## script's ``make`` or ``cc`` stays inside the width too) or has none to
## follow (a Nim compile takes ``--parallelBuild:N``, a test binary
## ``--test-threads N``). Given the width as a flag, none of them needs the
## engine to serve tokens as well, and a launched tool that cannot be
## reconfigured is not an action of this table. RunQuota's own jobserver
## (``runquota jobserver``) serves the commands that cannot take a flag; an
## action's own tree reaches it through ``RUNQUOTA_PARENT_LEASE``.
##
## WHERE THE NUMBERS COME FROM. The minimum is one slot: the edge can always
## run narrow. The preferred width is a fixed ``SizedPreferredSlots`` until the
## learned peak of the edge's command shape is served by the daemon (RunQuota
## protocol, CPU profiles); RunQuota grants the widest free width in the range,
## never above its budget, so a preferred width above the host only means "as
## wide as is free".
##
## The width is not what the action is: it never changes what the tool writes.
## It is not part of the engine's action key (``BuildAction.cpuMinMilli``); the
## payload that carries it is, so a change to this table re-runs the sized
## edges once.

# A leaf on purpose: ``runtime_core`` is an include file of the umbrella
# module, so this module cannot name its types. It takes the call's identity
# as plain strings.

const
  SizedMinMilli* = 1000'u32
    ## One slot: a sized edge can always run, narrowly.

  SizedPreferredSlots* = 64'u32
    ## The fixed preferred width of a sized edge, in whole slots.

  SizedPreferredMilli* = SizedPreferredSlots * 1000'u32

type
  SizedWidth* = object
    ## ``flag`` is empty for an unsized call.
    minMilli*: uint32
    preferredMilli*: uint32
    flag*: string

func sized(flag: string): SizedWidth =
  SizedWidth(minMilli: SizedMinMilli, preferredMilli: SizedPreferredMilli,
    flag: flag)

func sizedWidthFor*(packageName, executableName, subcommand: string;
                    argumentNames: openArray[string]): SizedWidth =
  ## The width range and flag of the edge that a typed call records, or the
  ## zero value (no flag, no range: the one-slot default) for a call that
  ## starts a single process. `argumentNames` are the names of the arguments
  ## the call supplied a value for.
  ##
  ## Keyed on the typed tool's package, its executable's binary name and the
  ## subcommand, because those are what the generated wrappers stamp on every
  ## call (``publicCliCall(pkg.packageName, exe.binaryName, cmd.name, ...)``).
  ## A value the call already gives the flag is kept by the engine when it is
  ## within the grant and lowered to the grant otherwise.
  case packageName
  of "cargo":
    if executableName == "cargo":
      # ``-j`` is cargo's own width. cargo serves the jobserver of its rustc
      # processes and build scripts, so one flag bounds the tree.
      if subcommand in ["build", "install", "test"]:
        return sized("-j")
    elif executableName == "cargo-test-binary" and subcommand == "run":
      # The test-binary edge is a libtest process: its width is its worker
      # threads.
      return sized("--test-threads")
  of "nim":
    if executableName == "nim" and subcommand in ["c", "cpp", "objc"]:
      # The C backend: one C compiler process per module, N at a time.
      return sized("--parallelBuild:")
  of "ninja":
    # `ninja -t <tool>` runs one of ninja's own subtools, not a build.
    if executableName == "ninjaBin" and "tool" notin argumentNames:
      return sized("-j")
  of "make":
    if executableName == "makeBin":
      return sized("-j")
  of "cmake":
    if executableName == "cmakeBin" and subcommand == "build":
      # A recipe that spelled its width as `--parallel N` keeps that
      # spelling, so the grant replaces its value instead of arriving as a
      # second, competing flag.
      return sized(if "parallel" in argumentNames: "--parallel" else: "-j")
  of "meson":
    if executableName == "mesonBin" and subcommand == "compile":
      return sized("-j")
  else:
    discard
