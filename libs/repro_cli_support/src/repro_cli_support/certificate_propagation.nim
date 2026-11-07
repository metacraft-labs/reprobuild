## Carrying certificates with a push: the managed ``pre-push`` hook's call into
## the linked reference ``test_certificates`` library.
##
## Certificates reach a receiving gate as git notes keyed by tree
## (test-certificates Transport §3). Reprobuild does not re-implement carrying
## them. ``prePushHook`` is the library form of the hook body of Tooling §4
## (https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md):
## it works out the commits a push introduces (§4.2), publishes the store's
## certificates for their trees and declared scopes' trees (§3.1), and pushes the
## notes ref to the same remote within a finite time budget (§4.3). It is linked,
## so every build of ``repro`` can propagate, at the revision ``repro.lock`` pins.
##
## What this module adds is what the reference executable's command line adds
## around that call, which its library does not export: the two documented
## environment variables and the report. Their names and meanings are the
## reference tool's, so a user sets one spelling whichever hook runs.
##
## Nothing here decides the push: what could not be propagated is reported, and
## the receiving gate decides what the missing notes mean (§4.3).

import std/[os, sequtils, strutils]

from test_certificates/cli as tccli import nil
from test_certificates/git as tcgit import nil
from test_certificates/hook as tchook import nil
from test_certificates/notes as tcnotes import nil
from test_certificates/roots as tcroots import nil
from test_certificates/scopes as tcscopes import nil

const
  CertificateHookSwitchVariable* = "TEST_CERTIFICATES_HOOK"
    ## ``off`` (or ``0``, ``false``, ``no``) skips propagation for one push.
  CertificateHookTimeoutVariable* = "TEST_CERTIFICATES_HOOK_TIMEOUT"
    ## Whole seconds, at least 1, the hook's network operations may take in all.
  certificatePropagationReportPrefix* = "repro hooks: certificates: "
    ## Starts every line this module reports; `repro push` passes those on.
  ReportPrefix = certificatePropagationReportPrefix

type
  CertificatePropagation* = enum
    ## How the call ended. None of these fails the push.
    cpPropagated     ## All there was to carry travelled; possibly nothing.
    cpOptedOut       ## ``TEST_CERTIFICATES_HOOK`` asked for no propagation.
    cpNotPropagated  ## Something could not be carried, and was reported.

proc switchedOff(): bool =
  getEnv(CertificateHookSwitchVariable).strip().toLowerAscii() in
    ["off", "0", "false", "no"]

proc hookOptions(report: proc (line: string)): tchook.HookOptions =
  ## The defaults (hooks off, the library's finite budget), with the user's
  ## budget when it is a valid one. Any other value is reported and ignored:
  ## there is no unlimited setting (Tooling §4.3).
  result = tchook.defaultHookOptions()
  let text = getEnv(CertificateHookTimeoutVariable).strip()
  if text.len == 0: return
  try:
    let seconds = parseInt(text)
    if seconds < 1 or seconds > high(int32) div 1000:
      raise newException(ValueError, "out of range")
    result.push.timeoutMs = seconds * 1000
  except ValueError:
    report(ReportPrefix & "ignored " & CertificateHookTimeoutVariable & "=" &
      text & " (not a whole number of seconds, at least 1); using " &
      $(tchook.DefaultHookTimeoutMs div 1000))

proc propagateCertificates*(repoRoot, remoteName, remoteLocation,
                            pushedRefs: string;
                            report: proc (line: string)):
    CertificatePropagation =
  ## Run the hook body for one push: ``remoteName`` and ``remoteLocation`` are
  ## git's two hook arguments and ``pushedRefs`` its standard input. Never
  ## raises, a defect in the library included: a push must not fail on this.
  try:
    if switchedOff():
      report(ReportPrefix & CertificateHookSwitchVariable & "=" &
        getEnv(CertificateHookSwitchVariable) &
        ": not propagated with this push")
      return cpOptedOut
    let hook = tchook.prePushHook(repoRoot, remoteName, remoteLocation,
      pushedRefs, tcroots.nativeRoots(), hookOptions(report))
    for fault in hook.faults:
      report(ReportPrefix & "ignored pre-push input " & fault)
    for remark in hook.remarks:
      report(ReportPrefix & remark)
    if hook.publishRan or hook.pushRan:
      var appended, replaced = 0
      for tree in hook.published.trees:
        appended += tree.appended.len
        replaced += tree.replaced.len
      var line = $hook.certified.len & " certified tree(s) among " &
        $hook.introducedCount & " pushed commit(s): " & $appended &
        " certificate(s) added to " & hook.notesRef
      if replaced > 0:
        line.add(", " & $replaced & " replaced by a signed copy")
      if hook.pushRan and hook.pushed.ok:
        line.add("; " & $hook.pushed.outcome & " to " & hook.target)
      report(ReportPrefix & line)
    elif hook.introducedCount > 0 and hook.problems.len == 0:
      report(ReportPrefix & "no stored certificates for the " &
        $hook.introducedCount &
        " commit(s) this push introduces; nothing to propagate")
    if hook.problems.len == 0:
      return cpPropagated
    for problem in hook.problems:
      report(ReportPrefix & "warning: " & problem)
    report(ReportPrefix & "warning: NOT fully propagated; the push continues")
  except Exception as err: # Defect included, deliberately (see above)
    try:
      report(ReportPrefix & "warning: internal error: " & err.msg &
        "; not propagated, and the push continues")
    except Exception:
      discard
  cpNotPropagated

