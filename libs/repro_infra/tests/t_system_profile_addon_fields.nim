## The add-on's surface in the system-profile text format: the
## per-resource `collision` opt-in, the profile-wide `addOn` stanza with
## its managed `/etc` prefixes, the drop-in name, the renderer's round
## trip, and the comment stripping that keeps a `#` inside a multi-line
## quoted value.
##
## No mocks: pure parser and renderer over text.

import std/[strutils, unittest]

import repro_infra

suite "collision opt-ins":
  test "a file may divert; a unit may drop in or replace; nothing else":
    let p = parseSystemProfile("""fs.systemFile { path = "/etc/x/a" content = "a" collision = "divert" }
systemd.systemUnit { name = "a.service" content = "[Unit]" collision = "dropIn" dropInName = "hardening" }
systemd.systemUnit { name = "b.service" content = "[Unit]" collision = "replace" }
""")
    check p.resources[0].sfCollision == "divert"
    check p.resources[1].suCollision == "dropIn"
    check p.resources[1].suDropInName == "hardening"
    check p.resources[2].suCollision == "replace"
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""fs.systemFile { path = "/etc/x/a" collision = "replace" }""")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""systemd.systemUnit { name = "a.service" content = "x" collision = "divert" }""")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""systemd.systemUnit { name = "a.service" content = "x" collision = "Divert" }""")

  test "dropInName needs the dropIn opt-in and a safe segment":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""systemd.systemUnit { name = "a.service" content = "x" dropInName = "h" }""")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""systemd.systemUnit { name = "a.service" content = "x" collision = "dropIn" dropInName = "../h" }""")
    check isSafeDropInName("a-b_c.1") and not isSafeDropInName("a/b") and
      not isSafeDropInName("..")

suite "the addOn stanza":
  test "managed prefixes are declared once, validated and de-duplicated":
    let p = parseSystemProfile("""addOn {
  managedEtcPrefixes = [
    "/etc/vaultwarden/",
    "/etc/issue.net",
    "/etc/vaultwarden/"
  ]
}
fs.systemFile { path = "/etc/vaultwarden/x" content = "a" }
""")
    check p.addOn.declared
    check p.addOn.managedEtcPrefixes == @["/etc/vaultwarden/", "/etc/issue.net"]
    check p.resources.len == 1
    check not parseSystemProfile("").addOn.declared

  test "a prefix outside /etc, the whole of /etc, '..' or a class directory is refused":
    for bad in ["/usr/lib/x/", "/etc/", "/etc/a/../b/", "/etc/systemd/system/",
                "/etc/systemd/", "/etc/sysctl.d/x/", "/etc/tmpfiles.d",
                "/etc/sysusers.d/"]:
      check managedPrefixError(bad).len > 0
    check managedPrefixError("/etc/vaultwarden/") == ""
    check managedPrefixError("/usr/local/etc/app/") == ""
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""addOn { managedEtcPrefixes = ["/etc/systemd/system/"] }""")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""addOn { managedEtcPrefixes = [] }
addOn { managedEtcPrefixes = [] }""")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("""addOn { other = 1 }""")

  test "a trailing slash means the subtree; without it, that path or below":
    check isUnderManagedPrefix("/etc/a/b", "/etc/a/")
    check not isUnderManagedPrefix("/etc/ab", "/etc/a/")
    check isUnderManagedPrefix("/etc/issue.net", "/etc/issue.net")
    check isUnderManagedPrefix("/etc/issue.net/x", "/etc/issue.net")
    check not isUnderManagedPrefix("/etc/issue.network", "/etc/issue.net")

suite "rendering":
  test "the renderer round-trips the new fields and the stanza":
    let text = """addOn {
  managedEtcPrefixes = [
    "/etc/app/"
  ]
}

fs.systemFile {
  path = "/etc/app/a.conf"
  content = "line one
# not a comment: inside the value
line three
"
  collision = "divert"
}

systemd.systemUnit {
  name = "cron.service"
  content = "[Service]
Nice=5
"
  collision = "dropIn"
  dropInName = "nice"
}
"""
    let p = parseSystemProfile(text)
    check p.resources[0].sfContent == "line one\n# not a comment: inside the value\nline three\n"
    check renderProfileText(p) == text
    check renderProfileText(parseSystemProfile(renderProfileText(p))) == text

  test "comments outside values are still stripped":
    let p = parseSystemProfile("# leading\nfs.systemFile { # trailing\n  path = \"/etc/a\" # here\n  content = \"x\"\n}\n")
    check p.resources.len == 1 and p.resources[0].sfPath == "/etc/a"
    check stripComments("a # b\n\"c # d\"\n") == "a    \n\"c # d\"\n"
