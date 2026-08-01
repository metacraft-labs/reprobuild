## Typed-Extension-Interfaces M1b — the CAPSTONE UNBLOCK: a lifted
## ``resourceType``'s ATTRIBUTE TYPE crosses the interface boundary as a
## CONSUMER-IMPORTABLE type, so a consuming compilation that does NOT link the
## producer's provider/driver module can still register the M1a SSZ codec for
## that ``typeId`` and round-trip its attrs box.
##
## Spec: ``Typed-Extension-Interfaces-And-Provider-Libraries.md`` §2 + §1.3;
## ``Low-Level-Provider-Protocol.md`` §4. This is the situation the N2/N3a
## mocks masked (they linked the producer's ``registerExtension`` marshaller
## straight into the test binary). Here the marshaller reaches the consumer
## ONLY through the lifted interface stub — exactly how the ``repro`` CLI
## reconciling an out-of-tree provider (vm-harness) gets it.
##
## The test drives the REAL shipped extractor (``extractInterfaceFromModule``)
## for a producer declaring a ``resourceType`` with flat SSZ-clean attributes,
## then compiles TWO independent consumers against the LIFTED STUB (never the
## producer):
##
##   * a "producer-side" marshaller binary that DOES link the producer module,
##     marshals an attrs box for the typeId, and writes the envelope bytes;
##   * a "consumer" binary that imports ONLY the lifted stub (no producer, no
##     driver), unmarshals those bytes back through the registry the stub
##     installed, and re-marshals — proving the round-trip closes on the
##     regenerated attrs type.
##
## Falsifiability (the acceptance bar): a consumer that imports the stub but
## with the stub's lifted-extension emission SUPPRESSED (``registerExtension``
## line removed) FAILS at ``unmarshalAttrs`` with the missing-interface
## diagnostic — proving the codec's presence is load-bearing and comes from the
## lift, not from anything the test binary linked on its own.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_test_support

const producerRepro = """
when not defined(reproInterfaceMode):
  import net_driver_impl

import repro_project_dsl
import repro_resources
import std/options

type
  NetworkAttrs* = object
    subnet*: string
    mtu*: int
    dnsServers*: seq[string]
    dhcp*: bool

proc nIdentity(inst: ResourceInstance): string {.nimcall.} =
  "network:" & inst.address

proc nDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)

proc nObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  result.present = false

proc nApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: nIdentity(inst), present: true)

let networkDriver = ResourceProviderDriver(
  identity: nIdentity, digest: nDigest, observe: nObserve, apply: nApply)

resourceType "vm_harness.network":
  attrs: NetworkAttrs
  wrapper: network
  determinism: rdVolatile
  driver: networkDriver
  attr subnet: string
  attr mtu: int
  attr dnsServers: seq[string]
  attr dhcp: bool

package vmnet:
  executable placeholder:
    discard
"""

# A PRIVATE producer dependency the lift must NOT drag into the consumer — the
# interface-mode compile skips importing it (``when not defined(...)``) and the
# stub never mentions it. Present only to prove the consumer stays clean.
const producerPrivateDep = """
proc privateNetSalt*(): string = "private-net-driver"
"""

proc pathFlags(paths: openArray[string]): seq[string] =
  for path in paths:
    result.add("--path:" & path)

proc runNim(args: openArray[string]): tuple[code: int; output: string] =
  let res = runShell(shellCommand(@args), getCurrentDir())
  (code: res.code, output: res.output)

