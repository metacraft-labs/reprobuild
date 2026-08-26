## ``every_launch_path_is_monitored`` — the coverage gate for io-monitor
## hosting.
##
## WHY THIS TEST EXISTS
## --------------------
## A build action's dependency evidence is only as good as the guarantee
## that the monitor was actually wrapped around it. A launch path that
## misses the monitor is **silently unmonitored**: the child runs, the
## action succeeds, the cache entry publishes, and the recorded
## dependency set is wrong. Nothing in the build output says so.
##
## The engine reaches the OS through several different spawn sites, and
## the set of them is not obvious from any single grep — the tokens
## ``bypassRunQuota`` / ``inlineRunQuota`` / ``fallbackToRunQuotaBypass``
## occur 82x in ``repro_cli_support.nim``, 43x in
## ``repro_build_engine.nim`` and in four further production files
## (``repro_dev_env_engine.nim``, ``repro_lock_gen.nim``,
## ``repro_profile_compile/edge.nim``,
## ``repro_profile_compile/apply_build_actions.nim``), and not one of
## those occurrences is itself a spawn: they are CLI flags, config
## fields and forwarded parameters. This file pins the actual
## enumeration and exercises it against real processes.
##
##
## THE ENUMERATION
## ---------------
## Derived by reading ``libs/repro_build_engine/src/repro_build_engine.nim``
## and following every branch that can turn a ready action into a running
## child. Line numbers are a reading aid, NOT a checked fact: nothing in
## this suite verifies one, and every number below had drifted by the
## time it was next read (they were re-derived from the source, and the
## largest correction was 70 lines). Treat a number here as a hint and
## grep for the symbol next to it. What IS checked is the row set, which
## the first test case re-derives from the source TEXT so the list
## cannot silently fall out of date when lines move.
##
## The three-way launch decision is taken at ``:6251-6257``.
##
##   L1  BYPASS RUNQUOTA — monitored, and HOSTED IN-PROCESS
##       when ``launchBypassesRunQuota()`` (:5349): ``config.bypassRunQuota``,
##       ``REPROBUILD_NO_RUNQUOTA``, or ``fallbackToRunQuotaBypass`` with an
##       unreachable daemon. No lease.
##       spawn: ``startMonitorHost`` -> io-mon's ``startMonitor``, in the
##       engine process, with no ``repro internal io monitor`` child in
##       between (In-Process-Monitor-Hosting HM-4). The pre-HM-4 form —
##       ``startBypassRunQuotaProcess`` -> ``startDirect`` — is still the
##       code path when the monitor is not hosted (Windows, or an action
##       with no monitor policy), and is still pinned below.
##       backend label ``runquota-bypass``.
##
##   L2  RUNQUOTA HELPER PROCESS — monitored
##       when neither bypass nor inline applies.
##       spawn: ``startRunQuotaProcess`` (:3999) -> ``startProcess(helper,
##       helperCliArgs(...))`` (:4011). The argv reaches the OS two
##       processes deep: engine -> ``repro __repro-runquota-helper`` ->
##       the command.
##       backend label ``runquota-helper``.
##
##   L3  INLINE RUNQUOTA, GRANTED IMMEDIATELY — monitored
##       when ``config.inlineRunQuota`` and a session opens
##       (``tryEnsureInlineRunQuotaSession``, :5360).
##       spawn: ``offerWithRunQuotaBatch`` (:6357). NOTE: the daemon
##       grants the LEASE; it does not spawn the child. The spawn happens
##       in the engine process, inside ``startGrantedWithRunQuota``.
##       backend label ``runquota-inline``.
##
##   L3b INLINE RUNQUOTA, GRANTED AFTER QUEUEING — monitored
##       a candidate the daemon returns as ``rqokQueued`` (:6401) has NO
##       process yet. It is spawned LATER, from a different call site, in
##       the scheduler's wait loop:
##       ``pollInlineRunQuotaGrants`` -> ``startGrantedWithRunQuota``
##       (:5528), traced as ``launched``/``runquota-grant``.
##       This row is the one an enumeration written from the launch
##       decision alone would miss: it shares L3's backend label and its
##       command spec, but it is a genuinely separate spawn site reached
##       only under pool pressure.
##
##   L4  PRIVILEGED-OPERATION BROKER (elevation) — NOT monitored, by design
##       when ``action.requiresElevation`` (:6004), evaluated BEFORE the
##       monitor plan is computed, so the argv handed to
##       ``config.brokerSpawn(req)`` (:6022) is the RAW ``action.argv``.
##       The branch comment at :5989-6003 states the edge "is a one-shot
##       side-effecting spawn (no monitor depfile)". Fails closed when
##       ``brokerSpawn`` is nil.
##
##   L5  BUILT-IN ACTION — nothing to monitor
##       ``plan.action.kind != bakProcess`` (:6158) -> ``executeBuiltinAction``
##       (:6160), which explicitly refuses ``bakProcess`` (:4730).
##       ``monitoredAction`` returns early for built-ins at :2754.
##       Three built-in kinds do nevertheless run children, all outside
##       the monitor and outside RunQuota, and all deliberately:
##       ``bakWorkspaceVcs`` (git via the executor hook, :4510),
##       ``bakForeignProvision`` (the nix daemon, :4675), and post-build
##       dependency converters (``runConverter``, :2638), which run AFTER
##       the monitored action has finished.
##
## L1, L2, L3 and L3b are the monitored launch paths and this test
## exercises all four. L4 and L5 are recorded here so that "four
## monitored paths" is a decision on the record rather than an omission.
##
##
## WHO HOSTS THE MONITOR (In-Process-Monitor-Hosting HM-4)
## ------------------------------------------------------
## "Monitored" and "hosted in-process" are two different properties and
## this file now checks both, because they came apart in HM-4.
##
##   * L1 is HOSTED IN-PROCESS. The engine calls io-mon's decomposed host
##     API (``startMonitor`` / ``pollMonitor`` / ``finishMonitor``)
##     directly and the monitored root is its own child.
##   * L2, L3 and L3b are MONITORED BY THE CLI WRAPPER, still. Not an
##     oversight and not a fallback — io-mon OWNS the spawn (DH-4: "spawn
##     supplied by the caller is not delivered and should not be
##     expected"), so a path can host the monitor only if the ENGINE is
##     the process that spawns. L2's argv is spawned by a separate
##     ``repro __repro-runquota-helper`` process, two deep. L3 and L3b are
##     spawned inside ``offerWithRunQuotaBatch`` /
##     ``startGrantedWithRunQuota``, which spawn the child themselves as
##     part of binding it to the granted lease; hosting there needs a
##     RunQuota lease that can ADOPT an already-spawned child, which is a
##     change to the RunQuota adapter and not to the engine.
##
## That split is exactly why ``evidence is identical across launch
## paths`` matters more after HM-4 than before it: it is now comparing
## TWO HOSTING MECHANISMS against each other on the same fixture, not
## four call sites into one mechanism. ``checkTookLaunchPath`` also pins
## which mechanism each case used, by looking for the per-action stdio
## capture files that only the in-process host writes — so a regression
## in either direction (L1 quietly falling back to the wrapper, or a
## wrapper path quietly acquiring a host) reddens.
##
##
## THE TWO SEAMS
## -------------
## Four launch paths do not need four monitor wirings, because they share
## both halves of the wiring:
##
##   * ARGV — the monitor decision is taken in exactly ONE proc,
##     ``monitoredAction``, called from exactly ONE site. Since HM-4 that
##     proc either prepends the CLI wrapper or reports
##     ``hostInProcess = true``; either way it is the only place an action
##     acquires (or fails to acquire) a monitor.
##   * ARGV+ENV CONTRACT — all four paths obtain their ``ReproCommandSpec``
##     from exactly ONE proc, ``preparedRunQuotaCommand`` (:3953), whose
##     own doc-comment says it exists to "Build one argv/env contract for
##     direct, helper, and inline launches". L3b reuses the spec L3's
##     batch offer already built.
##
## So a host that has to be threaded through "every launch path" has two
## seams to thread, not the hundred-and-twenty-five occurrences counted
## above. The first test case pins both
## call-site counts and every spawn site in the module, so a fifth path
## forces this enumeration to be revisited rather than silently joining
## the set unmonitored.
##
##
## WHAT THE SOURCE SCAN GUARANTEES, AND WHAT IT DOES NOT
## -----------------------------------------------------
## Pinning counts in ``repro_build_engine.nim`` alone ratchets that file,
## not the launch surface. A working bypass was built to prove it: a
## helper in a sibling module of the same library, constructing its own
## ``ReproCommandSpec`` (the shared builder is private, so it must),
## dropping the monitor wrapper and spawning through ``startDirect``,
## wired into the bypass branch. Every count keyed on the engine module
## was unchanged and the suite stayed green — while the action ran
## unmonitored, succeeded, and published a wrong dependency set.
##
## The second test case scans every ``.nim`` under
## ``libs/repro_build_engine/src`` — with comments and string literals
## blanked out first, so the pins are about code and a reworded comment
## cannot move them — and pins five things:
##
##   1. how many times each way of starting a child process is CALLED,
##      library-wide, matching WHOLE IDENTIFIERS rather than substrings
##      (so ``uncontrolledStartProcess(`` is its own pinned row instead
##      of hiding from a search for ``startProcess(``);
##   2. that every one of those calls lives in the engine module this
##      enumeration is written from, so a spawn in a sibling module
##      fails even at an unchanged total;
##   3. that none of those names is written down WITHOUT being called.
##      An alias has to name what it aliases — ``let engineSpawn =
##      startDirect`` — so aliasing moves a count even though calling
##      through the alias would not;
##   4. that no OTHER identifier is merely named after one of them;
##   5. that only the engine module imports one of the modules on the
##      capability list, and that where that list restricts an import to
##      named symbols — ``std/posix``, ``std/winlean`` — the import line
##      names nothing else.
##
## Rule 5 is the only one that does not depend on knowing the callee's
## name: within a module ON THE LIST, it holds for a procedure nobody has
## thought of yet, because the call is impossible without the import. It
## is NOT capability-level in general, and an earlier version of this
## comment said it was. The list is a hand-written enumeration of modules,
## so the rule covers exactly the modules somebody thought of — which is
## the same failure mode as the name rows, one level up. It was found the
## same way, too: ``std/posix`` and ``std/winlean`` were missing, and
## ``fork()`` + ``execvp()`` in a sibling module of this library compiled,
## ran an unmonitored child, and left every gate green. They are on the
## list now. What has not changed is that nothing derives the list from
## the code.
##
## THE PINNED SET IS AN ALLOWLIST, AND AN ALLOWLIST IS ONLY AS GOOD AS
## ITS AUDIT. ``execCmd`` and ``execProcesses`` were missing from it for
## exactly that reason. Neither is a substring of a name that was on it
## — ``execCmd(`` is not ``execCmdEx(``, ``execProcesses(`` is not
## ``execProcess(`` — and ``std/osproc`` is already imported here, so a
## helper calling either one started a child that nothing counted. That
## was demonstrated end to end, not argued: a new file in this library
## ran an action's raw argv through ``execCmd`` while the suite reported
## every case green.
##
## So the third test case makes the audit reproducible rather than a
## matter of someone remembering. It reads the exported surface of every
## module ON THE CAPABILITY LIST — not of every module this library can
## reach a spawn through, which is a claim nothing here can make — and
## fails if that surface contains a name this file has not classified as
## either putting a child process on the road — starting one, building
## the argv/env one is started from, resolving the binary one is started
## as — or not. A new exported routine upstream is a red test with the
## new name in the message, not a silent hole.
##
## THE TWO LISTS ARE NOW TIED TOGETHER, and that is the part worth
## keeping. Until it was asserted, ``SpawnCapabilityModules`` named five
## modules and the audit read four: ``repro_runquota`` — where
## ``startDirect``, ``offerWithRunQuotaBatch`` and
## ``startGrantedWithRunQuota`` all live, so every monitored path in this
## file goes through it — was gated on its import and never read. An
## exported spawn helper added to it and called from the engine started a
## real unmonitored child with every case green. The case now requires the
## two lists to have the same length, the same keys and no duplicate key,
## so the next module added cannot arrive with no surface at all.
##
## THAT IS A BIJECTION ON KEYS AND NOTHING MORE, which is less than it
## sounds and was measured rather than reasoned about. It says nothing
## about whether a surface's ``sourceRel`` points at the module its key
## names: a row that keeps the key ``repro_runquota``, points ``sourceRel``
## at a file with no exported routines and classifies nothing leaves both
## ``unclassified`` and ``vanished`` empty while reading the module not at
## all — both lists in perfect bijection, every message silent, and the
## same spawn helper green again. So the read is also required to find
## something: a capability module has an exported surface by definition,
## and a read that finds none has read the wrong file.
##
## Two rows are read differently and say so: ``std/posix`` (492 exported
## routines) and ``std/winlean`` are gated on their IMPORT LINE instead —
## they may be reached only through ``from <module> import <names>`` with
## every name on an allowlist, which is stronger than a name audit for
## this purpose and does not go stale as the module grows. Their audit
## checks that the allowlisted names really are exported, not that the
## module exports nothing else.
##
## WHAT IT DOES NOT GUARANTEE. This is a ratchet on one library, not a
## proof that every action is monitored:
##
##   * A launch path implemented in a DIFFERENT library that the engine
##     calls is outside this scan entirely.
##     ``scripts/check_ambient_execution.sh`` is the repo-wide half, and
##     it is weaker in two ways: it matches a fixed list of NAMES, so a
##     spelling that is not on that list is invisible to it, and it is
##     keyed on FILES, so a file already on its baseline can acquire
##     another spawn without it reporting anything.
##   * Inside this library, an identifier that neither names one of the
##     pinned procedures nor ends in one of their names — a callback
##     handed in from outside, a procedure re-exported elsewhere under a
##     different name — is invisible to rules 3 and 4. Rule 5 is what
##     narrows that: the re-export still has to be imported from
##     somewhere, and only the engine module may import a module on the
##     capability list. It does not eliminate it, and it only narrows it
##     as far as that list reaches.
##   * The capability list itself is written by hand. Nothing derives
##     "these are the modules a child can be started through" from the
##     code, so a spawn-capable module nobody listed is invisible to rule
##     5 exactly as an unpinned name is invisible to rules 1-4. Two were
##     missing (``std/posix``, ``std/winlean``) and were found by attack,
##     not by the gate.
##   * ``scripts/check_ambient_execution.sh`` bans no OS-level name:
##     ``fork``, ``execvp``, ``posix_spawn`` and their neighbours are not
##     on its list, in any file. Inside this library rule 5 covers them;
##     outside it, nothing does. Adding them repo-wide is a measurement
##     of its own, because ``std/posix`` is imported by plenty of
##     platform code that has nothing to do with launching.
##   * The two SIBLING rows — ``runquota_process`` and ``io_mon`` — are
##     located at RUN time from ``$RUNQUOTA_SRC`` / ``$IO_MON_SRC``, and
##     when those are unset the lookup falls back to the workspace sibling
##     checkout. That is not necessarily the revision this binary was
##     COMPILED against, so those two rows can audit sources the compiled
##     code never saw. The stdlib rows do not have this problem
##     (``querySetting(libPath)`` is resolved at compile time) and neither
##     do the in-tree ones.
##   * The compile-time linter in
##     ``repro_core/ambient_execution.nim`` — the authoritative half, of
##     which the shell script is an approximation — has no rewrite rule
##     for ``execCmd`` and none for ``execProcesses``, and no
##     ``uncontrolled*`` hatch to migrate a call site to. It is silent on
##     exactly the two ``std/osproc`` exports this file's rows and the
##     shell ratchet had to be widened for. Adding the rules would warn
##     at existing call sites across the repository, which is a
##     migration, so the two names are covered here and by the ratchet
##     but not by the compiler yet.
##
## What the gate does buy is that a launch path cannot be added to this
## library by writing down the name of a way to start a process, that
## the set of such names is checked against the sources of the modules
## on the capability list instead of being remembered, and that a file
## other than the engine module cannot even import one of those modules.
## What it does not buy is any statement about a module nobody put on
## the list.
##
##
## NO MOCKS
## --------
## Every case runs the real ``repro`` binary as the monitor driver, the
## real graph-built monitor shim, a real compiled C fixture performing a
## real ``open``/``read`` of a real file, and — for L2, L3 and L3b — the
## real ``repro __repro-runquota-helper`` and a real ``runquotad`` daemon
## over a real unix socket. Nothing is stubbed. The oracle is the
## dependency evidence the engine actually produced, not a call
## assertion.

