## A link edge runs after every library it names with ``-l``: after the
## library's producing edge and, for a versioned SONAME, after the edge that
## writes the link-time name ``lib<base>.so`` that ``-l<base>`` resolves.
##
## Before this was fixed (reprobuild-pm issue
## 2026-11-16-stdlib-link-edges-do-not-order-after-the-libraries-they-link),
## ``gccLink`` and ``clangLink`` turned ``LinkOptions.deps`` into ``-l`` /
## ``-L`` arguments only and gave the edge no dependency on the library, and
## ``zigLink`` ordered after its objects but not after the libraries. A
## consumer's link could then start before ``lib<base>.so`` existed and fail
## with "cannot find -l<base>"; it worked only when something else happened to
## schedule the library first. ``gccLink`` and ``clangLink`` did not order
## after their objects either. The edge's ``deps`` is what the engine
## schedules by, so this test reads it. Ordering is all it checks: whether
## the ``-L`` the link passes names the directory the library is written to
## is a separate question.
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. Each case opens a
## real ``build:`` frame for a registered package whose ``library`` block
## declares the ``api:``, calls ``c_library`` and ``c_executable`` as a recipe
## does, and reads the edges they registered, under each link adapter (gcc,
## clang, a zig target).

import std/[os, unittest]

import repro_project_dsl
import repro_dsl_stdlib/types/library
import repro_dsl_stdlib/types/executable
import repro_dsl_stdlib/types/options
import repro_dsl_stdlib/operations/toolchain
import repro_dsl_stdlib/operations/link
import repro_dsl_stdlib/constructors/c_library
import repro_dsl_stdlib/constructors/c_executable

const
  Recipe = "linkOrderFixture"
  HostIsElf = not (defined(macosx) or defined(windows))
  ZigTriple = "armv7-unknown-linux-musleabihf"

package linkOrderFixture:
  nativeBuildDeps:
    "zig >=0.13 <0.15"
  library greet:
    api:
      soname "greet"
      sover "1"
      linkKind shared
      links "greet"
  library archived:
    api:
      soname "archived"
      linkKind static
      links "archived"

# Templates, not procs: a ``check`` that fails inside a top-level proc sees
# no ``testStatusIMPL``, so it sets only the process exit code, and the
# enclosing ``test`` still prints ``[OK]`` over the failure (seen while
# writing this file). Inlined, each case reports its own failure.
template withTarget(value: string; body: untyped) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", "targetTriple=" & value)
  else: delEnv("REPRO_VARIANTS")
  try: body
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved)
    else: delEnv("REPRO_VARIANTS")

template inBuild(body: untyped) =
  resetBuildActionRegistry()
  let state = beginBuildBlock(Recipe)
  try: body
  finally: endBuildBlock(state)

proc registered(id: string): BuildActionDef =
  ## The edge as the engine will see it, from the registry; a default edge
  ## (empty ``id``) when nothing by that id is registered.
  for a in registeredBuildActions():
    if a.id == id: return a

template checkConsumerOrdersAfter(lib: Library; expectLinkTimeName: bool) =
  let exe = c_executable(into = "hello", sources = @["hello.c"],
                         deps = @[lib])
  let consumer = registered(exe.install.id)
  check consumer.id.len > 0
  checkpoint("consumer " & consumer.id & " deps=" & $consumer.deps)
  check lib.install.id.len > 0
  check lib.install.id in consumer.deps
  if expectLinkTimeName:
    check lib.linkTimeName.id.len > 0
    check lib.linkTimeName.id in consumer.deps
  else:
    check lib.linkTimeName.id.len == 0

suite "a link orders after the libraries it links":

  test "linkPrerequisites: install, then linkTimeName, defaults skipped":
    let a = Library(install: BuildActionDef(id: "a"),
                    linkTimeName: BuildActionDef(id: "a-ln"))
    let b = Library(install: BuildActionDef(id: "b"))
    let none = Library()
    var ids: seq[string]
    for e in linkPrerequisites([a, b, none]): ids.add(e.id)
    check ids == @["a", "a-ln", "b"]

  for compiler in ["gcc", "clang"]:
    test compiler & ": the consumer's link depends on the library's edges":
      setCompilerOverride(compiler)
      defer: setCompilerOverride("")
      withTarget(""):
        inBuild:
          let lib = c_library(into = "greet", sources = @["greet.c"])
          check lib.install.call.packageName == compiler
          checkConsumerOrdersAfter(lib, expectLinkTimeName = HostIsElf)

    test compiler & ": a static library dependency orders the link too":
      setCompilerOverride(compiler)
      defer: setCompilerOverride("")
      withTarget(""):
        inBuild:
          let lib = c_library(into = "archived", sources = @["a.c"])
          check lib.linkTimeName.id.len == 0
          checkConsumerOrdersAfter(lib, expectLinkTimeName = false)

  test "zig target: the consumer's link depends on the library's edges":
    withTarget(ZigTriple):
      inBuild:
        let lib = c_library(into = "greet", sources = @["greet.c"])
        check lib.install.call.packageName == "zig"
        checkConsumerOrdersAfter(lib, expectLinkTimeName = true)
        let zigConsumer = registered(
          c_executable(into = "hello2", sources = @["hello.c"],
                       deps = @[lib]).install.id)
        check zigConsumer.call.packageName == "zig"

  test "a direct link() orders after its objects":
    setCompilerOverride("gcc")
    defer: setCompilerOverride("")
    withTarget(""):
      inBuild:
        let obj = buildAction(id = "obj-main", call = inlineExecCall(@["true"]),
                              outputs = ["main.o"])
        let exe = link(LinkOptions(objects: @[obj], kind: lokExecutable,
                                   target: "bin/main"))
        check "obj-main" in exe.deps
