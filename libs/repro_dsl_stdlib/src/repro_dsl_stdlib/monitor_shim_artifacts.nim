## The Windows monitor artefacts that must be staged side by side.
##
## Windows process monitoring needs FOUR files in one directory, not one.
## ``findShimLibrary`` resolves the 64-bit shim at ``<appDir>/../lib/`` — i.e.
## reprobuild's ``build/lib`` — and nim-stackable-hooks' injector then locates
## the other three BY CONVENTION relative to it:
##
##   ``librepro_monitor_shim.dll``        the 64-bit shim (``findShimLibrary``)
##   ``librepro_monitor_shim32.dll``      the 32-bit shim (``wow64ShimPathFor``:
##                                        ``<name>32<ext>`` beside the 64-bit one)
##   ``stackable_hooks_wow64_probe32.exe`` the 32-bit probe (``wow64ProbePathFor``:
##                                        a fixed name in the same directory)
##   ``stackable_hooks_inject64.exe``     the 64-bit inject helper
##                                        (``inject64HelperPathFor``, same
##                                        directory)
##
## Convention, not configuration, is what makes these names load-bearing: no
## code ever reads them from a manifest, so a rename on either side of the
## seam produces no error at all. The injector meets a 32-bit child, finds no
## ``<name>32.dll``, refuses, and the child's whole subtree goes unmonitored —
## an unknown-scope evidence loss that silently makes the action uncacheable.
## A monitoring failure looks exactly like a process with no dependencies.
##
## These constants are therefore the single place reprobuild's recipe spells
## the names, and ``libs/repro_dsl_stdlib/tests/t_windows_monitor_artifacts.nim``
## asserts they still agree with nim-stackable-hooks' own convention procs, so
## a rename breaks a test instead of breaking injection.

const
  MonitorShim64Name* = "librepro_monitor_shim.dll"
    ## The 64-bit shim; the anchor every other lookup is relative to.
  MonitorShim32Name* = "librepro_monitor_shim32.dll"
    ## The 32-bit (WOW64) shim, found by ``wow64ShimPathFor``.
  Wow64Probe32Name* = "stackable_hooks_wow64_probe32.exe"
    ## The 32-bit probe, found by ``wow64ProbePathFor``. It reports the
    ## 32-bit kernel32 proc addresses a 64-bit injector cannot resolve for
    ## itself, via its exit code.
  Inject64HelperName* = "stackable_hooks_inject64.exe"
    ## The 64-bit injection helper, found by ``inject64HelperPathFor``. Its
    ## only caller is the 32-bit shim: a WOW64 process cannot inject into a
    ## 64-bit child itself, so it delegates the whole operation.

  MonitorArtifactLibDir* = "build/lib"
    ## Where reprobuild's graph stages them, matching where
    ## ``findShimLibrary`` looks (``<appDir>/../lib``).

proc windowsMonitorArtifactNames*(): seq[string] =
  ## Every file the Windows monitor stack expects in one directory, in
  ## staging order (the 64-bit shim first — it is the anchor).
  @[MonitorShim64Name, MonitorShim32Name, Wow64Probe32Name,
    Inject64HelperName]

proc windowsCrossBitnessArtifactNames*(): seq[string] =
  ## The three that only a host with an i686 toolchain can produce. Their
  ## absence is what leaves 32-bit children unmonitored.
  @[MonitorShim32Name, Wow64Probe32Name, Inject64HelperName]

proc monitorArtifactPath*(name: string; libDir = MonitorArtifactLibDir): string =
  ## Project-relative staging path for one artefact.
  ##
  ## Joined with a literal ``/`` rather than ``os./`` on purpose. A declared
  ## output is part of the action key, so ``build/lib\x.dll`` and
  ## ``build/lib/x.dll`` are two different actions even though they name one
  ## file — and the 64-bit shim edge predates this module with the
  ## forward-slash spelling. Switching separators here would silently
  ## re-key it (and everything downstream of it) for nothing.
  if libDir.len == 0: name else: libDir & "/" & name
