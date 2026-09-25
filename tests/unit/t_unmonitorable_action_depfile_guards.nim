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

suite "DA-1f: the generated depfile says a machine can tell it is generated":
  ## `depfileInputs` is a TERM OF THE ENGINE'S ZERO-EVIDENCE GUARD, and this
  ## helper's own docstring is the reason that matters: "a depfile emitted by
  ## a real tool is an OBSERVATION — the tool reports what it actually
  ## opened. This one is not." The two arrive at the engine as the same bytes
  ## in the same format, so until the reader could tell them apart, a guard
  ## whose subject is observation could be satisfied by a set that is 100%
  ## declaration-derived. `reprobuild-specs/Dependency-Observation-
  ## Attribution.md` rule 8.
  ##
  ## WHAT THIS FILE GRADES THAT THE ENGINE'S OWN CASES CANNOT. The engine side
  ## (`libs/repro_build_engine/tests/t_zero_evidence_edge_is_not_cacheable`)
  ## writes the stamp by hand, so it grades the CONSEQUENCE against a needle
  ## it chose itself. This grades the AGREEMENT: the writer is the real
  ## `unmonitorableActionDepfileText` and the reader is the real
  ## `readRecognizedDependencyReport`, so a change to the generator's wording
  ## reddens here. A shared constant between the two would have made them
  ## agree by construction and measured nothing — and would still have been
  ## green if the generator stopped emitting a comment at all.

  test "a generated depfile is recognised as declaration-derived":
    let parsed = parseGenerated(unmonitorableActionDepfileText(
      "build/test-deps/t_example.d",
      @["build/bin/thing", "build/lib/helper.so"],
      "the action interposes libc itself and livelocks with our shim"))
    check parsed.declarationDerived
    # ATTRIBUTION, NOT SUPPRESSION: the flag is carried IN ADDITION to the
    # paths, which are unchanged. A reader that ignores it behaves exactly as
    # it did before the flag existed.
    check parsed.inputs == @["build/bin/thing", "build/lib/helper.so"]

  test "an ordinary tool-written depfile is NOT declaration-derived":
    ## THE OTHER BOUND. Without it, "every depfile is declaration-derived"
    ## passes the case above and refuses every real `gcc -MD` report — which
    ## is the failure in the opposite direction and is worse, because it is a
    ## permanent non-publish for every compile in the graph.
    check not parseGenerated("out.o: a.h b.h\n").declarationDerived
    # Comments in general are not the stamp. A depfile may carry any comment;
    # only THIS one means "assembled from a declaration".
    check not parseGenerated(
      "# generated by gcc\nout.o: a.h\n").declarationDerived

  test "the stamp survives a multi-line reason and an awkward path":
    ## The stamp is written once, before the reason lines, and the reason is
    ## attacker-shaped input in the sense that matters here: it is free text
    ## the recipe author supplies, it is split into several comment lines, and
    ## its trailing backslashes are stripped so it cannot splice into the
    ## rule. None of that may displace or corrupt the stamp.
    let parsed = parseGenerated(unmonitorableActionDepfileText(
      "build/test-deps/t_multi.d",
      @["build/bin/thing with space", "build/lib/a#b"],
      "first line\nsecond line ending in a backslash \\\nthird line"))
    check parsed.declarationDerived
    check parsed.inputs == @["build/bin/thing with space", "build/lib/a#b"]
