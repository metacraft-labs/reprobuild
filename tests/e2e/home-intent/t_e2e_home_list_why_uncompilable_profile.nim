## `repro home list` / `why` on a profile that does not compile, and the
## `headless()` predicate that used to compile without an evaluator.
##
## * `e2e_list_why_refuse_a_profile_that_does_not_compile`: `list` and `why`
##   read the compiled profile (CLI/home/list.md, why.md; reprobuild-pm issue
##   2026-10-13-home-list-and-why-reject-profiles-that-compose-helpers, fixed
##   in 650d33bc0, whose gate covered only profiles that compile). For a
##   profile with a Nim syntax error and for one naming an undeclared helper,
##   each command exits 1, prints nothing on stdout (no partial listing, no
##   header), and its stderr names the command, the profile and what the
##   compiler refused. The profile file is left unchanged. Positive control:
##   the same sandbox with the error repaired lists the package, exit 0.
## * `e2e_headless_predicate_is_refused_at_compile_time`: `when headless():`
##   in an activity (reprobuild-pm issue
##   2026-10-13-headless-predicate-template-has-no-evaluator) is a compile
##   error naming `headless`, for `list`, `why`, `apply --plan` and
##   `export --target`. Before the fix it compiled, `export --target` failed
##   at plan time with "no user-predicate evaluator provided for 'headless'",
##   and `list` exited 1 with the same planner error. The standard
##   predicates beside it compile and plan.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, an
## isolated sandbox (`profile_compile_edge_harness`); nothing is applied.
## Platforms: every host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_profile_compile

import ../m83/profile_compile_edge_harness

const SyntaxError = """
import repro_profile

profile "gnmBroken":
  activity default:
    ripgrep
    when linux(:
      `gnm-broken`
"""

const UndeclaredHelper = """
import repro_profile

profile "gnmUndeclared":
  activity default:
    ripgrep
    gnmNoSuchHelper()
"""

const Repaired = """
import repro_profile

profile "gnmRepaired":
  activity default:
    ripgrep
"""

const Headless = """
import repro_profile

profile "gnmHeadless":
  activity default:
    ripgrep
    when headless():
      tmux
"""

const Standard = """
import repro_profile

profile "gnmStandard":
  activity default:
    ripgrep
    when linux() or macos() or windows() or bsd() or wsl():
      tmux
    when x86_64() or arm64() or arm32():
      fd
"""

proc show(label: string; r: ReproRun) =
  checkpoint label & " (exit " & $r.exitCode & ")\n--- stdout\n" & r.stdout &
    "\n--- stderr\n" & r.stderr

suite "home list / why: a profile that does not compile":

  test "e2e_list_why_refuse_a_profile_that_does_not_compile":
    for (label, text, needle) in [
        ("syntax", SyntaxError, "home.nim(6"),
        ("undeclared", UndeclaredHelper, "gnmNoSuchHelper")]:
      let sb = newProfileSandbox("gnm-rd-" & label, text)
      defer: sb.dispose()
      let env = sb.fixturePackageEnv(["ripgrep", "gnm-broken"])
      for args in [@["home", "list"], @["home", "why", "ripgrep"]]:
        let r = sb.runRepro(args, extraEnv = env)
        show(label & ": " & args.join(" "), r)
        check r.exitCode == 1
        # Nothing on stdout: no listing header, no partial listing.
        check r.stdout.strip() == ""
        let command = "repro " & args[0] & " " & args[1]
        check r.stderr.contains(command)
        check r.stderr.contains(sb.profilePath)
        # What the compiler refused, not a generic failure.
        check r.stderr.contains(needle)
        check not r.stderr.contains("unstructured profile")
      check readFile(extendedPath(sb.profilePath)) == text
      # Positive control: the same sandbox, repaired, lists the package.
      writeFile(extendedPath(sb.profilePath), Repaired)
      let ok = sb.runRepro(["home", "list"], extraEnv = env)
      show(label & ": list (repaired)", ok)
      check ok.exitCode == 0
      check ok.stdout.contains("  enabled  ripgrep  activity=default")

  test "e2e_headless_predicate_is_refused_at_compile_time":
    let sb = newProfileSandbox("gnm-rd-headless", Headless)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(["ripgrep", "tmux", "fd"])
    for args in [@["home", "list"], @["home", "why", "tmux"],
                 @["home", "apply", "--plan"],
                 @["home", "export", "--target", compilingPlatformSystem()]]:
      let r = sb.runRepro(args, extraEnv = env)
      show(args.join(" "), r)
      check r.exitCode != 0
      # A compile error naming the identifier, not the planner's failure.
      check r.stderr.contains("headless")
      check r.stderr.contains("undeclared identifier")
      check not r.stderr.contains("no user-predicate evaluator")
    # Control: the built-in predicates compile and plan.
    writeFile(extendedPath(sb.profilePath), Standard)
    let listed = sb.runRepro(["home", "list"], extraEnv = env)
    show("list (standard predicates)", listed)
    check listed.exitCode == 0
    check listed.stdout.contains("  enabled  tmux  activity=default")
    check listed.stdout.contains("  enabled  fd  activity=default")
    let exported = sb.runRepro(["home", "export", "--target", compilingPlatformSystem()],
      extraEnv = env)
    show("export --target (standard predicates)", exported)
    check exported.exitCode == 0
    check exported.stdout.contains("\"tmux\"")