import std/[algorithm, compilesettings, os, osproc, sequtils, sets, strutils,
            tables, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_test_support

type
  LaunchPathKind = enum
    lpBypassRunQuota          ## L1
    lpRunQuotaHelper          ## L2
    lpInlineRunQuota          ## L3
    lpInlineRunQuotaQueued    ## L3b

  LaunchPath = object
    kind: LaunchPathKind
    name: string
    spawnSite: string
      ## The proc in ``repro_build_engine.nim`` that performs the spawn.
    needsRunQuota: bool

const EnumeratedLaunchPaths: array[4, LaunchPath] = [
  LaunchPath(kind: lpBypassRunQuota, name: "L1 bypass-runquota",
    spawnSite: "startBypassRunQuotaProcess", needsRunQuota: false),
  LaunchPath(kind: lpRunQuotaHelper, name: "L2 runquota-helper",
    spawnSite: "startRunQuotaProcess", needsRunQuota: true),
  LaunchPath(kind: lpInlineRunQuota, name: "L3 inline-runquota",
    spawnSite: "offerWithRunQuotaBatch", needsRunQuota: true),
  LaunchPath(kind: lpInlineRunQuotaQueued,
    name: "L3b inline-runquota-after-queue",
    spawnSite: "startGrantedWithRunQuota", needsRunQuota: true)
]

## A C fixture that reads a marker file and writes an output file, with
## an optional busy period so a second action can be held in the
## daemon's queue while this one holds the lease (L3b). The read is the
## observable: it can only appear in the action's evidence if the
## io-monitor shim was actually injected into this process.
const FixtureSource = r"""
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) return 80;
  char buffer[256];
  ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
  if (count < 0) return 81;
  close(fd);
  buffer[count] = '\0';
  long hold_ms = atol(argv[3]);
  if (hold_ms > 0) {
    struct timespec ts;
    ts.tv_sec = hold_ms / 1000;
    ts.tv_nsec = (hold_ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
  }
  FILE *out = fopen(argv[2], "w");
  if (out == NULL) return 82;
  fputs(buffer, out);
  fclose(out);
  return 0;
}
"""

const EngineSource = "libs/repro_build_engine/src/repro_build_engine.nim"

## The WHOLE engine library, not just the module the enumeration above is
## written from. Scanning one file only ratchets that one file: a helper
## dropped into a sibling module can build its own command spec, strip the
## monitor wrapper and spawn, and every count pinned against
## ``repro_build_engine.nim`` stays exactly as it was. That hole was
## demonstrated with a working side-channel launcher, so the scan is keyed on
## the directory.
const EngineLibrarySourceDir = "libs/repro_build_engine/src"

## The engine module the launch-path enumeration is written from. Spawning
## belongs here and nowhere else in the library, so the scan reports the
## FILE of every spawn call and not merely the total.
const EngineModuleRelPath = EngineLibrarySourceDir & "/repro_build_engine.nim"

type EngineSourceFile = object
  relPath: string
  text: string           ## the file as written
  code: string           ## the same file with comments and literals blanked
  importCode: string     ## comments blanked, literals kept — the import gate

## Every way of starting a child process (or of building the argv+env a
## child is started from) that this library can reach, and how many calls
## it is allowed to contain. A zero row is not padding: it is the assertion
## that this way of starting a child has NOT appeared.
##
## THE ROWS ARE AN ALLOWLIST AND THE AUDIT THAT KEEPS THEM HONEST IS
## ``the spawn table still covers every way in`` BELOW. Four rows were
## missing when this table was first written, and each was missing for the
## same reason — a name that no other name on the list contains:
##
##   * ``execCmd`` is not a substring of ``execCmdEx``, and
##     ``execProcesses`` is not a substring of ``execProcess``. Both come
##     from ``std/osproc``, which this library already imports, so both
##     were callable from any file here without moving a single count.
##     Demonstrated, not hypothesised: a helper that ran an action's raw
##     argv through ``execCmd`` left every pin below intact.
##   * ``launchProcess`` and ``commandSpec`` come from
##     ``runquota_process``. They are exactly what ``startDirect`` itself
##     calls, and they are importable directly, so "spawn the way the
##     engine spawns, without naming the engine's primitive" was one
##     import away.
##
## ``uncontrolled*`` rows are the repository's sanctioned escape hatches
## (``repro_core/ambient_execution.nim``): the spelling a new launch path
## can reach for while leaving the stdlib name's count untouched. Note that
## ``execCmd`` and ``execProcesses`` have no ``uncontrolled*`` counterpart
## and no rewrite-warning template there either, so the compile-time linter
## does not see them at all — which is the other half of why they needed a
## row here.
const SpawnPrimitives: array[43, tuple[name: string; expected: int;
                                       why: string]] = [
  ("startProcess", 3,
    "post-build converter, the L2 RunQuota helper, the nix daemon"),
  # In-Process-Monitor-Hosting HM-4. ``startMonitor`` is a REAL spawn — it is
  # io-mon's only spawn site for a monitored tree — so the engine hosting the
  # monitor is a launch path in its own right and is pinned like any other.
  # ``pollMonitor`` and ``finishMonitor`` are on the list for the same reason
  # ``commandSpec`` is: on the Windows arm the spawn is DEFERRED into them
  # (``runWithMonitorShim`` spawns and waits in one call), so a call to either
  # can put a child on the road even though neither does so on POSIX.
  ("startMonitor", 1, "HM-4: L1 hosts io-mon in-process"),
  ("pollMonitor", 1, "HM-4: advances a hosted monitor; SPAWNS on Windows"),
  ("finishMonitor", 1, "HM-4: consumes a hosted monitor; SPAWNS on Windows"),
  ("uncontrolledStartProcess", 0, "the escape hatch; unused by the engine"),
  ("startDirect", 1, "L1 bypass-runquota"),
  ("offerWithRunQuotaBatch", 1, "L3 inline-runquota"),
  ("startGrantedWithRunQuota", 1, "L3b inline-runquota-after-queue"),
  ("startWithRunQuota", 0, "superseded by the batch offer"),
  ("offerWithRunQuota", 0, "superseded by the batch offer"),
  ("runWithRunQuota", 0, "blocking; the engine polls instead"),
  ("execCmd", 0, "std/osproc; NOT matched by a search for execCmdEx"),
  ("execCmdEx", 0, ""),
  ("uncontrolledExecCmdEx", 0, ""),
  ("execProcess", 0, ""),
  ("execProcesses", 0, "std/osproc; NOT matched by a search for execProcess"),
  ("uncontrolledExecProcess", 0, ""),
  ("execShellCmd", 0, ""),
  ("uncontrolledExecShellCmd", 0, ""),
  ("findExe", 0, ""),
  ("uncontrolledFindExe", 0, ""),
  ("launchProcess", 0, "runquota_process; what startDirect itself calls"),
  ("commandSpec", 0, "runquota_process; the spec startDirect hands it"),
  ("runMonitored", 0, "io_mon's spawning host entry point"),
  ("runFsSnoopCli", 0, "io_mon's CLI wrapper around runMonitored"),
  ("warnFindExe", 0, "the linter's rewrite template, callable by name"),
  ("warnExecCmdEx", 0, ""),
  ("warnExecProcess", 0, ""),
  ("warnExecShellCmd", 0, ""),
  ("warnStartProcess", 0, ""),
  # `repro_runquota`'s remaining exported ways in, found by reading its
  # source instead of by remembering it. The first is the RunQuota helper's
  # own entry point; the other two build the argv a child is started from,
  # which is the same reason `commandSpec` has a row.
  ("runRunQuotaHelperCli", 0, "the L2 helper's own entry point"),
  ("acquireCliArgs", 0, "builds the `runquota acquire -- <argv>` command line"),
  ("helperCliArgs", 1, "L2: the argv the RunQuota helper is started with"),
  # The OS. These have no `uncontrolled*` hatch, no rewrite template and no
  # entry in the shell ratchet; the import gate is what really covers them
  # (see `SpawnCapabilityModules`), and these rows are the name-level
  # second line for the one file that IS allowed the import.
  ("fork", 0, "std/posix"),
  ("vfork", 0, "std/posix"),
  ("execv", 0, "std/posix"),
  ("execve", 0, "std/posix"),
  ("execvp", 0, "std/posix"),
  ("posix_spawn", 0, "std/posix"),
  ("posix_spawnp", 0, "std/posix"),
  ("popen", 0, "std/posix"),
  ("createProcessW", 0, "std/winlean"),
  ("shellExecuteW", 0, "std/winlean")
]

## THE ARGV+ENV CONTRACT, pinned as a construction count rather than only as
## a call count on the private builder. ``preparedRunQuotaCommand`` is
## private to ``repro_build_engine.nim``, so a launch path added anywhere
## else in the library cannot call it and has to construct its own
## ``ReproCommandSpec`` — which is precisely how the demonstrated bypass
## slipped past a scan keyed on the builder's name.
const CommandSpecConstructions = 1

## Case-insensitive tails that no OTHER call identifier in the library may
## end with. Rationale: the pins above match whole identifiers, so
## ``uncontrolledStartProcess(`` no longer masquerades as ``startProcess(``
## — but it also means an identifier this table has never heard of would be
## counted against nothing at all. A procedural alias is the sharp case:
## ``let engineStartDirect = startDirect`` followed by
## ``engineStartDirect(spec)`` moves no primitive's count and constructs no
## new command spec, so only a rule about NAMES can see it. Anything whose
## name ends in a spawn primitive's name has to be added to
## ``SpawnPrimitives`` with a count before it can exist.
const SpawnNameTails = ["startprocess", "startdirect", "execcmdex",
                        "execprocess", "execshellcmd", "findexe",
                        "execcmd", "execprocesses", "launchprocess",
                        "commandspec", "runmonitored",
                        "startmonitor", "pollmonitor", "finishmonitor"]

## THE CAPABILITY GATE, and the reason the rows above are not the whole
## answer. Counting names is only ever as complete as the list of names.
## Importing is not: a procedure cannot be called from a file that has not
## imported the module it lives in, whatever it is called. So this is the
## list of modules known to carry that capability, and only the engine
## module may import one. The list is written by hand and nothing derives
## it — say "the modules on this list", never "the modules through which a
## child can be started at all". Two were missing and were found by attack.
##
## The match is on the WHOLE module path, so ``io_mon/codec`` (types, no
## spawn) is not ``io_mon`` (re-exports ``fs_snoop``, which spawns), and a
## sibling module is free to import the former.
##
## ``engineImports`` records whether the engine module imports the module
## TODAY. Where it is true the gate is "the engine module and nothing
## else", and the truth of it is asserted so the rule cannot quietly
## become a description of a capability that is no longer there.
##
## Where it is false the gate is stronger: NO file in this library may
## import it, the engine module included. Two rows are in that state, and
## both are ways to spawn exactly as the engine spawns while naming
## nothing the engine names — ``runquota_process``, the backend
## ``startDirect`` is built on and which the engine reaches only through
## ``repro_runquota``, and ``repro_core/ambient_execution``, which holds
## the ``uncontrolled*`` escape hatches.
##
## THE OS ITSELF IS A CAPABILITY MODULE, and leaving it off this list was
## the hole that made rule 5's "it holds for a procedure nobody has thought
## of yet" false. ``std/posix`` exports ``fork``, ``execvp``,
## ``posix_spawn`` and ``system``; ``std/winlean`` exports
## ``createProcessW`` and ``shellExecuteW``. Both are imported by the engine
## module today. Demonstrated, not argued: ``fork()`` + ``execvp()`` in the
## sibling ``platform.nim`` compiled, ran an unmonitored child, and left
## every gate green.
##
## They cannot be classified name-by-name the way ``std/osproc`` is —
## ``posix.nim`` exports 492 routines — so they are gated on the IMPORT
## LINE instead, which is stronger and is what ``symbolRestricted`` below
## is for. See ``capabilitySurfaces``.
const SpawnCapabilityModules: array[7, tuple[path: string;
                                             engineImports: bool;
                                             why: string]] = [
  ("osproc", true,
    "std/osproc: startProcess, execProcess, execProcesses, execCmd, execCmdEx"),
  ("runquota_process", false,
    "the shared process backend: launchProcess, commandSpec"),
  ("repro_runquota", true,
    "startDirect and the RunQuota launch/offer wrappers"),
  ("io_mon", true,
    "re-exports fs_snoop, whose runMonitored spawns the monitored child"),
  ("ambient_execution", false,
    "repro_core's sanctioned escape hatches: uncontrolledStartProcess et al"),
  ("posix", true,
    "std/posix: fork, vfork, execv/execve/execvp, posix_spawn, popen, system"),
  ("winlean", true,
    "std/winlean: createProcessW, shellExecuteW")
]

## THE AUDIT. For each capability module, its ENTIRE exported routine
## surface, split into the names that put a child process on the road —
## starting one, or building the argv/env one is started from, or
## resolving the binary one is started as — and the names that cannot.
## The audit case reads each module's source and requires the union of the
## two lists to be exactly what it finds there, so a new exported routine
## upstream reddens this file instead of quietly becoming an unpinned way
## in. Every name in ``spawning`` must also carry a row in
## ``SpawnPrimitives`` above.
##
## ``io_mon`` is audited through ``io_mon/fs_snoop``: ``io_mon.nim`` itself
## defines no routines, it re-exports, and ``fs_snoop`` is the re-exported
## module that owns the spawn.
##
## EVERY ROW OF ``SpawnCapabilityModules`` MUST HAVE A SURFACE HERE, and the
## audit case asserts it by key. Nothing linked the two lists before, and
## the consequence was silent: ``repro_runquota`` — the module that holds
## ``startDirect``, ``offerWithRunQuotaBatch`` and
## ``startGrantedWithRunQuota``, i.e. the module every monitored launch path
## in this file goes through — was on the capability list and had no
## surface, so its 28 exported routines were never read. An exported
## ``spawnRawDetached`` added to it, called from the engine at the L1 site,
## started an unmonitored child with every gate green. The missing
## assertion mattered more than the missing row: with the row but without
## the assertion, the NEXT capability module to be added arrives with the
## same hole.
type
  CapabilityAudit = enum
    caFullSurface
      ## Every exported routine of the module is classified below, and the
      ## audit fails on any name the module exports that is not.
    caImportAllowlist
      ## The module's surface is too large to classify (``std/posix``
      ## exports 492 routines), so the gate is on the IMPORT instead: it may
      ## be reached only through ``from <module> import <names>`` with every
      ## name on ``allowedSymbols``. That is strictly stronger than a name
      ## audit for the property in question — ``fork`` cannot be called from
      ## a file that has not put ``fork`` on its import line, whatever the
      ## caller spells it — and it does not go stale when the module grows.
      ## What the audit still checks is that every classified name is really
      ## exported, so the allowlist keeps describing the module it claims to.

  CapabilitySurface = object
    key: string             ## which ``SpawnCapabilityModules`` row this is
    audit: CapabilityAudit
    sourceRel: string       ## path of the module source, inside its own root
    spawning: seq[string]
    inert: seq[string]
    allowedSymbols: seq[string]
      ## ``caImportAllowlist`` only: the exact symbols an import of this
      ## module may name. Includes types and constants, which are not
      ## routines and so never appear in ``spawning`` / ``inert``.

proc capabilitySurfaces(): seq[CapabilitySurface] =
  @[
    CapabilitySurface(key: "osproc", audit: caFullSurface,
      sourceRel: "pure/osproc.nim",
      spawning: @["execProcess", "execCmd", "startProcess", "execProcesses",
                  "execCmdEx"],
      inert: @["close", "suspend", "resume", "terminate", "kill", "running",
               "processID", "waitForExit", "peekExitCode", "inputStream",
               "outputStream", "errorStream", "peekableOutputStream",
               "peekableErrorStream", "inputHandle", "outputHandle",
               "errorHandle", "countProcessors", "lines", "readLines",
               "hasData"]),
    CapabilitySurface(key: "runquota_process", audit: caFullSurface,
      sourceRel: "libs/runquota_process/src/runquota_process.nim",
      spawning: @["commandSpec", "launchProcess"],
      inert: @["libraryInfo", "backendProfile", "launchResult", "running",
               "pollCompletion", "terminate", "killNow", "waitForCompletion",
               "waitForExit", "cancelAndWait", "close"]),
    # THE MODULE THE WHOLE ENUMERATION GOES THROUGH, and the one that was
    # on the capability list with no surface at all. `startDirect` (L1),
    # `offerWithRunQuotaBatch` (L3) and `startGrantedWithRunQuota` (L3b)
    # live here, so an exported addition to this module is the shortest
    # path from "the engine may import it" to "the engine can start a
    # child the enumeration does not describe".
    CapabilitySurface(key: "repro_runquota", audit: caFullSurface,
      sourceRel: "libs/repro_runquota/src/repro_runquota.nim",
      spawning: @["startDirect", "startWithRunQuota", "offerWithRunQuota",
                  "offerWithRunQuotaBatch", "startGrantedWithRunQuota",
                  "runWithRunQuota", "runRunQuotaHelperCli",
                  "acquireCliArgs", "helperCliArgs"],
      inert: @["toRunQuotaRequest", "grantHeartbeatMs", "grantUnresponsiveMs",
               "grantBoundedReadMs", "reportGrantHeartbeat", "awaitGrantLoop",
               "isRunQuotaDaemonReachable", "processId", "pollCompletion",
               "finishCompleted", "cancelAndWait", "openRunQuotaSession",
               "close", "maxOfferBatchSize", "pollRunQuotaGrants",
               "cancelQueued", "defaultRunQuotaWindowsPipePath",
               "probeWindowsPipeOwner", "terminateStalePipeOwner"]),
    # THE MODULE THE ENGINE NOW HOSTS FROM. Before HM-4 this surface was six
    # names and the engine called none of them; the decomposed host API
    # (IoMon-Decomposed-Host-API DH-2) added seven more, and THIS AUDIT IS
    # WHAT REPORTED THEM — bumping reprobuild's io-mon pin turned the case red
    # with all seven named, before a line of engine code had changed. That is
    # the audit doing its job on an UPSTREAM change, which is the case it was
    # written for and had not yet been exercised on.
    #
    # ``pollMonitor`` and ``finishMonitor`` are classified as spawning
    # deliberately, even though on POSIX neither starts anything: the Windows
    # arm defers the spawn into them, so "can this put a child on the road"
    # is true of both on at least one platform, and the classification has to
    # be the union rather than this machine's answer.
    CapabilitySurface(key: "io_mon", audit: caFullSurface,
      sourceRel: "io_mon/fs_snoop.nim",
      spawning: @["runMonitored", "runFsSnoopCli", "startMonitor",
                  "pollMonitor", "finishMonitor"],
      inert: @["appendLauncherEventLoss", "findShimLibrary", "completeness",
               "records", "monitorLifecycleCounts", "live", "hasExited",
               "rootPid"]),
    # The escape hatches, and the rewrite templates that warn about the
    # stdlib names. The templates are pattern rewrites, but they are also
    # ordinary exported templates that can be called by name, so they are
    # classified as ways in rather than as commentary.
    #
    # AUDITING THIS MODULE ALSO SHOWS WHAT IS MISSING FROM IT: there is no
    # `warnExecCmd` and no `warnExecProcesses`, so the compile-time linter
    # is silent on exactly the two `std/osproc` exports that were missing
    # from the table above. The rows and the ratchet cover them here; the
    # linter itself does not, and that is a known limitation rather than
    # something this file fixed.
    CapabilitySurface(key: "ambient_execution", audit: caFullSurface,
      sourceRel: "libs/repro_core/src/repro_core/ambient_execution.nim",
      spawning: @["uncontrolledFindExe", "uncontrolledExecCmdEx",
                  "uncontrolledExecProcess", "uncontrolledExecShellCmd",
                  "uncontrolledStartProcess", "warnFindExe", "warnExecCmdEx",
                  "warnExecProcess", "warnExecShellCmd", "warnStartProcess"],
      inert: @[]),
    # THE OPERATING SYSTEM. Both rows are `caImportAllowlist`: they export
    # far too much to classify, and classifying them is not what the gate
    # needs anyway. `std/posix` puts `fork` and `execvp` one line away from
    # any file in this library, and that was demonstrated with a working
    # unmonitored spawn in the sibling `platform.nim`. The gate is that the
    # engine module — and only it — may name these modules, and only
    # through the symbols listed here.
    #
    # `Pid`, `SIGKILL`, `SIGTERM`, `Handle`, `DWORD`, `WINBOOL`,
    # `SYNCHRONIZE`, `MAXIMUM_WAIT_OBJECTS` and `WOHandleArray` are a type
    # and constants rather than routines, so they appear in
    # `allowedSymbols` and in neither classification list.
    # ``Mode`` / ``umask`` / ``dup`` / ``dup2`` / ``close`` are HM-4's
    # in-process spawn context (``beginMonitorSpawnContext``): io-mon spawns
    # with ``poParentStreams``, so the monitored child inherits the ENGINE's
    # descriptors 1 and 2 and the engine's file-creation mask, and both have
    # to be set across the spawn now that no wrapper shell is doing it. None
    # of the five starts a child; ``Mode`` is a type and so appears only in
    # ``allowedSymbols``.
    #
    # This row is the gate working rather than the gate being widened: the
    # five were REFUSED on the first run after the engine change, each named
    # individually, and each had to be classified before the suite would go
    # green again.
    CapabilitySurface(key: "posix", audit: caImportAllowlist,
      sourceRel: "posix/posix.nim",
      spawning: @[],
      inert: @["kill", "setpgid", "umask", "dup", "dup2", "close"],
      allowedSymbols: @["Pid", "SIGKILL", "SIGTERM", "kill", "setpgid",
                        "Mode", "umask", "dup", "dup2", "close"]),
    CapabilitySurface(key: "winlean", audit: caImportAllowlist,
      sourceRel: "windows/winlean.nim",
      spawning: @[],
      inert: @["openProcess", "closeHandle", "waitForMultipleObjects"],
      allowedSymbols: @["Handle", "DWORD", "WINBOOL", "SYNCHRONIZE",
                        "MAXIMUM_WAIT_OBJECTS", "WOHandleArray",
                        "openProcess", "closeHandle",
                        "waitForMultipleObjects"])
  ]

proc capabilitySurfaceRoot(key, repoRoot: string): string =
  ## Where each audited module's source lives. Mirrors ``config.nims``:
  ## the stdlib comes from the compiler that will build this test, and the
  ## two siblings honour the same environment overrides the build does.
  ##
  ## A CAVEAT THAT IS NOT FIXED HERE, and that a reader has to know before
  ## trusting the two sibling rows. ``querySetting(libPath)`` is resolved at
  ## COMPILE time, so the stdlib rows really do audit the stdlib this binary
  ## was built against. ``RUNQUOTA_SRC`` and ``IO_MON_SRC`` are read at RUN
  ## time, and when they are unset the lookup falls back to the workspace
  ## sibling checkout — which is only the revision this test was COMPILED
  ## against if nothing moved in between. Run the binary with the two
  ## variables unset in a workspace whose siblings have since been updated,
  ## or from a different workspace, and those two rows audit sources the
  ## compiled code never saw. Closing it means baking the resolved paths in
  ## at compile time (``staticExec`` / ``-d:``), which is a change to how
  ## the suite is driven, so it is declared rather than done.
  case key
  of "osproc", "posix", "winlean":
    querySetting(SingleValueSetting.libPath)
  of "runquota_process":
    let fromEnv = getEnv("RUNQUOTA_SRC")
    if fromEnv.len > 0: fromEnv else: repoRoot.parentDir / "runquota"
  of "io_mon":
    let fromEnv = getEnv("IO_MON_SRC")
    if fromEnv.len > 0 and fileExists(fromEnv / "io_mon.nim"):
      fromEnv
    elif fromEnv.len > 0 and fileExists(fromEnv / "src" / "io_mon.nim"):
      fromEnv / "src"
    else:
      repoRoot.parentDir / "io-mon" / "src"
  of "ambient_execution", "repro_runquota":
    repoRoot
  else:
    ""

proc countOccurrences(haystack, needle: string): int =
  var pos = 0
  while true:
    let hit = haystack.find(needle, pos)
    if hit < 0: break
    inc result
    pos = hit + needle.len

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc blankRange(s: var string; a, b: int) =
  for k in max(a, 0) ..< min(b, s.len):
    if s[k] != '\n': s[k] = ' '

proc strippedSource(src: string; blankStrings: bool): string =
  ## ``src`` with every comment — and, when ``blankStrings``, every string
  ## and character literal — replaced by spaces, preserving length and line
  ## structure.
  ##
  ## THE TWO MODES EXIST BECAUSE THE IMPORT GATE NEEDS THE OPPOSITE OF WHAT
  ## THE COUNTS NEED. The counts must not see prose or literals. The import
  ## gate must, because Nim accepts a QUOTED path as a module spelling:
  ## ``import "../../../repro_runquota/src/repro_runquota.nim"`` is a real
  ## import of a capability module, and blanking its literal deletes the
  ## whole statement before ``moduleImports`` can read it. Measured: with
  ## one stripper for both, that line in the sibling ``platform.nim`` left
  ## the gate at 10 [OK] and exit 0 — rule 5 switched off by a quotation
  ## mark. Comments stay blanked in both modes, so a commented-out import is
  ## still not an import.
  ##
  ## Why this exists: without it every pin below is a pin on PROSE as well
  ## as on code. ``repro_build_engine.nim`` mentions ``osproc.startProcess``
  ## and ``launchProcess`` in comments today, so a raw identifier count
  ## cannot distinguish "a launch path was added" from "a comment was
  ## reworded" — and a count that reddens on comment edits is a count
  ## somebody eventually re-baselines without reading.
  result = src
  var i = 0
  let n = src.len
  while i < n:
    let c = src[i]
    if c == '#':
      if i + 1 < n and src[i + 1] == '[':
        var depth = 1
        var j = i + 2
        while j < n and depth > 0:
          if j + 1 < n and src[j] == '#' and src[j + 1] == '[':
            inc depth
            j += 2
          elif j + 1 < n and src[j] == ']' and src[j + 1] == '#':
            dec depth
            j += 2
          else:
            inc j
        result.blankRange(i, j)
        i = j
      else:
        var j = i
        while j < n and src[j] != '\n': inc j
        result.blankRange(i, j)
        i = j
    elif c == '"':
      # A string literal is RAW when the quote is glued to an identifier
      # (``r"…"``, ``fmt"…"``): backslash is then an ordinary character and
      # a doubled quote is the escape.
      let raw = i > 0 and isIdentChar(src[i - 1])
      if i + 2 < n and src[i + 1] == '"' and src[i + 2] == '"':
        var j = src.find("\"\"\"", i + 3)
        j = if j < 0: n else: j + 3
        if blankStrings: result.blankRange(i, j)
        i = j
      else:
        var j = i + 1
        while j < n:
          if src[j] == '\n': break
          elif (not raw) and src[j] == '\\': j += 2
          elif raw and src[j] == '"' and j + 1 < n and src[j + 1] == '"': j += 2
          elif src[j] == '"':
            inc j
            break
          else: inc j
        if blankStrings: result.blankRange(i, j)
        i = j
    elif c == '\'':
      # A char literal — but NOT the apostrophe of ``1'u32`` or of a
      # custom numeric literal, which is glued to what precedes it.
      if i > 0 and isIdentChar(src[i - 1]):
        inc i
      else:
        var j = i + 1
        if j < n and src[j] == '\\':
          j += 2
          while j < n and src[j] != '\'' and src[j] != '\n': inc j
        elif j < n:
          inc j
        if j < n and src[j] == '\'': inc j
        if blankStrings: result.blankRange(i, j)
        i = j
    else:
      inc i

proc codeOnly(src: string): string =
  ## Comments AND literals blanked. What every count in this file is
  ## computed over.
  strippedSource(src, blankStrings = true)

proc importScanSource(src: string): string =
  ## Comments blanked, literals KEPT. What the import gate is computed over,
  ## so a quoted module path is still an import. See ``strippedSource``.
  strippedSource(src, blankStrings = false)

iterator wholeIdentifiers(src: string): tuple[name: string; called: bool] =
  ## Every maximal identifier in ``src``, with whether it is immediately
  ## followed by ``(``.
  ##
  ## The ``called = false`` half is what sees an ALIAS. ``let engineSpawn =
  ## startDirect`` followed by ``engineSpawn(spec)`` moves no call count and
  ## constructs no command spec — but it cannot avoid writing ``startDirect``
  ## down as a bare name, and neither can ``from repro_runquota import
  ## startDirect as engineSpawn``. Requiring every pinned name's bare-
  ## reference count to be zero turns "you may call this N times" into "this
  ## name may appear exactly N times, as N calls".
  var i = 0
  while i < src.len:
    if isIdentChar(src[i]) and src[i] notin {'0' .. '9'} and
       (i == 0 or not isIdentChar(src[i - 1])):
      var stop = i
      while stop < src.len and isIdentChar(src[stop]): inc stop
      yield (src[i ..< stop], stop < src.len and src[stop] == '(')
      i = stop
    else:
      inc i

type ModuleImport = object
  path: string
    ## the module path as written, ``std/[os, osproc]`` already expanded
  symbols: seq[string]
    ## the named symbols of a ``from X import a, b``; empty otherwise
  symbolRestricted: bool
    ## true ONLY for ``from X import <names>``. ``import X``,
    ## ``import X except Y`` and ``import X as Y`` all pull the module's
    ## whole surface into scope and are therefore unrestricted.

proc moduleImports(code: string): seq[ModuleImport] =
  ## Every module this file imports, includes or re-exports, with
  ## ``std/[os, osproc]`` expanded to ``std/os`` and ``std/osproc``, and
  ## with the symbol list of a ``from X import a, b`` recorded.
  ##
  ## The symbol list is what makes a capability row about a module as large
  ## as ``std/posix`` meaningful. ``from std/posix import Pid, SIGKILL,
  ## SIGTERM, kill, setpgid`` does not put ``fork`` or ``execvp`` in scope,
  ## and the import line is the only place that can change.
  ## ``code`` must already have been through ``importScanSource`` — NOT
  ## ``codeOnly``, which blanks the quoted path of an ``import "…"`` and so
  ## deletes the statement.
  let lines = code.splitLines()
  var idx = 0
  while idx < lines.len:
    let head = lines[idx].strip()
    var keyword = ""
    for k in ["import ", "from ", "include ", "export "]:
      if head.startsWith(k):
        keyword = k
        break
    if keyword.len == 0:
      inc idx
      continue
    var stmt = head[keyword.len .. ^1]
    while stmt.count('[') > stmt.count(']') or stmt.strip().endsWith(","):
      inc idx
      if idx >= lines.len: break
      stmt.add " " & lines[idx].strip()
    inc idx
    # ``from X import Y`` / ``import X except Y`` / ``import X as Y``.
    var symbols: seq[string] = @[]
    var symbolRestricted = false
    for sep in [" import ", " except ", " as "]:
      let p = stmt.find(sep)
      if p >= 0:
        if keyword == "from " and sep == " import " and not symbolRestricted:
          symbolRestricted = true
          for raw in stmt[p + sep.len .. ^1].split(','):
            let sym = raw.strip().strip(chars = {'`', '[', ']'})
            if sym.len > 0: symbols.add sym
        stmt = stmt[0 ..< p]
    var prefix = ""
    var cur = ""
    var inBracket = false
    template flush() =
      let item = cur.strip()
      cur = ""
      if item.len > 0:
        result.add ModuleImport(
          path: (if inBracket: prefix & item else: item),
          symbols: symbols, symbolRestricted: symbolRestricted)
    for ch in stmt:
      case ch
      of '[':
        prefix = cur.strip()
        cur = ""
        inBracket = true
      of ']':
        flush()
        prefix = ""
        inBracket = false
      of ',':
        flush()
      of ' ', '\t', '"':
        discard
      else:
        cur.add ch
    flush()

proc importedModulePaths(code: string): seq[string] =
  for imp in code.moduleImports: result.add imp.path

proc isModule(path, module: string): bool =
  ## A ``.nim`` SUFFIX IS STRIPPED FIRST, and that is HALF of what a quoted
  ## module path needs. Nim accepts one as a module spelling — ``import
  ## "../../../repro_runquota/src/repro_runquota.nim"`` compiles and puts
  ## the whole module in scope — and that path ends in ``/repro_runquota.nim``
  ## rather than ``/repro_runquota``. The OTHER half is that the import scan
  ## has to be able to see the literal at all; see ``strippedSource``. Both
  ## were missing, and together they made rule 5 — the one rule here that
  ## does not depend on the callee's name — one quotation mark away from
  ## being switched off for every module on the capability list, ``std/posix``
  ## included. Measured: a sibling module imported ``repro_runquota`` that
  ## way and the gate reported 10 [OK], exit 0.
  let p = if path.endsWith(".nim"): path[0 ..< path.len - 4] else: path
  p == module or p == "std/" & module or p.endsWith("/" & module)

proc importsModule(paths: seq[string]; module: string): bool =
  for p in paths:
    if p.isModule(module):
      return true
  false

proc exportedRoutineNames(code: string): HashSet[string] =
  ## Every exported routine name in a module source. ``code`` must already
  ## have been through ``codeOnly``, so a routine spelled inside a doc
  ## comment does not count as declared.
  ##
  ## BACKTICK-QUOTED NAMES ARE PART OF THE SURFACE. Nim lets any routine be
  ## declared with its name in backticks — ``proc `spawnAnything`*(…)`` is
  ## legal and callers write ``spawnAnything(…)`` — so a reader that skips
  ## every backticked declaration hands back a surface with holes in it, and
  ## the audit that rests on it passes while an exported way to start a
  ## child goes unclassified. This was a real hole: the earlier version
  ## dropped the line the moment it saw a backtick.
  ##
  ## What is still skipped, deliberately, is a backticked OPERATOR (`` `$`
  ## ``, `` `==` ``). An operator has no plain-identifier spelling, so it is
  ## not something a launch path can be invoked through by name and it is
  ## not part of the surface the name-based rules have to cover.
  ##
  ## ``macro`` IS ONE OF THE STARTERS, and leaving it out was the same hole
  ## in a second spelling. Nim has exactly seven routine keywords and a
  ## ``macro`` is as callable by name as a ``template`` — ``macro
  ## spawnAnything*(argv: untyped)`` expanding to a spawn is invisible to
  ## every count in this file, because the expansion never appears in the
  ## caller's source text. None of the audited modules exports one today,
  ## so adding the keyword changed no classification; what it changes is
  ## that adding one later is a red test rather than a silent hole.
  const Starters = ["proc ", "func ", "template ", "iterator ",
                    "converter ", "method ", "macro "]
  for line in code.splitLines():
    let head = line.strip()
    var rest = ""
    for s in Starters:
      if head.startsWith(s):
        rest = head[s.len .. ^1].strip()
        break
    if rest.len == 0: continue
    if rest[0] == '`':
      let close = rest.find('`', 1)
      if close <= 1: continue                   # unterminated, or ``` `` ```
      let quoted = rest[1 ..< close]
      var isIdent = quoted[0] notin {'0' .. '9'}
      for c in quoted:
        if not isIdentChar(c): isIdent = false
      if not isIdent: continue                  # `` `$` ``-style operator
      if close + 1 >= rest.len or rest[close + 1] != '*': continue
      result.incl quoted
    else:
      var stop = 0
      while stop < rest.len and isIdentChar(rest[stop]): inc stop
      if stop == 0: continue
      if stop >= rest.len or rest[stop] != '*': continue
      result.incl rest[0 ..< stop]

proc engineLibrarySources(repoRoot: string): seq[EngineSourceFile] =
  ## Every Nim source in the engine library, in a stable order, in both
  ## stripped forms: ``code`` for the counts (comments and literals blanked)
  ## and ``importCode`` for the import gate (comments blanked, literals
  ## kept). See ``strippedSource`` for why the two differ.
  for path in walkDirRec(repoRoot / EngineLibrarySourceDir):
    if not path.endsWith(".nim"): continue
    let text = readFile(path)
    result.add EngineSourceFile(
      relPath: path.relativePath(repoRoot).replace('\\', '/'),
      text: text,
      code: codeOnly(text),
      importCode: importScanSource(text))
  result.sort(proc (a, b: EngineSourceFile): int = cmp(a.relPath, b.relPath))

proc statExists(path: string): bool =
  ## ``fileExists`` is false for a unix socket (it is not a regular
  ## file), so daemon readiness has to be probed with a stat.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc compileFixture(sourcePath, outputPath: string) =
  let res = execCmdEx("cc " & quoteShell(sourcePath) & " -o " &
    quoteShell(outputPath))
  if res.exitCode != 0:
    echo res.output
  doAssert res.exitCode == 0, "fixture compile failed"

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false
proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-hm4", "hm4-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

type DaemonHandle = object
  process: Process
  socket: string
  started: bool

proc startRunQuotaDaemon(repoRoot: string; cpuMilli: int): DaemonHandle =
  ## Real runquotad over a real unix socket. ``cpuMilli`` is the whole
  ## host budget: L3b needs it small enough that two concurrent actions
  ## cannot both be granted at once.
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = getTempDir() / ("repro-hm4-rq-" & $getCurrentProcessId() &
    ".sock")
  removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", $cpuMilli,
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  for _ in 0 ..< 400:
    if statExists(socketPath):
      putEnv("RUNQUOTA_SOCKET", socketPath)
      return DaemonHandle(process: daemon, socket: socketPath, started: true)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear: " & socketPath)

proc stop(handle: var DaemonHandle) =
  if not handle.started: return
  handle.process.terminate()
  discard handle.process.waitForExit()
  handle.process.close()
  removeFile(handle.socket)
  delEnv("RUNQUOTA_SOCKET")
  handle.started = false

proc configFor(lp: LaunchPath; repoRoot, cacheRoot: string):
    BuildEngineConfig =
  # The RunQuota "helper CLI" is the ``repro`` image itself: L2 spawns
  # ``repro __repro-runquota-helper …`` (helperCliArgs, repro_runquota.nim
  # :496). The standalone ``runquota`` binary is a status/acquire CLI and
  # does NOT accept that argv.
  result = BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: monitorTools(repoRoot).monitorCliPath,
    monitorCliPath: monitorTools(repoRoot).monitorCliPath,
    monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
    maxParallelism: 2'u32,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    # In-process hosting is OPT-IN and off in production (see
    # ``BuildEngineConfig.hostMonitorInProcess``). It is requested here for
    # EVERY launch path, not only for L1, and that is what keeps the negative
    # half of the oracle honest: with the switch on across the board, the only
    # thing deciding who hosts is whether the ENGINE is the process that
    # spawns. A change that let L2/L3/L3b host would show up as a
    # ``.host.stdout`` under their cache roots rather than being masked by a
    # config they never set.
    hostMonitorInProcess: true)
  case lp.kind
  of lpBypassRunQuota:
    result.bypassRunQuota = true
  of lpRunQuotaHelper:
    discard          # neither bypass nor inline: the helper-process path
  of lpInlineRunQuota, lpInlineRunQuotaQueued:
    result.inlineRunQuota = true

