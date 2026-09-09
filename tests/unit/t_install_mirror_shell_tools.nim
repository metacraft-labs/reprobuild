import std/unittest
import repro_project_dsl/install_mirror_resolver

const Common = @["sh", "rm", "mkdir", "cp", "touch", "sed", "chmod"]
const LinuxExtra = @["find", "head", "od", "tr", "sort", "grep",
  "dirname", "basename", "wc", "patchelf"]
const Expected = when defined(linux): Common & LinuxExtra else: Common
const GlibcExpected = when defined(linux): Expected & @["readlink", "ln"]
                      else: Expected

static:
  doAssert typedInstallMirrorShellTools("plain") == Expected
  doAssert typedInstallMirrorShellTools("glibcSource") == GlibcExpected

suite "install mirror shell tools":
  test "the native platform gets exactly its generated shell utilities":
    check typedInstallMirrorShellTools("plain") == Expected
    check InstallMirrorPublishToolName notin typedInstallMirrorShellTools("plain")

  test "only the Linux glibc mirror adds its symlink normalization tools":
    check typedInstallMirrorShellTools("glibcSource") == GlibcExpected
