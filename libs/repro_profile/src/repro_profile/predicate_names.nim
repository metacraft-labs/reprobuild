## The built-in predicate identifiers of a home profile, in ONE place.
##
## Two modules read this list and must never disagree: the profile
## combinators (`repro_profile/predicates`, which generates one
## `template <name>*(): PredicateExpr` per entry) and the predicate grammar
## that evaluates what those templates produce
## (`repro_home_intent/predicate`, `StandardPlatformIdents` /
## `StandardArchIdents`). They used to be two lists, and the combinators
## offered a `headless()` the grammar did not know: a profile using it
## compiled and then failed at plan time with "no user-predicate evaluator
## provided for 'headless'" (reprobuild-pm issue
## 2026-10-13-headless-predicate-template-has-no-evaluator). With one list
## a combinator without an evaluator cannot be written.
##
## The set is the spec's (Home-Profile-Intent-Layer.md §`when` and `if`
## predicates): platform `windows`, `macos`, `linux`, `bsd`, `wsl`;
## architecture `x86_64`, `arm64`, `arm32`. `host` is a value compared with
## `==` / `!=` / `in`, not a boolean, and is not listed here. "Headless" is
## deliberately absent: it is an activity selection, not a predicate
## (Gradual-Nix-To-Reprobuild-Migration.md §Hosts).
##
## No imports: `repro_home_intent` depends on this module and nothing else
## of `repro_profile`.

const
  StandardPlatformIdents* = ["windows", "macos", "linux", "bsd", "wsl"]
  StandardArchIdents* = ["x86_64", "arm64", "arm32"]