proc monitoredFixtureAction(id, fixtureBin, marker, outPath, workRoot: string;
                            holdMs: int; cpuMilli: uint32): BuildAction =
  action(id, [fixtureBin, marker, outPath, $holdMs],
    cwd = workRoot,
    inputs = [marker.extractFilename],
    outputs = [outPath.extractFilename],
    commandStatsId = id,
    cpuMilli = cpuMilli,
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    dependencyPolicy = automaticMonitorGatheringPolicy())

proc mentionsPath(paths: seq[string]; wanted: string): bool =
  for p in paths:
    if p == wanted: return true
  false

proc hasTrace(run: BuildRunResult; event, detail: string): bool =
  for item in run.trace:
    if item.event == event and item.detail == detail:
      return true
  false

proc resultById(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id: return item
  raise newException(ValueError, "no result for " & id)

## ---------------------------------------------------------------------
## Cross-path evidence identity.
##
## ``checkMonitoredEvidence`` below asserts each path's evidence is
## non-empty and complete. That is weaker than what is actually true:
## for the same fixture, all four launch paths produce the SAME
## evidence — one read, no writes recorded as differences, no
## diagnostics. Asserting the identity rather than each half separately
## costs nothing and turns "monitored" into "monitored the same way",
## which is the property a change to how the monitor is hosted has to
## preserve.
##
## Everything that legitimately differs between cases is a path prefix
## or a per-case filename, so those are substituted out and the whole
## ``PathSetEvidence`` is rendered to one comparable string. Rendering
## every field (not just ``monitorReads``) is deliberate: a change that
## moved a path from ``monitorReads`` into ``monitorProbes`` on one path
## only would otherwise pass.
## ---------------------------------------------------------------------
var recordedEvidence: seq[tuple[label, shape: string]] = @[]

proc evidenceShape(res: ActionResult;
                   subs: seq[(string, string)]): string =
  proc render(name: string; paths: seq[string]): string =
    var items: seq[string] = @[]
    for p in paths:
      var value = p
      for sub in subs:
        value = value.replace(sub[0], sub[1])
      items.add value
    items.sort()
    name & "=[" & items.join(" ") & "]"

  let ev = res.evidence
  @[
    render("declaredInputs", ev.declaredInputs),
    render("declaredOutputs", ev.declaredOutputs),
    render("depfileInputs", ev.depfileInputs),
    render("monitorReads", ev.monitorReads),
    render("monitorWrites", ev.monitorWrites),
    render("monitorProbes", ev.monitorProbes),
    render("diagnostics", ev.diagnostics)
  ].join("\n")

proc caseSubstitutions(tempRoot, caseDir, workRoot, marker,
                       outPath: string): seq[(string, string)] =
  ## Longest and most specific first — the absolute forms have to be
  ## consumed before the directory prefixes they contain.
  result = @[
    (expandFilename(marker), "<marker>"),
    (marker, "<marker>"),
    (outPath, "<out>"),
    (workRoot, "<work>"),
    (caseDir, "<case>"),
    (tempRoot, "<temp>"),
    (marker.extractFilename, "<marker>"),
    (outPath.extractFilename, "<out>")
  ]

proc helperResultFilesWritten(cacheRoot: string): int =
  ## Only the L2 helper-process path writes a lease result JSON into
  ## ``<cacheRoot>/runquota-results/`` — ``startRunQuotaProcess`` passes
  ## ``--result <path>`` on the helper argv and reads it back in
  ## ``finishRunQuotaProcess``. Bypass and inline launches never do, so
  ## the presence or absence of these files distinguishes L2 from L1/L3
  ## at runtime rather than by trusting the config.
  let dir = cacheRoot / "runquota-results"
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      inc result

proc inProcessHostCaptureFiles(cacheRoot: string): int =
  ## In-Process-Monitor-Hosting HM-4. The in-process host redirects the
  ## monitored child's descriptors 1 and 2 into
  ## ``<cacheRoot>/actions/<stem>.host.stdout`` / ``.host.stderr`` across the
  ## spawn, because io-mon spawns with ``poParentStreams`` and the child would
  ## otherwise inherit the ENGINE's terminal. Nothing else in the engine writes
  ## a ``.host.stdout``, so their presence is a runtime witness that this
  ## action was hosted IN-PROCESS rather than by a ``repro internal io
  ## monitor`` child — which no field of ``ActionResult`` reports, because the
  ## whole point is that the two are indistinguishable downstream.
  let dir = cacheRoot / "actions"
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".host.stdout"):
      inc result

