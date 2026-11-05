## A ``linux.tmpfilesRule`` fragment is judged by its lines (spec §4.1, the
## ``tmpfiles`` class; §4.4): every add-on apply refuses a line whose path
## -- or a symlink's target, a copy's source -- is outside the class's
## directories (``/var/lib``, ``/var/cache``, ``/var/log``, ``/run``, less
## the trees other owners hold), and a line it cannot parse.
##
## Falsifier: ``tmpfiles-scope-unchecked`` (no line is parsed) turns every
## refusal test red.
##
## *Mocking.* None: the scope check is a pure function of the profile.

import std/[strutils, unittest]

import repro_infra
import repro_infra/addon_diagnostics
import repro_addon/addon_apply
import repro_addon/tmpfiles_scope

proc fragment(content: string): SystemProfile =
  SystemProfile(resources: @[SystemResource(kind: srkLinuxTmpfilesRule,
    address: "linux.tmpfilesRule:repro-x.conf", tmpfilesName: "repro-x.conf",
    tmpfilesContent: content)])

proc scopeRefusal(content: string): string =
  try:
    checkScope(fragment(content))
    ""
  except EAddOnOutOfScope as e:
    e.msg

suite "a tmpfiles fragment's lines are held to the class":
  test "every line type outside the class's directories is refused":
    # One line per tmpfiles.d(5) type, each aimed at the management path or
    # a class directory: what systemd-tmpfiles would do with it as root.
    for line in ["f /etc/nologin 0644 root root -",
                 "f+ /etc/nologin 0644 root root - locked",
                 "w /etc/pam.d/sshd - - - - auth requisite pam_deny.so",
                 "w+ /etc/pam.d/common-auth - - - - x",
                 "d /etc/ssh/sshd_config.d 0755 root root -",
                 "D /etc/systemd/system/ssh.service.d 0755 root root -",
                 "e /etc/ssh - - - -", "v /etc/x 0755 root root -",
                 "q /etc/x", "Q /etc/x", "p /etc/x", "p+ /etc/x",
                 "L /etc/ssh/sshd_config.d/x.conf - - - - /var/lib/x",
                 "L+ /etc/ssh/sshd_config.d/x.conf - - - - /var/lib/x",
                 "C /etc/ssh/sshd_config - - - - /var/lib/x",
                 "C+ /etc/ssh/sshd_config - - - - /var/lib/x",
                 "x /etc/x", "X /etc/x", "r /etc/nologin", "R /etc/ssh",
                 "z /etc/shadow 0644 root root -", "Z /etc/ssh 0777 - - -",
                 "t /etc/x - - - - security.x=y", "T /etc/x",
                 "h /etc/x - - - - +i", "H /etc/x", "a /etc/x - - - - u:x:rwx",
                 "a+ /etc/x", "A /etc/x", "A+ /etc/x",
                 "w /proc/sys/kernel/sysrq - - - - 1",
                 "d /usr/local/bin 0755 root root -",
                 "f /var/run/nologin", "d /run 0755 root root -",
                 "d /var/lib 0755 root root -"]:
      checkpoint line
      check "outside the tmpfiles class" in scopeRefusal(line & "\n")

  test "the trees other owners hold under the class are refused":
    for line in ["d /run/systemd/system/ssh.service.d 0755 root root -",
                 "f /run/systemd/system/x.service",
                 "d /run/tmpfiles.d 0755 root root -",
                 "f /run/sysctl.d/x.conf", "d /run/credentials/x",
                 "d /run/user/1000 0700 u u -", "R /run/repro/secrets",
                 "r /var/lib/repro/state", "d /var/lib/private/x",
                 "R /var/lib/systemd/linger"]:
      checkpoint line
      check "which another owner holds" in scopeRefusal(line & "\n")

  test "a symlink's target and a copy's source are held to the class too":
    check "outside the tmpfiles class" in
      scopeRefusal("L /var/lib/app/sshd - - - - /etc/ssh/sshd_config\n")
    check "outside the tmpfiles class" in
      scopeRefusal("C /var/lib/app/shadow - - - - /etc/shadow\n")
    check "which another owner holds" in
      scopeRefusal("L+ /var/lib/app/units - - - - /run/systemd/system\n")
    # No argument: systemd's default under /usr/share/factory.
    check scopeRefusal("L /var/lib/app/x\n") == ""
    check scopeRefusal("L /var/lib/app/x - - - - /var/lib/app/y\n") == ""

  test "a line the add-on cannot parse is refused":
    for line in ["c /var/lib/app/null 0666 root root - 1:3",
                 "b /var/lib/app/blk 0660 root root - 8:0",
                 "y /var/lib/app/x", "f", "f \"/var/lib/app/a b\"",
                 "f /var/lib/app/\\x2fetc", "d %S/app 0755 root root -",
                 "r /var/lib/app/*", "R /var/lib/app/?", "z /var/lib/[a]x",
                 "d /var/lib//app", "d /var/lib/./app", "d /var/lib/../etc",
                 "d var/lib/app"]:
      checkpoint line
      check scopeRefusal(line & "\n").len > 0

  test "the class's own directories are accepted":
    check scopeRefusal(
      "# a comment\n\n" &
      "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -\n" &
      "D /run/app 0755 root root -\nf /var/log/app/x.log 0640 app app -\n" &
      "f+ /var/cache/app/stamp 0644 root root - x\nr /run/app/old\n" &
      "R /var/cache/app/tmp\nx /var/cache/app/keep\nz /var/lib/app 0700 app app -\n" &
      "d! /run/app-boot 0755 root root -\nf- /var/lib/app/opt\n" &
      "L+ /var/lib/app/current - - - - /var/lib/app/v2\n") == ""

  test "the parser keeps each rule's type and paths":
    var rules: seq[TmpfilesRule]
    check tmpfilesRules("L+! /var/lib/a - - - - /var/lib/b c\nd /run/x\n",
                        rules) == ""
    check rules.len == 2
    check rules[0].kind == "L+" and rules[0].path == "/var/lib/a" and
      rules[0].source == "/var/lib/b c"
    check rules[1].kind == "d" and rules[1].source == ""

  test "a setuid or setgid mode is refused before anything is written":
    # The add-on writes no setuid or setgid bit, and the apply unit runs
    # with RestrictSUIDSGID=yes (spec §10.1), where the chmod would fail
    # half-way through a switch.
    check "setgid" in scopeRefusal("d /var/lib/app 2770 app app -\n")
    check "setgid" in scopeRefusal("f /var/lib/app/x 4755 root root -\n")
    check "setgid" in scopeRefusal("d /var/lib/app ~2770 app app -\n")
    check scopeRefusal("d /var/lib/app 1777 root root -\n") == ""
    check "octal" in scopeRefusal("d /var/lib/app rwx app app -\n")
