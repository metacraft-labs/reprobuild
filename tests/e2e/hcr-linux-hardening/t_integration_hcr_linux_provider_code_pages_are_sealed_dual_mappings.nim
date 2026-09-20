## HLX-M9 verification gate
## `integration_hcr_linux_provider_code_pages_are_sealed_dual_mappings`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.1, §5.2.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M9 — the deliverable
## "`memfd_create` dual mapping for provider-owned patch pages and islands
## under W^X policy, with `F_SEAL_WRITE` after finalization."
##
## ---------------------------------------------------------------------------
## WHAT CHANGED
##
## A provider-owned code page — a patch body, an island page — used to be
## `mmap(MAP_ANONYMOUS, PROT_READ|PROT_WRITE)`, written, then
## `mprotect(PROT_READ|PROT_EXEC)`. That is a W^X violation in exactly the shape
## a hardened kernel forbids, and it is also why island page REUSE needed a
## transient `RW|EXEC` (the islands already on the page are live and cannot lose
## `PROT_EXEC` while a new one is written beside them).
##
## It is now one `memfd`, mapped twice: an exec view that is
## `MAP_PRIVATE|PROT_READ|PROT_EXEC` and never writable, and a separate
## `MAP_SHARED|PROT_READ|PROT_WRITE` alias that code is written through. A page
## that will take no more writes has its alias dropped and `F_SEAL_WRITE`
## applied, after which no writable alias to that executable page can be created
## by anything.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE
##
## CASE 1 — THE MECHANISM, AND THE ARM THAT SEPARATES THE TWO. The allocator is
## driven directly through the production shim, once per mechanism, with and
## without `prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN)`. The assertion is not
## that it "returned success": the probe CALLS the page and the gate checks the
## value the page returns, so a page that was mapped and never became runnable
## cannot pass. Under MDWE the anonymous mechanism FAILS — its
## `mprotect(PROT_READ|PROT_EXEC)` is refused by the kernel — while the dual
## mapping succeeds. That is a real kernel policy, not an injected error, and it
## is the whole claim of the deliverable measured in one comparison.
##
## CASE 2 — A REAL PATCH'S BODY PAGE. The same binary applies a real patch over
## a real socket and reads, out of `/proc/self/maps`, the mapping the patched
## body actually executes from: its permissions must be `r-xp`, its backing must
## be `/memfd:repro-hcr-code`, and this process must hold ZERO bytes of writable
## mapping aliasing that memfd. The `--anonymous` arm of the same binary patches
## just as well and reports an UNNAMED mapping, which is what makes the backing
## assertion a comparison between two measured worlds rather than a description
## of one.
##
## THE SEAL IS THE KERNEL'S ANSWER, NOT THE PROVIDER'S. `F_ADD_SEALS`
## returning 0 is a claim this provider makes about itself. What is asserted
## instead is `dualSealVerified` — the kernel REFUSING a shared writable mapping
## of the memfd, asked while the fd was still open, which is the last moment it
## can be asked. A provider that called `F_ADD_SEALS` with a `MAP_SHARED` exec
## view gets `EBUSY`, leaves the page unsealed, and is caught here. That
## ordering is not hypothetical: it is the first thing a reasonable
## implementation does, and it was measured failing exactly that way while this
## was being written.
##
## ONE INSTRUMENT WAS WRONG AND IS RECORDED RATHER THAN QUIETLY REPLACED. The
## first version asked whether `mprotect(RW|EXEC)` on the exec view still
## succeeded, expecting the seal to refuse it. It does not, and should not: the
## exec view is `MAP_PRIVATE`, so making it writable yields a copy-on-write page
## and touches neither the memfd nor any other mapping of it. `F_SEAL_WRITE` is
## a guarantee about the FILE. Measured 1 on a correctly sealed page.
##
## WHAT WORLD THIS FAILS IN. Force the anonymous mechanism everywhere and case
## 2's backing and writable-alias assertions go red while the patch still
## applies. Make the exec view `MAP_SHARED` and the seal silently stops
## happening: `sealedPages` goes to 0 and the writable-alias assertion goes red
## while everything about the patch stays green — which is the failure that
## motivated asserting the kernel's answer rather than the return code.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_agent
  import repro_project_dsl
  import "../hcr-linux-direct/elf_rel_reader"
  import "../hcr-linux-prepare/prepare_fixture"

  const
    Gate = "integration_hcr_linux_provider_code_pages_are_sealed_dual_mappings"
    ProbeBodyResult = 4242
      ## What the probe's one-page body returns. Spelled here and in
      ## `repro_hcr_lx_probe_code_page_cycle` and nowhere else, so a stale
      ## mapping cannot be mistaken for this one.

    ProbeSource = """
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>

#ifndef PR_SET_MDWE
#define PR_SET_MDWE 65
#endif
#ifndef PR_MDWE_REFUSE_EXEC_GAIN
#define PR_MDWE_REFUSE_EXEC_GAIN 1
#endif

int repro_hcr_lx_probe_code_page_cycle(int force_anonymous,
                                       unsigned long long *out_exec_base);
int repro_hcr_lx_probe_memfd_dual_supported(void);
int repro_hcr_lx_probe_last_seal_verified(void);
unsigned long long repro_hcr_lx_probe_dual_page_count(void);
unsigned long long repro_hcr_lx_probe_sealed_page_count(void);
unsigned long long repro_hcr_lx_probe_fallback_page_count(void);

int main(int argc, char **argv) {
  int mdwe = (argc > 1 && strcmp(argv[1], "--mdwe") == 0);
  unsigned long long dual_base = 0, anon_base = 0;
  int supported, dual_rc, anon_rc, dual_seal_verified, anon_seal_verified;
  if (mdwe && prctl(PR_SET_MDWE, PR_MDWE_REFUSE_EXEC_GAIN, 0, 0, 0) != 0) {
    fprintf(stderr, "probe: prctl(PR_SET_MDWE) failed (needs Linux 6.3+)\n");
    return 3;
  }
  supported = repro_hcr_lx_probe_memfd_dual_supported();
  dual_rc = repro_hcr_lx_probe_code_page_cycle(0, &dual_base);
  dual_seal_verified = repro_hcr_lx_probe_last_seal_verified();
  anon_rc = repro_hcr_lx_probe_code_page_cycle(1, &anon_base);
  anon_seal_verified = repro_hcr_lx_probe_last_seal_verified();
  printf("{\"schemaId\":\"reprobuild.hcr.hlx-m9.code-page-probe.v1\",");
  printf("\"mdwe\":%s,\"dualSupported\":%s,", mdwe ? "true" : "false",
         supported ? "true" : "false");
  printf("\"dualResult\":%d,\"anonymousResult\":%d,", dual_rc, anon_rc);
  printf("\"dualBase\":\"0x%llx\",\"anonymousBase\":\"0x%llx\",",
         dual_base, anon_base);
  printf("\"dualSealVerified\":%d,\"anonymousSealVerified\":%d,",
         dual_seal_verified, anon_seal_verified);
  printf("\"dualPages\":%llu,\"sealedPages\":%llu,\"fallbackPages\":%llu}\n",
         repro_hcr_lx_probe_dual_page_count(),
         repro_hcr_lx_probe_sealed_page_count(),
         repro_hcr_lx_probe_fallback_page_count());
  fflush(stdout);
  return 0;
}
"""

  proc buildProbe(repoRoot, workDir: string): string =
    result = workDir / "hcr_lx_m9_code_page_probe"
    let source = workDir / "code_page_probe.c"
    writeFile(source, ProbeSource)
    discard runOrFail(shellCommand([
      "gcc", "-O2", "-g",
      "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
      "-o", result, source,
      repoRoot / "libs" / "repro_hcr_agent" / "c" /
        "repro_hcr_linux_x86_64_probe.c"]), repoRoot)
    doAssert fileExists(result)

  proc runProbe(binary: string; mdwe: bool): JsonNode =
    var args: seq[string] = @[]
    if mdwe: args.add "--mdwe"
    let res = execCmdEx(shellCommand(@[binary] & args))
    if res.exitCode != 0:
      raise newException(IOError,
        "code-page probe exited " & $res.exitCode & " (mdwe=" & $mdwe &
        "):\n" & res.output)
    targetJson(res.output)

  proc buildPatchTarget(repoRoot, workDir, sourcePath: string): string =
    result = workDir / "hcr_lx_m9_memfd_target"
    let caseDir = repoRoot / "tests" / "e2e" / "hcr-linux-hardening"
    let compileFlags = patchableCompileFlags(ReproHcr())
    let linkFlags = patchableLinkFlags(ReproHcr())
    doAssert "-fpatchable-function-entry=16,0" in compileFlags
    doAssert "-Wl,--build-id=sha1" in linkFlags
    discard runOrFail(shellCommand(
      @["gcc", "-O2", "-g"] & @compileFlags &
      @["-fcf-protection=full",
        "-I", repoRoot / "libs" / "repro_hcr_agent" / "c",
        "-o", result,
        caseDir / "hcr_lx_m9_memfd_target.c",
        sourcePath,
        repoRoot / "libs" / "repro_hcr_agent" / "c" / "repro_hcr_agent.c"] &
      @linkFlags & @["-lpthread"]), repoRoot)
    doAssert fileExists(result)

  proc patchArm(repoRoot, targetBin, socketPath: string; anonymous: bool;
                patchBytes: seq[byte]): JsonNode =
    removeFile(socketPath)
    var listener = listenHcrAgentUnixSocket(socketPath)
    defer: listener.close()
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env[ReproHcrAgentSocketEnv] = socketPath
    var args: seq[string] = @[]
    if anonymous: args.add "--anonymous"
    let process = startProcess(targetBin, workingDir = repoRoot, args = args,
      env = env, options = {poStdErrToStdOut})
    var connection = acceptHcrAgentConnection(listener)
    var client = initHcrCoordinatorClient(HcrLinuxX86_64DirectSupportProfile)
    discard client.deliverPatchRequest(connection, directPatchRequest(
      patchId = "hlx-m9-memfd-" & $getCurrentProcessId(),
      supportProfile = HcrLinuxX86_64DirectSupportProfile,
      changedFunctions = [VictimSymbol],
      targetSymbols = [VictimSymbol],
      directPatchBytes = patchBytes,
      debugObjectBytes = [],
      unwindMetadataBytes = [],
      sourceGenerationMap = [],
      changedFiles = ["src/patchable.c"],
      changedTypes = []))
    connection.close()
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    if code != 0:
      raise newException(IOError, "target exited " & $code & ":\n" & output)
    targetJson(output)

  suite Gate:
    test "the dual mapping allocates executable pages where the anonymous path cannot":
      let repoRoot = getCurrentDir()
      let workDir = repoRoot / "build" / "hcr-linux-memfd"
      createDir(workDir)
      let probe = buildProbe(repoRoot, workDir)

      let plain = runProbe(probe, mdwe = false)
      let hardened = runProbe(probe, mdwe = true)

      # ---- THE PREMISE. If this host cannot do the dual mapping at all, the
      # gate FAILS rather than passing over a fallback — a green result here
      # would report that the deliverable works on a host where it never ran.
      check plain["dualSupported"].getBool()
      check hardened["dualSupported"].getBool()

      # ---- WITHOUT hardening both mechanisms work, so the difference under
      # hardening is attributable to the policy and not to one path being
      # broken.
      check plain["dualResult"].getInt() == ProbeBodyResult
      check plain["anonymousResult"].getInt() == ProbeBodyResult

      # ---- WITH hardening only the dual mapping works. The anonymous path's
      # `mprotect(PROT_READ|PROT_EXEC)` is refused by the kernel, which the
      # allocator reports as -2 ("could not be made executable").
      check hardened["dualResult"].getInt() == ProbeBodyResult
      check hardened["anonymousResult"].getInt() != ProbeBodyResult
      check hardened["anonymousResult"].getInt() < 0

      # ---- THE SEAL IS THE KERNEL'S ANSWER. `F_ADD_SEALS` returning 0 is the
      # provider's claim about itself; `dualSealVerified` is the kernel
      # REFUSING a shared writable mapping of the memfd while it was still
      # open, which is what a wrongly-ordered implementation cannot obtain —
      # a `MAP_SHARED` exec view makes `F_ADD_SEALS` fail `EBUSY` and leaves
      # the writable mapping granted.
      check plain["dualSealVerified"].getInt() == 1
      check hardened["dualSealVerified"].getInt() == 1
      # The anonymous fallback has no memfd and no seal, and says so rather
      # than inheriting the previous cycle's answer.
      check plain["anonymousSealVerified"].getInt() == 0
      check hardened["anonymousSealVerified"].getInt() == 0

      # ---- and the provider's own counters CORROBORATE, from the other side.
      check plain["sealedPages"].getInt() >= 1
      check plain["dualPages"].getInt() >= 1
      check plain["fallbackPages"].getInt() >= 1

      writeEvidence(repoRoot, Gate & ".mechanism", %*{
        "schemaId": "reprobuild.hcr.hlx-m9.code-page-mechanism.v1",
        "plain": plain,
        "hardened": hardened})

    test "a real patch body executes from a sealed memfd with no writable alias":
      let repoRoot = getCurrentDir()
      let workDir = repoRoot / "build" / "hcr-linux-memfd"
      createDir(workDir)
      let repro = repoRoot / "build" / "bin" / "repro"
      if not fileExists(repro):
        raise newException(IOError,
          Gate & " requires the built `repro` binary at " & repro &
          ". Remedy: run `just build` in this checkout.")

      let oldPath = workDir / "patchable_old.c"
      let newPath = workDir / "patchable_new.c"
      writeFile(oldPath, OldSource)
      writeFile(newPath, NewSource)
      let target = buildPatchTarget(repoRoot, workDir, oldPath)

      let raw = compilePatchObject(workDir, newPath, "patchable.raw.o")
      let prepared = workDir / "patchable.prepared.o"
      removeFile(prepared)
      discard runOrFail(shellCommand([
        repro, "hcr", "prepare-object",
        "--input", raw, "--output", prepared,
        "--function", VictimSymbol, "--segment", "__HCR"]), repoRoot)
      let patchBytes = parseElfRelObject(prepared).functionBytes(VictimSymbol)
      check patchBytes.len > 0

      let dual = patchArm(repoRoot, target, workDir / "dual.sock",
        anonymous = false, patchBytes = patchBytes)
      let anon = patchArm(repoRoot, target, workDir / "anon.sock",
        anonymous = true, patchBytes = patchBytes)

      # ---- BOTH ARMS PATCHED, so the difference below is about the page's
      # provenance and not about one arm having failed.
      for arm in [dual, anon]:
        check arm["applied"].getBool()
        check arm["before"].getInt() == OriginalValue
        check arm["after"].getInt() == PatchedValue
        check arm["codeSwapped"].getBool()
        check arm["dispatchAddress"].getStr() != "0x0"
        # The mapping the body EXECUTES from is read-execute in both. A `w`
        # here would be a writable executable mapping left behind.
        check arm["dispatchPerms"].getStr() == "r-xp"

      # ---- the dual arm: named, sealed, no writable alias left in the process.
      check dual["dispatchBacking"].getStr().startsWith("/memfd:repro-hcr-code")
      check dual["writableAliasBytes"].getInt() == 0
      check dual["sealedPages"].getInt() >= 1
      check dual["dualPages"].getInt() >= 1

      # ---- the anonymous arm: the pre-HLX-M9 world, on the same binary.
      check dual["dispatchBacking"].getStr() != anon["dispatchBacking"].getStr()
      check not anon["dispatchBacking"].getStr().startsWith("/memfd:")
      check anon["fallbackPages"].getInt() >= 1
      check anon["sealedPages"].getInt() == 0

      writeEvidence(repoRoot, Gate & ".patch", %*{
        "schemaId": "reprobuild.hcr.hlx-m9.code-page-patch.v1",
        "dualArm": dual,
        "anonymousArm": anon})

else:
  suite "integration_hcr_linux_provider_code_pages_are_sealed_dual_mappings":
    test "the provider code-page gate is linux-x86_64-only":
      skip()