## ---------------------------------------------------------------------
## Path-identity oracle: prove the case really took the launch path it
## is named for, instead of quietly degrading to another one and passing
## for the wrong reason. ``runQuotaBackend`` alone cannot do this — on a
## granted lease it carries the runquota PROCESS backend name
## (``posix-fork-exec-poll``), not the engine's path label.
##
## Since HM-4 it also pins WHICH HOSTING MECHANISM ran, in both
## directions: L1 must be hosted in-process, and L2/L3/L3b must not be.
## Without the negative half, "every path hosts in-process" and "no path
## does" would both satisfy a check written only for L1.
## ---------------------------------------------------------------------
template checkTookLaunchPath(lp: LaunchPath; run: BuildRunResult;
                             res: ActionResult; cacheRoot: string) =
  case lp.kind
  of lpBypassRunQuota:
    check run.runQuotaBypassed
    check res.runQuotaBackend == "runquota-bypass"
    check res.leaseId == 0'u64
    check helperResultFilesWritten(cacheRoot) == 0
    if inProcessHostCaptureFiles(cacheRoot) == 0:
      echo "[", lp.name, "] no in-process host stdio capture under ",
        cacheRoot / "actions",
        ": this action was monitored by a `repro internal io monitor` child,",
        " not by the engine. HM-4 regressed on L1."
    check inProcessHostCaptureFiles(cacheRoot) > 0
  of lpRunQuotaHelper:
    check not run.runQuotaBypassed
    check res.leaseId != 0'u64
    check helperResultFilesWritten(cacheRoot) > 0
    check inProcessHostCaptureFiles(cacheRoot) == 0
  of lpInlineRunQuota, lpInlineRunQuotaQueued:
    check not run.runQuotaBypassed
    check res.leaseId != 0'u64
    check helperResultFilesWritten(cacheRoot) == 0
    check inProcessHostCaptureFiles(cacheRoot) == 0

