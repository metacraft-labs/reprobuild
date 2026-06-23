## M9.R.20.1 — `system "<hostname>":` macro skeleton.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §2.2.
## The macro lifts the proven home-side `repro_profile` macro pipeline
## to system scope, producing a typed `SystemIntent` value that holds
## the user's editable configuration (hostname + imports + config + users
## + services + packages + bootloader + validate).
##
## v0.1 scope: parse, compile, round-trip via emit/parse JSON helpers.
## Test#1 — Test#6 cover the six recognised sub-sections per the spec.

import std/unittest

import repro_profile

suite "M9.R.20.1: system macro skeleton":

  test "Test#1: empty system block compiles + hostname captured":
    let s = buildSystemIntent("emptyHost"):
      discard
    check s.hostname == "emptyHost"
    check s.imports.len == 0
    check s.configs.len == 0
    check s.users.len == 0
    check s.services.enableList.len == 0
    check s.extraPackages.len == 0

  test "Test#2: imports: block captures relative paths in order":
    let s = buildSystemIntent("withImports"):
      imports:
        "./hardware.nim"
        "modules/activities/development.nim"
        "modules/de/plasma.nim"
    check s.imports.len == 3
    check s.imports[0] == "./hardware.nim"
    check s.imports[1] == "modules/activities/development.nim"
    check s.imports[2] == "modules/de/plasma.nim"

  test "Test#3: config: block captures key/type/default per entry":
    let s = buildSystemIntent("withConfig"):
      config:
        timezone: string = "Europe/Sofia"
        locale: string = "en_US.UTF-8"
        hostname: string = "myDesktop"
        defaultUser: string = "zahary"
    check s.configs.len == 4
    check s.configs[0].key == "timezone"
    check s.configs[0].typeRepr == "string"
    check s.configs[0].defaultExpr == "\"Europe/Sofia\""
    check s.configs[0].isVariant == false
    check s.configs[3].key == "defaultUser"
    check s.configs[3].defaultExpr == "\"zahary\""

  test "Test#4: users: block captures groups + homeIntent import":
    let s = buildSystemIntent("withUsers"):
      users:
        "zahary":
          groups: @["wheel", "audio", "video"]
          homeIntent: import "./home.nim"
    check s.users.len == 1
    check s.users[0].name == "zahary"
    check s.users[0].groups == @["wheel", "audio", "video"]
    check s.users[0].homeIntentImport == "./home.nim"

  test "Test#5: services: enable + disable lists captured":
    let s = buildSystemIntent("withServices"):
      services:
        enable: @["NetworkManager", "sshd", "sddm"]
        disable: @["systemd-resolved"]
    check s.services.enableList == @["NetworkManager", "sshd", "sddm"]
    check s.services.disableList == @["systemd-resolved"]

  test "Test#6: full system block round-trips via JSON":
    let s = buildSystemIntent("myDesktop"):
      imports:
        "./hardware.nim"
        "modules/de/plasma.nim"
      config:
        timezone: string = "Europe/Sofia"
        hostname: string = "myDesktop"
      users:
        "zahary":
          groups: @["wheel", "audio"]
          homeIntent: import "./home.nim"
      services:
        enable: @["NetworkManager", "sddm"]
        disable: @[]
      packages:
        extra: @["firefox", "vim"]
      bootloader:
        `type`: grub
        device: "/dev/sda"
    let js = emitSystemIntentJson(s)
    let s2 = parseSystemIntentJson(js)
    check s2.hostname == "myDesktop"
    check s2.imports.len == 2
    check s2.configs.len == 2
    check s2.users.len == 1
    check s2.users[0].name == "zahary"
    check s2.users[0].homeIntentImport == "./home.nim"
    check s2.services.enableList.len == 2
    check s2.extraPackages == @["firefox", "vim"]
    check s2.bootloader.kind == "grub"
    check s2.bootloader.device == "/dev/sda"
    # Determinism: identical inputs produce identical JSON.
    let js2 = emitSystemIntentJson(s)
    check js == js2
