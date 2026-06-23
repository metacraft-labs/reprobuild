## M9.R.20.2 — `activity "<name>":` macro at system scope.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §4.2.
## Lifts the home-side activity helper pattern (~/dotfiles/modules/
## activities.nim) to the system scope. System-scope activities add
## `systemPackages` / `systemServices` / `groups` slots while still
## composing into the user's home profile via `homeContributions`.

import std/unittest

import repro_profile

suite "M9.R.20.2: activity macro at system scope":

  test "Test#1: empty activity captures name + defaults":
    let a = buildActivitySpec("development"):
      discard
    check a.name == "development"
    check a.displayName == ""
    check a.systemPackages.len == 0
    check a.systemServices.len == 0
    check a.groups.len == 0
    check a.homeContributions.len == 0

  test "Test#2: displayName + description + icon captured as scalars":
    let a = buildActivitySpec("development"):
      displayName: "Development"
      description: "Programming languages, tools, dev containers"
      icon: "applications-development"
    check a.displayName == "Development"
    check a.description == "Programming languages, tools, dev containers"
    check a.icon == "applications-development"

  test "Test#3: systemPackages + systemServices + groups lists captured":
    let a = buildActivitySpec("development"):
      systemPackages: @["git", "vscode", "docker", "neovim"]
      systemServices: @["docker.service"]
      groups: @["docker"]
    check a.systemPackages == @["git", "vscode", "docker", "neovim"]
    check a.systemServices == @["docker.service"]
    check a.groups == @["docker"]

  test "Test#4: homeContributions captured + round-trips via JSON":
    let a = buildActivitySpec("development"):
      displayName: "Development"
      description: "Dev tools"
      icon: "dev"
      systemPackages: @["git", "docker"]
      systemServices: @["docker.service"]
      groups: @["docker"]
      homeContributions:
        activities: @["devTools()", "containerTools()"]
    check a.homeContributions == @["devTools()", "containerTools()"]
    let js = emitSystemActivityJson(a)
    let a2 = parseSystemActivityJson(js)
    check a2.name == "development"
    check a2.displayName == "Development"
    check a2.systemPackages.len == 2
    check a2.systemServices == @["docker.service"]
    check a2.groups == @["docker"]
    check a2.homeContributions == @["devTools()", "containerTools()"]
    # Determinism check.
    check emitSystemActivityJson(a) == emitSystemActivityJson(a2)