## ---------------------------------------------------------------------
## The shared oracle: this action's dependency evidence proves the child
## was monitored.
##
## This MUST be a template, not a proc. ``unittest.check`` writes to
## ``testStatusIMPL``, which the ``test`` template declares as a local —
## inside a proc the assignment binds elsewhere and a failed ``check``
## prints its diagnostic while the case still reports ``[OK]``. That was
## observed on this very file during development: the L2 case printed
## three failed checks and passed. A silently-passing coverage test is
## the exact failure this file exists to prevent, one level up.
## ---------------------------------------------------------------------
template checkMonitoredEvidence(res: ActionResult; markerPath, label: string) =
  if res.status != asSucceeded:
    echo "[", label, "] action failed exit=", res.exitCode,
      " backend=", res.runQuotaBackend,
      "\n  diagnostics: ", res.evidence.diagnostics.join("; "),
      "\n  stdout: ", res.stdout, "\n  stderr: ", res.stderr
  check res.status == asSucceeded

  # The monitor was wired: a depfile was selected and written.
  check res.monitorDepfilePath.len > 0
  check fileExists(res.monitorDepfilePath)

  # PRIMARY ASSERTION. The child's real open()/read() of the marker
  # reached the engine's evidence. This is the property "this launch
  # path is monitored"; it is false for an unmonitored path no matter
  # how healthy the rest of the run looks.
  if not mentionsPath(res.evidence.monitorReads, markerPath):
    echo "[", label, "] monitorReads (", res.evidence.monitorReads.len,
      " entries) did not contain ", markerPath,
      "\n  diagnostics: ", res.evidence.diagnostics.join("; ")
  check mentionsPath(res.evidence.monitorReads, markerPath)

  # And the evidence is COMPLETE, not merely non-empty.
  for diagnostic in res.evidence.diagnostics:
    check not diagnostic.contains("monitor depfile read failed")
    check not diagnostic.contains(
      "requires monitor evidence but no RMDF path is selected")

