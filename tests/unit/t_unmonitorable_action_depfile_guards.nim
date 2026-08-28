## Guards on ``unmonitorableActionDepfile``, the escape hatch that generates a
## dependency depfile for an action the engine cannot monitor.
##
## The route it feeds — ``makeDepfilePolicy(..., suppressMonitorShimSeed =
## true)`` — is unmonitored, so the generated file is the edge's ONLY
## dependency evidence. That makes two things worth pinning:
##
##   * The helper cannot be called into a shape that supplies no evidence, and
##     cannot be called without a written justification. Those are the guards
##     that keep it from decaying into a general-purpose "skip dependency
##     tracking" switch — the shape banned four times over in
##     ``repro_core/dependency_gathering.nim``.
##   * What it emits is a real make-format depfile: the engine parses it with
##     ``repro_depfile`` and the paths it reports back are exactly the declared
##     inputs. A file that merely looked plausible would silently give the edge
##     no inputs at all, which is the same failure the guards above exist to
##     prevent, arriving by a different road.
##
## This file replaces ``t_trusted_declared_inputs_policy_guards.nim``, which
## covered the removed ``trustedDeclaredInputsPolicy``.

import std/[os, strutils, unittest]
import repro_project_dsl
import repro_depfile

proc parseGenerated(text: string): DependencyPathSet =
  ## Round-trip the generated text through the engine's own reader, from a
  ## real file, because that is how the engine consumes it.
  let dir = getTempDir() / "t_unmonitorable_action_depfile_guards"
  createDir(dir)
  let path = dir / "generated.d"
  writeFile(path, text)
  defer: removeFile(path)
  readRecognizedDependencyReport(MakeDepfileFormatName, path)

suite "unmonitorableActionDepfile guards":

  test "a well-formed call yields a parseable depfile naming every input":
    let text = unmonitorableActionDepfileText(
      "build/test-deps/t_example.d",
      @["build/test-bin/t_example", "build/test-bin/helper-tool"],
      "test performs LD_PRELOAD interposition itself")
    let parsed = parseGenerated(text)
    check parsed.inputs ==
      @["build/test-bin/t_example", "build/test-bin/helper-tool"]
    check parsed.outputs == @["build/test-deps/t_example.d"]

  test "the justification travels with the generated file":
    let text = unmonitorableActionDepfileText(
      "d.d", @["a"], "cannot be monitored: self-interposes")
    check "# reason: cannot be monitored: self-interposes" in text
    # ...and it does not disturb the rule the engine reads.
    check parseGenerated(text).inputs == @["a"]

  test "an empty input list is refused":
    # Would leave the unmonitored edge with no evidence whatsoever — the
    # declared-only shape this route exists to avoid.
    expect ValueError:
      discard unmonitorableActionDepfileText("d.d", @[], "some reason")

  test "a list of only empty paths is refused":
    expect ValueError:
      discard unmonitorableActionDepfileText("d.d", @["", ""], "some reason")

  test "a missing output path is refused":
    expect ValueError:
      discard unmonitorableActionDepfileText("", @["a"], "some reason")

  test "a missing reason is refused":
    expect ValueError:
      discard unmonitorableActionDepfileText("d.d", @["a"], "")

  test "a whitespace-only reason is refused":
    expect ValueError:
      discard unmonitorableActionDepfileText("d.d", @["a"], "   \t\n ")

  test "duplicate declared paths collapse":
    let parsed = parseGenerated(
      unmonitorableActionDepfileText("d.d", @["a", "a", "b"], "r"))
    check parsed.inputs == @["a", "b"]

  test "paths carrying make meta-characters survive the round trip":
    # Unescaped, a space or a ':' would split one path into two bogus ones and
    # the edge would depend on neither of the real files.
    let awkward = @["build/dir with space/lib.so", "build/a:b/lib.so",
                    "build/hash#name/lib.so", "build/dollar$sign/lib.so"]
    let parsed = parseGenerated(
      unmonitorableActionDepfileText("d.d", awkward, "r"))
    check parsed.inputs == awkward

  test "a path containing a newline is refused rather than silently mangled":
    expect ValueError:
      discard unmonitorableActionDepfileText("d.d", @["a\nb"], "r")

  test "a newline in the output path is refused too":
    # The output is the rule TARGET; a newline there splits the rule and the
    # engine reads back a depfile targeting something never written.
    expect ValueError:
      discard unmonitorableActionDepfileText("d\n.d", @["a"], "r")

  test "a reason ending in a backslash cannot swallow the rule":
    # The make grammar splices a backslash-terminated line into the next one.
    let parsed = parseGenerated(
      unmonitorableActionDepfileText("d.d", @["a"], "trailing backslash \\"))
    check parsed.inputs == @["a"]

suite "the removed declared-only route stays removed":

  test "makeDepfilePolicy is the only way to ask for an unmonitored edge":
    # ``suppressMonitorShimSeed`` rides on the depfile policy and defaults to
    # false, so no existing edge loses the monitor shim env seed. It cannot be
    # reached from the monitoring policies at all.
    check not automaticMonitorPolicy().suppressMonitorShimSeed
    check not defaultDependencyPolicy().suppressMonitorShimSeed
    check not makeDepfilePolicy("a.d").suppressMonitorShimSeed
    check makeDepfilePolicy("a.d", suppressMonitorShimSeed = true)
      .suppressMonitorShimSeed
    check makeDepfilePolicy("a.d").kind == bdpMakeDepfile