when isNixSupported:
  suite "Typed-Extension-Interfaces M1b: extension type lifted and consumed":

    test "t_extension_type_lifted_and_consumed":
      let repoRoot = getCurrentDir()
      let dslPath = repoRoot / "libs" / "repro_project_dsl" / "src"
      let resPath = repoRoot / "libs" / "repro_resources" / "src"
      let scratch = repoRoot / ".scratch-m1b-consume" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let providerDir = scratch / "producer"
      let thinDir = scratch / "thin"
      let binDir = scratch / "bin"
      let outDir = scratch / "out"
      for d in [providerDir, thinDir, binDir, outDir]:
        createDir(d)

      writeFile(providerDir / "net_driver_impl.nim", producerPrivateDep)
      let providerModule = providerDir / "repro.nim"
      writeFile(providerModule, producerRepro)

      let artifactPath = outDir / "vmnet.rbsz"
      let stubPath = thinDir / "vmnet_interface.nim"

      # ---- LIFT: run the real extractor. Emits the artifact + the stub. ----
      let artifact = extractInterfaceFromModule(providerModule, artifactPath,
        stubPath, repoRoot, outDir / "scratch")
      check fileExists(stubPath)
      check artifact.projectInterface.publicResources.len == 1
      check artifact.projectInterface.publicResources[0].typeId ==
        "vm_harness.network"

      # The stub must carry the CONSUMER-IMPORTABLE attrs type + its codec
      # registration, and must NOT drag in the producer's private driver.
      let stubSource = readFile(stubPath)
      check stubSource.contains("registerExtension[")
      check stubSource.contains("vm_harness.network")
      check stubSource.contains("subnet")
      check stubSource.contains("mtu")
      check stubSource.contains("dnsServers")
      check stubSource.contains("dhcp")
      check not stubSource.contains("net_driver_impl")
      check not stubSource.contains("privateNetSalt")
      check not stubSource.contains("networkDriver")

      let depFlags = consumerCompilePathFlags(repoRoot)

      # ---- PRODUCER-SIDE marshal: a binary that DOES link the producer,
      #      marshals an attrs box for the typeId, writes the envelope bytes.
      let envelopePath = scratch / "network.attrs.env"
      let marshallerSrc = scratch / "marshaller.nim"
      writeFile(marshallerSrc,
        "import std/os\n" &
        "import repro_project_dsl\n" &
        "import repro_resources\n" &
        "import \"" & (providerDir / "repro.nim").replace("\\", "/") & "\"\n\n" &
        "let box = TypedExtensionBox[NetworkAttrs](typeId: \"vm_harness.network\",\n" &
        "  val: NetworkAttrs(subnet: \"10.0.0.0/24\", mtu: 1500,\n" &
        "    dnsServers: @[\"1.1.1.1\", \"8.8.8.8\"], dhcp: true))\n" &
        "let bytes = marshalAttrs(box)\n" &
        "writeFile(paramStr(1), bytes)\n")
      let marshallerBin = binDir / "marshaller"
      let mOut = runNim(@["nim", "c", "--hints:off", "--verbosity:0"] & depFlags &
        pathFlags([providerDir, dslPath, resPath]) &
        @["--nimcache:" & (scratch / "nc-marshaller"),
          "--out:" & marshallerBin, marshallerSrc])
      check mOut.code == 0
      if mOut.code != 0: checkpoint(mOut.output)
      let mRun = runNim(@[marshallerBin, envelopePath])
      check mRun.code == 0
      if mRun.code != 0: checkpoint(mRun.output)
      check fileExists(envelopePath)

      # ---- CONSUMER: imports ONLY the lifted stub. Unmarshals the producer's
      #      envelope through the registry the STUB installed (no producer /
      #      driver linked), then re-marshals — the round-trip closes on the
      #      regenerated attrs type. This is the CLI's real situation.
      let consumerSrc = scratch / "consumer.nim"
      writeFile(consumerSrc,
        "import std/os\n" &
        "import repro_project_dsl\n" &
        "import repro_resources\n" &
        "import vmnet_interface\n\n" &  # the LIFTED stub — nothing producer-side
        "let raw = readFile(paramStr(1))\n" &
        "let box = unmarshalAttrs(\"vm_harness.network\", raw)\n" &
        "let round = marshalAttrs(box)\n" &
        "let typed = TypedExtensionBox[VmHarness_networkAttrs](box)\n" &
        "doAssert round == raw, \"attrs envelope did not round-trip\"\n" &
        "doAssert typed.val.subnet == \"10.0.0.0/24\"\n" &
        "doAssert typed.val.mtu == 1500\n" &
        "doAssert typed.val.dnsServers == @[\"1.1.1.1\", \"8.8.8.8\"]\n" &
        "doAssert typed.val.dhcp\n" &
        "echo \"consumer-roundtrip-ok\"\n")
      let consumerBin = binDir / "consumer"
      let cOut = runNim(@["nim", "c", "--hints:off", "--verbosity:0"] & depFlags &
        pathFlags([thinDir, dslPath, resPath]) &
        @["--nimcache:" & (scratch / "nc-consumer"),
          "--out:" & consumerBin, consumerSrc])
      check cOut.code == 0
      if cOut.code != 0: checkpoint(cOut.output)
      let cRun = runNim(@[consumerBin, envelopePath])
      check cRun.code == 0
      if cRun.code != 0: checkpoint(cRun.output)
      check cRun.output.contains("consumer-roundtrip-ok")

      # ---- FAILS-WITHOUT-THE-LIFT: with the stub's ``registerExtension``
      #      emission SUPPRESSED, the consumer has no codec for the typeId, so
      #      ``unmarshalAttrs`` raises the missing-interface diagnostic. This
      #      proves the codec came from the LIFT, not from anything the consumer
      #      linked itself.
      let suppressedStub = thinDir / "vmnet_interface_no_ext.nim"
      var suppressed: seq[string] = @[]
      for line in stubSource.splitLines:
        if line.strip().startsWith("registerExtension["):
          suppressed.add("  discard  # registerExtension suppressed")
        else:
          suppressed.add(line)
      writeFile(suppressedStub, suppressed.join("\n"))
      let consumerNoExtSrc = scratch / "consumer_no_ext.nim"
      writeFile(consumerNoExtSrc,
        "import std/os\n" &
        "import repro_project_dsl\n" &
        "import repro_resources\n" &
        "import vmnet_interface_no_ext\n\n" &
        "let raw = readFile(paramStr(1))\n" &
        "discard unmarshalAttrs(\"vm_harness.network\", raw)\n")
      let consumerNoExtBin = binDir / "consumer_no_ext"
      let cnOut = runNim(@["nim", "c", "--hints:off", "--verbosity:0"] & depFlags &
        pathFlags([thinDir, dslPath, resPath]) &
        @["--nimcache:" & (scratch / "nc-consumer-noext"),
          "--out:" & consumerNoExtBin, consumerNoExtSrc])
      check cnOut.code == 0
      if cnOut.code != 0: checkpoint(cnOut.output)
      let cnRun = runNim(@[consumerNoExtBin, envelopePath])
      check cnRun.code != 0     # unmarshalAttrs must raise
      check cnRun.output.contains("missing the interface dependency")