suite "every_launch_path_is_monitored":

  test "the enumeration matches the engine source":
    ## A list nobody tested is not an enumeration. This re-derives the
    ## launch-path set from the engine source text, so a fifth spawn
    ## site — or a second caller of either monitor seam — cannot land
    ## without this file being revisited.
    let src = readFile(getCurrentDir() / EngineSource)

    # SEAM 1 (argv): the monitor decision is taken in exactly one proc,
    # called from exactly one site. Since HM-4 that proc also decides WHO
    # hosts, which is why the call now carries the extra argument.
    check countOccurrences(src, "proc monitoredAction(") == 1
    check countOccurrences(src,
      "monitoredAction(action, config, cacheRoot,") == 1

    # SEAM 2 (argv+env contract): one definition + FOUR uses. Three are the
    # non-deferred launch paths (L3b reuses L3's spec); the fourth is the
    # in-process host, which takes the same contract with the shell umask
    # wrapper switched off — see ``preparedRunQuotaCommand``'s doc-comment
    # for why that wrapper cannot survive into a monitored tree.
    check countOccurrences(src, "preparedRunQuotaCommand(") == 5

    # SEAM 3 (HM-4, hosting): the engine becomes io-mon's host in exactly
    # one proc, called from exactly one site, and the three decomposed
    # lifecycle calls appear exactly once each. A launch path that acquired
    # its own host — or L1 losing the one it has — moves one of these.
    check countOccurrences(src, "proc startMonitorHost(") == 1
    check countOccurrences(src,
      "startMonitorHost(monitorHosts, plan.action, config,") == 1
    check countOccurrences(src, "startMonitor(monitorHostRequest(") == 1
    check countOccurrences(src, "pollMonitor(pool.handles[slot])") == 1
    check countOccurrences(src, "finishMonitor(move(pool.handles[slot]))") == 1

    # Every spawn site NAMED IN THE TABLE really exists in the engine —
    # so a row cannot describe a path that was deleted or renamed.
    for lp in EnumeratedLaunchPaths:
      if countOccurrences(src, lp.spawnSite) == 0:
        echo "enumerated launch path ", lp.name,
          " names a spawn site that is not in the engine: ", lp.spawnSite
      check countOccurrences(src, lp.spawnSite) > 0

    # Every enumerated spawn site is present, defined once and called
    # once. (The bare proc names also appear in prose comments, so the
    # pins below use the definition and call-site forms rather than a
    # raw name count, which would move whenever a comment is reworded.)
    check countOccurrences(src, "proc startBypassRunQuotaProcess(") == 1
    check countOccurrences(src,
      "startBypassRunQuotaProcess(plan.action, config)") == 1          # L1
    check countOccurrences(src, "proc startRunQuotaProcess(") == 1
    check countOccurrences(src,
      "startRunQuotaProcess(plan.action, config, resultPath)") == 1    # L2
    check countOccurrences(src, "offerWithRunQuotaBatch(") == 1        # L3
    check countOccurrences(src, "startGrantedWithRunQuota(") == 1      # L3b

    # The deliberately-unmonitored paths still have the shape this
    # enumeration recorded for them.
    check countOccurrences(src, "config.brokerSpawn(req)") == 1        # L4
    check countOccurrences(src, "executeBuiltinAction(plan.action)") == 1  # L5

  test "no launch path exists outside the enumeration":
    ## The scan above is keyed on ONE file, which makes it a ratchet on
    ## that file rather than on the launch surface. A helper added to a
    ## sibling module in the same library — building its own
    ## ``ReproCommandSpec`` because the shared builder is private,
    ## dropping the monitor wrapper, spawning through ``startDirect`` —
    ## leaves every count above untouched and ships an unmonitored,
    ## successful, cache-publishing action. That was not hypothetical:
    ## it was built, and the suite stayed green.
    ##
    ## So this case scans the whole of ``libs/repro_build_engine/src``
    ## and pins five things at once:
    ##
    ##   1. how many times each pinned spawn primitive is called,
    ##      library-wide;
    ##   2. that every one of those calls is in the engine module the
    ##      enumeration is written from, so a spawn in a new file is a
    ##      failure even when the total happens to be preserved;
    ##   3. that no pinned name is REFERENCED without being called, so an
    ##      alias cannot move the call under a name no count is watching;
    ##   4. that no identifier merely ENDING in a spawn primitive's name
    ##      exists, so a suffixed spelling cannot occupy the same role
    ##      under a name no count is watching;
    ##   5. that only the engine module imports a module a child can be
    ##      started through at all — the one rule here that does not
    ##      depend on knowing the callee's name.
    ##
    ## Comments and string literals are blanked out first, so all five
    ## are statements about code.
    let sources = engineLibrarySources(getCurrentDir())
    check sources.len >= 1

    # NOT VACUOUS. The scanner is only meaningful if it really does drop
    # comments and literals, so that is checked against a fixture rather
    # than assumed — a stripper that silently returned its input would
    # make rule 3 pass on every prose mention of a primitive.
    const StripperFixture = "a # startProcess(\n" &
      "b\"startProcess(\" '\\'' c #[ startProcess( ]# d\n"
    let stripped = codeOnly(StripperFixture)
    check stripped.len == StripperFixture.len
    check stripped.count('\n') == StripperFixture.count('\n')
    check not stripped.contains("startProcess")
    check stripped.contains("a")
    check stripped.contains("b")
    check stripped.contains("d")

    var calls = initCountTable[string]()
    var refs = initCountTable[string]()
    var callSites = initTable[string, seq[string]]()
    var refSites = initTable[string, seq[string]]()
    for source in sources:
      for (name, called) in source.code.wholeIdentifiers:
        refs.inc(name)
        if not refSites.hasKey(name): refSites[name] = @[]
        if source.relPath notin refSites[name]:
          refSites[name].add source.relPath
        if called:
          calls.inc(name)
          if not callSites.hasKey(name): callSites[name] = @[]
          if source.relPath notin callSites[name]:
            callSites[name].add source.relPath

    # 1 + 2 + 3. Every pinned way of starting a child, counted across the
    # library and located. A new launch path that uses one of these names
    # moves its count no matter which file it is written in; if it uses a
    # name the engine does not use today it moves that name's zero.
    for primitive in SpawnPrimitives:
      let found = calls.getOrDefault(primitive.name)
      if found != primitive.expected:
        echo "spawn primitive `", primitive.name, "` is called ", found,
          " time(s) in ", EngineLibrarySourceDir, ", expected ",
          primitive.expected,
          (if primitive.why.len > 0: " (" & primitive.why & ")" else: ""),
          "\n  in: ", callSites.getOrDefault(primitive.name).join(", "),
          "\n  A launch path was added, removed or moved. Revisit THE",
          " ENUMERATION at the top of this file before changing this",
          " number."
      check found == primitive.expected

      for site in callSites.getOrDefault(primitive.name):
        if site != EngineModuleRelPath:
          echo "spawn primitive `", primitive.name, "` is called from ",
            site, ", which is not the engine module the launch-path",
            " enumeration is written from (", EngineModuleRelPath, ")."
        check site == EngineModuleRelPath

      # 3. No bare reference. Every appearance of the name must BE one of
      # the calls counted above; anything else is the name being handed
      # around as a value, which is how a launch path gets invoked under
      # a spelling no count is watching.
      let mentioned = refs.getOrDefault(primitive.name)
      if mentioned != found:
        echo "spawn primitive `", primitive.name, "` is named ", mentioned,
          " time(s) in ", EngineLibrarySourceDir, " but called only ",
          found, " time(s)",
          "\n  in: ", refSites.getOrDefault(primitive.name).join(", "),
          "\n  A bare reference is an ALIAS: `let f = ", primitive.name,
          "` lets a launch path call it under a different name while",
          " every count above stays flat. Call it directly, or give the",
          " alias its own row."
      check mentioned == found

    # The argv+env contract. A launch path outside the engine module
    # cannot reach the private builder, so it must construct its own
    # spec — which shows up here even if it reuses a spawn primitive
    # whose total it managed to keep flat.
    let specs = calls.getOrDefault("ReproCommandSpec")
    if specs != CommandSpecConstructions:
      echo "ReproCommandSpec is constructed ", specs, " time(s) in ",
        EngineLibrarySourceDir, ", expected ", CommandSpecConstructions,
        "\n  in: ", callSites.getOrDefault("ReproCommandSpec").join(", "),
        "\n  All monitored launches must take their argv+env from",
        " `preparedRunQuotaCommand`."
    check specs == CommandSpecConstructions
    for site in callSites.getOrDefault("ReproCommandSpec"):
      check site == EngineModuleRelPath

    # 4. Anchoring. Nothing may be named like a spawn primitive without
    # being one of the pinned rows. ``ReproCommandSpec`` ends in
    # ``commandSpec`` and is exempt because it has its own pin directly
    # above; anything ELSE ending that way — a second spec type, a
    # ``buildCommandSpec`` helper — is not, which is the point of adding
    # the tail.
    var pinned = initHashSet[string]()
    for primitive in SpawnPrimitives: pinned.incl primitive.name
    pinned.incl "ReproCommandSpec"
    var evaders: seq[string] = @[]
    for name in refs.keys:
      if name in pinned: continue
      let lowered = name.toLowerAscii
      for tail in SpawnNameTails:
        if lowered.endsWith(tail):
          evaders.add name & " (in " &
            refSites.getOrDefault(name).join(", ") & ")"
          break
    if evaders.len > 0:
      echo "identifier(s) named after a spawn primitive but pinned by no",
        " count: ", evaders.join(", "),
        "\n  Add the name to `SpawnPrimitives` with the number of calls",
        " the enumeration allows it."
    check evaders.len == 0

    # 5. CAPABILITY. Rules 1-4 are all rules about NAMES, and a name-based
    # rule can only ever cover the names somebody thought of — which is
    # how `execCmd` and `execProcesses` stayed uncounted while being one
    # call away in a module this library already imports. This rule does
    # not need the callee's name: a module that can start a child has to
    # be imported before anything in it can be called, so only the engine
    # module may import one.
    #
    # For a `caImportAllowlist` module the rule goes one step further and
    # is applied to the SYMBOLS, because "the engine module may import
    # std/posix" would otherwise hand the engine module `fork` and
    # `execvp` with nothing watching. The import must be a
    # `from <module> import <names>` and every name must be on the row's
    # allowlist.
    var surfaceByKey = initTable[string, CapabilitySurface]()
    for surface in capabilitySurfaces():
      surfaceByKey[surface.key] = surface

    for source in sources:
      # NOT `source.code`: see `strippedSource`. A quoted module path is a
      # string literal, and blanking it deletes the import.
      let imports = source.importCode.moduleImports
      for capability in SpawnCapabilityModules:
        for imported in imports:
          if not imported.path.isModule(capability.path): continue
          let allowed = capability.engineImports and
                        source.relPath == EngineModuleRelPath
          if not allowed:
            echo source.relPath, " imports `", capability.path,
              "`, which can start a child process (", capability.why, ").",
              (if capability.engineImports:
                 "\n  Only " & EngineModuleRelPath & " — the module the" &
                 " launch-path enumeration above is written from — may" &
                 " import it."
               else:
                 "\n  No module in this library may import it directly, the" &
                 " engine module included: nothing here needs it today, and" &
                 " what it offers is a way to start a child that the" &
                 " enumeration above does not describe."),
              "\n  A launch path anywhere else in this library is",
              " unreachable from the enumeration and will not be monitored",
              " by the wrapper the enumeration documents."
          check allowed

          if not surfaceByKey.hasKey(capability.path): continue
          let surface = surfaceByKey[capability.path]
          if surface.audit != caImportAllowlist: continue

          if not imported.symbolRestricted:
            echo source.relPath, " imports all of `", capability.path,
              "`. This module is gated on its IMPORT LINE rather than on a",
              " classification of its exports (it has far too many), so it",
              " may only be reached through `from ", capability.path,
              " import <names>` with every name on the row's allowlist in",
              " `capabilitySurfaces`."
          check imported.symbolRestricted

          for symbol in imported.symbols:
            if symbol notin surface.allowedSymbols:
              echo source.relPath, " imports `", symbol, "` from `",
                capability.path, "`, which is not on that module's",
                " allowlist (", surface.allowedSymbols.join(", "), ").",
                "\n  This is the capability gate for a module whose export",
                " surface is not classified name by name. Decide whether `",
                symbol, "` can start a child process: if it can, it needs a",
                " row in `SpawnPrimitives` and a place in the enumeration at",
                " the top of this file; if it cannot, add it to",
                " `allowedSymbols`."
            check symbol in surface.allowedSymbols

    # And the gate is not vacuous where it claims the engine module is the
    # exception: that module really does import those capabilities, so
    # "only the engine module" is a restriction and not an empty set.
    let engineImports = block:
      var found: seq[string] = @[]
      for source in sources:
        if source.relPath == EngineModuleRelPath:
          found = source.importCode.importedModulePaths
      found
    check engineImports.len > 0
    for capability in SpawnCapabilityModules:
      if not capability.engineImports: continue
      if not engineImports.importsModule(capability.path):
        echo "the engine module no longer imports `", capability.path,
          "`; if that capability is genuinely gone, drop its row from",
          " `SpawnCapabilityModules` and `capabilitySurfaces` rather",
          " than leaving a gate that can never fire."
      check engineImports.importsModule(capability.path)

  test "the spawn table still covers every way in":
    ## THE AUDIT, and the reason the case above is trustworthy.
    ##
    ## ``SpawnPrimitives`` is an allowlist of names, and an allowlist is
    ## only as good as the audit that produced it. This one was wrong for
    ## a while in a way that was invisible from inside: ``execCmd`` and
    ## ``execProcesses`` are exported by ``std/osproc``, which the engine
    ## already imports, and neither name is a substring of a name that WAS
    ## on the list — ``execCmd(`` is not ``execCmdEx(``, ``execProcesses(``
    ## is not ``execProcess(``. A helper that ran an action's raw argv
    ## through ``execCmd`` therefore started an unmonitored child while
    ## every pin stayed exactly where it was.
    ##
    ## Remembering to re-read ``std/osproc`` after each Nim upgrade is not
    ## a control. So this case reads it — and every other module a spawn
    ## is reachable through — and requires their entire exported routine
    ## surface to be classified here as either putting a child process on
    ## the road or not. An upstream release that adds an exported
    ## procedure fails this case with the new name in the message, whether
    ## or not it spawns; whoever bumps the toolchain has to say which. And
    ## every name classified as spawning must carry a row in
    ## ``SpawnPrimitives``, so a classification cannot be recorded here and
    ## then not enforced there.
    var pinned = initHashSet[string]()
    for primitive in SpawnPrimitives: pinned.incl primitive.name

    let surfaces = capabilitySurfaces()

    ## THE LINK BETWEEN THE TWO LISTS, and the assertion whose absence is
    ## the reason this audit read FOUR modules while calling itself an audit
    ## of every module a spawn is reachable through.
    ##
    ## ``SpawnCapabilityModules`` said five and ``capabilitySurfaces``
    ## returned four; the missing one was ``repro_runquota``, which is where
    ## `startDirect` and both RunQuota launch wrappers live. Nothing
    ## compared the lists, so the surface simply was not read, and an
    ## exported spawn helper added to that module — called from the engine
    ## at the L1 bypass site — started a real unmonitored child with every
    ## case green.
    ##
    ## This is the load-bearing part of that fix rather than the row
    ## itself: without it the SIXTH capability module is one careless commit
    ## from repeating it, and it would be just as silent.
    var moduleKeys = initHashSet[string]()
    for capability in SpawnCapabilityModules: moduleKeys.incl capability.path
    var surfaceKeys = initHashSet[string]()
    for surface in surfaces: surfaceKeys.incl surface.key

    if surfaces.len != SpawnCapabilityModules.len:
      echo "`capabilitySurfaces` returns ", surfaces.len, " surface(s) for ",
        SpawnCapabilityModules.len, " capability module(s).",
        "\n  Every module the import gate calls spawn-capable must have",
        " its exports read here, or the audit is an audit of a subset and",
        " says so nowhere."
    check surfaces.len == SpawnCapabilityModules.len
    check surfaceKeys.len == surfaces.len          # no duplicate keys

    let unaudited = (moduleKeys - surfaceKeys).toSeq.sorted
    if unaudited.len > 0:
      echo "capability module(s) with no surface in `capabilitySurfaces`: ",
        unaudited.join(", "),
        "\n  Their exported routines are never read, so a new way to start",
        " a child in one of them is invisible to this file."
    check unaudited.len == 0

    let orphaned = (surfaceKeys - moduleKeys).toSeq.sorted
    if orphaned.len > 0:
      echo "surface(s) in `capabilitySurfaces` with no row in",
        " `SpawnCapabilityModules`: ", orphaned.join(", "),
        "\n  The import gate does not cover them, so the classification is",
        " describing a module nothing restricts."
    check orphaned.len == 0

    let repoRoot = getCurrentDir()
    for surface in surfaces:
      let root = capabilitySurfaceRoot(surface.key, repoRoot)
      let path = root / surface.sourceRel
      if not fileExists(path):
        echo "cannot audit `", surface.key, "`: no source at ", path,
          "\n  This test compiled, so the module IS on the compiler's",
          " search path; fix the resolution in `capabilitySurfaceRoot`",
          " rather than deleting the audit."
      check fileExists(path)
      if not fileExists(path): continue

      let declared = exportedRoutineNames(codeOnly(readFile(path)))

      # NOT VACUOUS. Key equality with `SpawnCapabilityModules` says the
      # right MODULES are audited; it says nothing about whether
      # `sourceRel` points at the right FILE. A surface that keeps its key
      # and points `sourceRel` at a file with no exported routines — while
      # classifying nothing — leaves `unclassified` and `vanished` both
      # empty and reads the module not at all, with both lists still in
      # perfect bijection. That was measured, paired with an exported
      # spawn helper added to `repro_runquota`: the whole gate stayed
      # green. A capability module has a surface by definition, so requiring
      # the read to have found one closes it.
      if declared.len == 0:
        echo "`", surface.key, "`: reading ", path,
          " found NO exported routines, so this row audits nothing.",
          "\n  `sourceRel` is pointing somewhere that is not the module,",
          " and key equality with `SpawnCapabilityModules` cannot see that."
      check declared.len > 0

      var classified = initHashSet[string]()
      for name in surface.spawning: classified.incl name
      for name in surface.inert: classified.incl name

      if surface.audit == caFullSurface:
        let unclassified = (declared - classified).toSeq.sorted
        if unclassified.len > 0:
          echo "`", surface.key, "` (", path, ") exports ",
            unclassified.join(", "),
            ", which this file has not classified.",
            "\n  Decide for each name whether it can start a child",
            " process. If it can, add it to `spawning` AND give it a row",
            " in `SpawnPrimitives` with the number of calls this library",
            " is allowed. If it cannot, add it to `inert`. Leaving it out",
            " is what made `execCmd` invisible."
        check unclassified.len == 0
      else:
        # `caImportAllowlist`: the module's surface is deliberately NOT
        # enumerated (`std/posix` exports 492 routines), so there is no
        # `unclassified` check to make here. What replaces it is rule 5's
        # symbol gate, and the two halves are kept honest against each
        # other: every routine this row classifies has to be a symbol the
        # row would actually let through.
        for name in surface.spawning & surface.inert:
          if name notin surface.allowedSymbols:
            echo "`", surface.key, "` classifies `", name, "` but does not",
              " allow it to be imported, so the classification describes",
              " nothing the gate can ever see."
          check name in surface.allowedSymbols

      let vanished = (classified - declared).toSeq.sorted
      if vanished.len > 0:
        echo "`", surface.key, "` (", path, ") no longer exports ",
          vanished.join(", "),
          "\n  Remove the stale name so the classification keeps",
          " describing the module it claims to describe."
      check vanished.len == 0

      # Every spawning name is actually enforced by the scan above.
      for name in surface.spawning:
        if name notin pinned:
          echo "`", name, "` is classified as a way to start a child in `",
            surface.key, "` but has no row in `SpawnPrimitives`, so",
            " nothing counts it."
        check name in pinned

  test "the io-monitor subcommand argv agrees across all of its mirrors":
    ## The CLI subcommand ``repro internal io monitor`` is the debugging
    ## entry point and must keep working. The triple is spelled SIX times
    ## under ``libs/``, five of them hand-written literals rather than
    ## uses of a shared constant, because the modules that need it sit on
    ## both sides of the dependency graph and cannot import one another.
    ## A rename in one place alone is not a compile error — it is a
    ## silently unmonitored dev session, or worse.
    ##
    ## The dangerous one is site 6. There the literal is COMPARED against
    ## the configured ``monitorCliArgs`` to decide WHICH BINARY to launch;
    ## a rename makes the comparison simply stop matching and the fallback
    ## branch is taken, with nothing anywhere reporting a problem.
    let root = getCurrentDir()
    const Expected = ["internal", "io", "monitor"]
    const Triple = "@[\"internal\", \"io\", \"monitor\"]"

    # 1. The shared test-support constant the engine is configured with,
    #    pinned by VALUE (so the rest of this suite cannot be driving a
    #    different argv than production) and by text.
    check ioMonitorCliArgs == @Expected
    let testSupport = readFile(root /
      "libs/repro_test_support/src/repro_test_support.nim")
    check countOccurrences(testSupport,
      "ioMonitorCliArgs* = " & Triple) == 1

    # 2. The definition in repro_cli_support.
    let cliSupport = readFile(root /
      "libs/repro_cli_support/src/repro_cli_support.nim")
    check countOccurrences(cliSupport,
      "const internalIoMonitorArgs* = " & Triple) == 1

    # 3. The dispatcher that has to recognise it, both for the self-spawn
    #    (``internal``) and for the operator-facing (``debug``) spelling.
    #    All three words are pinned, in both arms: the CLI falls through
    #    to the unknown-subcommand path (exit 2) if any one of them stops
    #    matching, which is how a renamed triple surfaces as a failed
    #    action rather than as a compile error.
    check countOccurrences(cliSupport,
      "args[0] == \"internal\" and args[1] == \"io\" and") == 1
    check countOccurrences(cliSupport,
      "args[0] == \"debug\" and") >= 1
    check countOccurrences(cliSupport,
      "args[1] == \"io\" and args[2] == \"monitor\"") == 1   # the debug arm
    # Two arms, so two ``monitor`` word tests: the self-spawn arm and the
    # operator-facing one.
    check countOccurrences(cliSupport, "args[2] == \"monitor\"") == 2

    # 4. The hand-copied literal in the dev-session supervisor.
    let devSession = readFile(root /
      "libs/repro_cli_support/src/repro_cli_support/dev_session.nim")
    check countOccurrences(devSession,
      "monitorCliArgs: " & Triple) == 1

    # 5. The profile-compile edge. ``repro_profile_compile`` sits BELOW
    #    ``repro_cli_support`` in the dependency graph and cannot import
    #    the constant without a cycle, so it mirrors the literal. Without
    #    these args the monitored argv degenerates to
    #    ``repro --depfile <path> -- <cmd>`` and every profile-compile
    #    action fails under the automatic-monitor policy.
    let profileEdge = readFile(root /
      "libs/repro_profile_compile/src/repro_profile_compile/edge.nim")
    check countOccurrences(profileEdge,
      "const ProfileCompileMonitorCliArgs* = " & Triple) == 1

    # 6. The dev-env engine, where the literal is a PREDICATE rather than
    #    a value: it decides whether the configured monitor CLI is the
    #    consolidated ``repro`` image (reuse it) or something else (fall
    #    back to the public CLI path). Renaming the triple does not fail
    #    to compile and does not fail to run — it quietly changes which
    #    binary the provider-compile edge is launched with. Both halves
    #    are pinned: the literal, and the comparison that consumes it.
    let devEnvEngine = readFile(root /
      "libs/repro_dev_env_engine/src/repro_dev_env_engine.nim")
    check countOccurrences(devEnvEngine,
      "let internalMonitorArgs = " & Triple) == 1
    check countOccurrences(devEnvEngine,
      "config.monitorCliArgs == internalMonitorArgs") == 1

    # And no SEVENTH spelling has appeared unpinned. Five of the six
    # sites spell the triple as a sequence literal and are swept here;
    # the sixth is the dispatcher's element-wise comparison (site 3),
    # which is pinned by text above because it is not a literal.
    const LiteralSpellings = 5
    var spelled = 0
    var spelledIn: seq[string] = @[]
    for path in walkDirRec(root / "libs"):
      if not path.endsWith(".nim"): continue
      let rel = path.relativePath(root).replace('\\', '/')
      if "/tests/" in rel: continue
      let hits = countOccurrences(readFile(path), Triple)
      if hits > 0:
        spelled += hits
        spelledIn.add rel & " x" & $hits
    if spelled != LiteralSpellings:
      echo "the `internal io monitor` argv triple is spelled as a literal ",
        spelled, " time(s) under libs/, expected ", LiteralSpellings, ":\n  ",
        spelledIn.join("\n  "),
        "\n  Every spelling is a place a rename can silently diverge.",
        " Pin the new one above."
    check spelled == LiteralSpellings

  when defined(linux) or defined(macosx):
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-hm4-launch-paths", "")
    let fixtureSource = tempRoot / "fixture.c"
    let fixtureBin = tempRoot / "fixture"
    writeFile(fixtureSource, FixtureSource)
    compileFixture(fixtureSource, fixtureBin)

    # One host budget of 1000 cpu-milli; the L3b actions ask for 800
    # each, so the daemon can grant exactly one at a time and the other
    # comes back `rqokQueued`.
    var daemon: DaemonHandle
    var runQuotaError = ""
    try:
      daemon = startRunQuotaDaemon(repoRoot, cpuMilli = 1000)
    except CatchableError as err:
      runQuotaError = err.msg

    ## The monitored launch paths, parameterised over the enumeration.
    ## Looping over ``EnumeratedLaunchPaths`` rather than hand-copying a
    ## case per row is deliberate: a path added to the enumeration is
    ## exercised automatically, so it is not possible to extend the list
    ## and forget the test.
    for launchPath in EnumeratedLaunchPaths:
      let lp = launchPath
      test "monitored evidence is complete via " & lp.name:
        if lp.needsRunQuota and runQuotaError.len > 0:
          # Named, not quietly omitted.
          echo "[fixture N/A] ", lp.name,
            " needs a real runquota/runquotad: ", runQuotaError
          skip()
        else:
          let caseDir = tempRoot / ("case-" & $ord(lp.kind))
          let workRoot = caseDir / "work"
          createDir(workRoot)
          let cacheRoot = caseDir / ".repro-cache"
          let config = configFor(lp, repoRoot, cacheRoot)

          if lp.kind == lpInlineRunQuotaQueued:
            # Two actions, 800 cpu-milli each against a 1000-milli host:
            # the batch offer grants one and QUEUES the other, so the
            # queued one is spawned from the deferred site (:5528)
            # instead of from the batch flush.
            var actions: seq[BuildAction] = @[]
            for i in 0 .. 1:
              let marker = workRoot / ("marker-" & $i & ".txt")
              writeFile(marker, "hm4 marker payload " & $i & "\n")
              actions.add monitoredFixtureAction("queued-" & $i, fixtureBin,
                marker, workRoot / ("out-" & $i & ".txt"), workRoot,
                holdMs = 400, cpuMilli = 800'u32)
            let run = runBuild(graph(actions), config)
            check run.results.len == 2

            # The deferred site really was exercised: the queued
            # candidate is traced as launched by a grant, which only
            # `pollInlineRunQuotaGrants` emits.
            if not run.hasTrace("launched", "runquota-grant"):
              echo "[", lp.name,
                "] no queued-then-granted launch was observed; the ",
                "deferred spawn site was NOT exercised by this run"
            check run.hasTrace("launched", "runquota-grant")

            for i in 0 .. 1:
              let res = run.resultById("queued-" & $i)
              checkTookLaunchPath(lp, run, res, cacheRoot)
              checkMonitoredEvidence(res,
                expandFilename(workRoot / ("marker-" & $i & ".txt")),
                lp.name & " #" & $i)
              recordedEvidence.add (lp.name & " #" & $i,
                res.evidenceShape(caseSubstitutions(tempRoot, caseDir,
                  workRoot, workRoot / ("marker-" & $i & ".txt"),
                  workRoot / ("out-" & $i & ".txt"))))
          else:
            let marker = workRoot / "marker.txt"
            writeFile(marker, "hm4 marker payload\n")
            let act = monitoredFixtureAction("monitored-" & $ord(lp.kind),
              fixtureBin, marker, workRoot / "out.txt", workRoot,
              holdMs = 0, cpuMilli = 100'u32)
            let run = runBuild(graph([act]), config)
            check run.results.len == 1
            let res = run.results[0]
            checkTookLaunchPath(lp, run, res, cacheRoot)
            checkMonitoredEvidence(res, expandFilename(marker), lp.name)
            recordedEvidence.add (lp.name,
              res.evidenceShape(caseSubstitutions(tempRoot, caseDir,
                workRoot, marker, workRoot / "out.txt")))

    test "evidence is identical across launch paths":
      ## ``evidence_is_identical_across_launch_paths``.
      ##
      ## The cases above each assert that THEIR path is monitored. This
      ## one asserts they are monitored the SAME WAY: for one fixture
      ## doing one ``open``/``read``, all four launch paths — five
      ## actions, counting both halves of L3b — must produce
      ## indistinguishable dependency evidence once the per-case paths
      ## are normalised away.
      ##
      ## Two reasons it is worth its own case. First, "each path's
      ## evidence is non-empty" tolerates paths that disagree about
      ## WHICH paths they saw or which bucket they landed in; identity
      ## does not. Second, it is a baseline: a change to how the monitor
      ## is hosted has to reproduce this exact shape, and that is only a
      ## usable comparison if the shape was recorded before the change.
      if runQuotaError.len > 0:
        echo "[fixture N/A] cross-path evidence identity needs a real ",
          "runquota/runquotad for L2/L3/L3b: ", runQuotaError
        skip()
      else:
        # Five actions across the four paths, all recorded.
        check recordedEvidence.len == 5

        if recordedEvidence.len > 0:
          # NOT VACUOUS. Identical-but-empty would satisfy the
          # comparison below while proving nothing, so the shared shape
          # is pinned: exactly the marker was read, and there are no
          # diagnostics.
          let shape = recordedEvidence[0].shape
          if not shape.contains("\nmonitorReads=[<marker>]\n"):
            echo "[", recordedEvidence[0].label,
              "] the shared evidence shape does not read exactly the ",
              "marker:\n", shape
          check shape.contains("\nmonitorReads=[<marker>]\n")
          check shape.contains("\nmonitorWrites=[<out>]\n")
          check shape.contains("\ndiagnostics=[]")

          # PRIMARY ASSERTION.
          for i in 1 ..< recordedEvidence.len:
            if recordedEvidence[i].shape != recordedEvidence[0].shape:
              echo "launch paths produced DIFFERENT evidence for the same ",
                "fixture.\n--- ", recordedEvidence[0].label, " ---\n",
                recordedEvidence[0].shape, "\n--- ",
                recordedEvidence[i].label, " ---\n",
                recordedEvidence[i].shape
            check recordedEvidence[i].shape == recordedEvidence[0].shape

    test "teardown":
      daemon.stop()
      removeDir(tempRoot)
      # ``check true`` could not fail, so a teardown that silently left the
      # daemon running or the scratch tree on disk still reported [OK].
      # Assert the post-state the teardown exists to produce.
      check not dirExists(tempRoot)