proc commitsPushIntroduces*(repoRoot, remoteName, commit, destinationRef: string;
                           remoteObjects: openArray[string]):
    tuple[ok: bool; commits: seq[string]; problem: string] =
  ## The commits ``git push <remoteName> <commit>:<destinationRef>`` introduces
  ## (Tooling §4.2), asked of the library before the push, so what is decided here
  ## and what its hook carries cannot disagree. ``remoteObjects`` has what each
  ## push URL advertises for the destination, "" where it has nothing: each URL
  ## gets a hook run of its own, so the answer is the union over them. Never raises.
  try:
    let options = hookOptions(proc (line: string) = discard)
    let absent = repeat('0', commit.len)
    let destinations =
      if remoteObjects.len > 0: toSeq(remoteObjects) else: @[""]
    var asked: seq[string]
    for advertised in destinations:
      if advertised in asked:
        continue
      asked.add(advertised)
      let answer = tchook.introducedCommits(repoRoot, remoteName,
        commit & " " & commit & " " & destinationRef & " " &
          (if advertised.len > 0: advertised else: absent) & "\n", options)
      if not answer.ok:
        return (false, @[], answer.problems.join("; "))
      for introduced in answer.commits:
        if introduced notin result.commits:
          result.commits.add(introduced)
    result.ok = true
  except Exception as err: # Defect included, as in the other entry points here.
    return (false, @[], "the commits this push introduces could not be told: " &
      err.msg)

proc carryCertificatesOfCommit*(repoRoot, remoteName, commit: string;
                                report: proc (line: string)):
    CertificatePropagation =
  ## Get the store's certificates for ``commit`` to ``remoteName`` when no hook
  ## will: ``prePushHook`` carries what a push introduces (Tooling §4.2), which
  ## is nothing for a commit the remote already has and for a new branch at a
  ## commit a remote-tracking ref reaches. The same two library calls, under the
  ## same switch and the same budget.
  ##
  ## With no certificate for the commit it stays off the network, so a closure
  ## of many published members costs nothing. With one it always pushes, whether
  ## or not this call added to the note: a note published earlier may be one
  ## whose push failed, and a push the remote has already seen is one round trip.
  ## Never raises: what could not be carried is reported with the remedy, and the
  ## receiving gate decides what that means (§4.3).
  try:
    if switchedOff():
      report(ReportPrefix & CertificateHookSwitchVariable & "=" &
        getEnv(CertificateHookSwitchVariable) & ": " & commit &
        " not carried")
      return cpOptedOut
    let options = hookOptions(report)
    let budget = tcgit.deadlineIn(options.push.timeoutMs)
    let published = tcnotes.publishNotes(repoRoot, tcroots.nativeRoots(),
      [commit], deadline = budget, gitExe = options.push.gitExe)
    var problems = published.problems
    var appended, certificates = 0
    for tree in published.trees:
      appended += tree.appended.len + tree.replaced.len
      certificates += tree.appended.len + tree.replaced.len + tree.present.len
      for line in tree.notPublished:
        problems.add("not published: " & line)
    if certificates > 0:
      var pushOptions = options.push
      pushOptions.timeoutMs = max(tcgit.remainingMs(budget), 1)
      let pushed = tcnotes.pushNotes(repoRoot, remoteName,
        options = pushOptions)
      problems.add(pushed.problems)
      if pushed.ok and (appended > 0 or pushed.outcome != tcnotes.soUpToDate):
        report(ReportPrefix & $certificates & " certificate(s) for " & commit &
          ": " & $pushed.outcome & " to " & remoteName)
    if problems.len == 0:
      return cpPropagated
    for problem in problems:
      report(ReportPrefix & "warning: " & problem)
    report(ReportPrefix & "warning: NOT fully propagated. To carry them: " &
      "test-certificates notes publish " & commit &
      " && test-certificates notes push " & remoteName)
  except Exception as err: # Defect included, deliberately (see above)
    try:
      report(ReportPrefix & "warning: internal error: " & err.msg &
        "; not propagated, and the push continues")
    except Exception:
      discard
  cpNotPropagated

proc linkedCertificateLibraryVersion*(): string =
  ## The version of the ``test_certificates`` library this build links, as the
  ## library's own executable reports it. ``repro health`` shows it: the library
  ## cannot be missing, so what can differ between two builds is which one.
  tccli.Version

proc certificatePropagationEnvironmentFindings*(): seq[string] =
  ## What in this process's environment would stop every push made from it. An
  ## opt-out meant for one push that stayed exported in a shell is otherwise
  ## visible only in the output of each push it silently emptied.
  if switchedOff():
    result.add(CertificateHookSwitchVariable & "=" &
      getEnv(CertificateHookSwitchVariable) &
      " is set here, so pushes from this environment propagate nothing")
  let roots = tcroots.nativeRoots()
  if roots.user.len == 0 and roots.system.len == 0:
    result.add("neither certificate store root could be resolved: " &
      roots.problems.join("; "))

proc certificatePropagationFindings*(repoRoot: string): seq[string] =
  ## What in ``repoRoot``'s git configuration stands between its certificates
  ## and a gateway, which a push reports only in its own output:
  ##
  ## * an invalid scope declaration stops propagation altogether (Tooling §3.1);
  ## * a ``testCertificates.notesRef`` other than the default sends notes to a
  ##   ref the gateway does not read. Reprobuild's gates read the default only.
  let declared = tcscopes.declaredScopes(repoRoot)
  for problem in declared.problems:
    result.add("invalid scope declaration: " & problem)
  let repo = tcnotes.openNotesRepo(repoRoot)
  if not repo.ok:
    result.add("notes configuration: " & repo.problem)
  elif repo.notesRef != tcnotes.DefaultNotesRef:
    result.add(tcnotes.NotesRefConfigKey & " is " & repo.notesRef &
      ", and gateways read " & tcnotes.DefaultNotesRef)
