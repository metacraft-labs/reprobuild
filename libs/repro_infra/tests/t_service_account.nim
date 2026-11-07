## The account a systemd service runs as (``repro_infra/service_account``),
## resolved as systemd resolves it: specifiers, instance names, a static
## account winning over ``DynamicUser=yes`` (for the user and the group),
## uid aliases, ``/etc/group`` memberships, and the accounts a profile
## creates. Falsified by the build ``-d:reproAddonMutation=account-as-written``
## (the account taken as written), which must turn this test red.
##
## No mocks: real ``passwd``/``group`` files in a scratch root and the real
## profile parser. The systemd behaviour each case encodes is cited in the
## module's header (systemd.exec(5), systemd.unit(5) "Specifiers"); the
## add-on VM gate measures the two that decide reach (``DynamicUser=yes``
## with ``User=root``, ``User=%i`` on an instance) on a real systemd.

import std/[os, unittest]

import repro_infra
from repro_test_support import testCaseScratchSlug

let root = getTempDir() / ("t_service_account" & testCaseScratchSlug())
removeDir(root)
createDir(root / "etc")
writeFile(root / "etc/passwd",
  "root:x:0:0:root:/root:/bin/sh\n" &
  "toor:x:0:0:alias:/root:/bin/sh\n" &
  "app:x:1001:1001::/home/app:/bin/sh\n" &
  "web:x:1002:1002::/home/web:/bin/sh\n" &
  "svc:x:1003:1003::/:/usr/sbin/nologin\n" &
  "f2b:x:1004:1004::/:/usr/sbin/nologin\n" &
  "wheely:x:1005:0::/:/bin/sh\n")
writeFile(root / "etc/group",
  "root:x:0:\nadm:x:4:app\nshadow:x:42:\napp:x:1001:\nweb:x:1002:\n" &
  "svc:x:1003:\nf2b:x:1004:\nsneaky:x:0:\nwheel-ish:x:0:web\n")

writeFile(root / "etc/nsswitch.conf", "passwd: files systemd\ngroup: files systemd\n")

let host = hostAccountLookup(root)

proc res(user, group: string; dyn = false; unit = "x.service";
         supp = ""; lookup = host): ResolvedAccount =
  resolveServiceAccount(user, group, supp, dyn, unit, lookup)

suite "the account systemd will use":
  test "an empty User= is root, with root's group":
    let a = res("", "")
    check a.known and a.userIsRoot and a.groupIsRoot and not a.dynamicUser

  test "DynamicUser=yes with User=root runs as root, not as a dynamic user":
    let a = res("root", "", dyn = true)
    check a.known and a.userIsRoot and not a.dynamicUser

  test "DynamicUser=yes with a static User= uses the static account":
    let a = res("app", "", dyn = true)
    check a.known and not a.dynamicUser and a.uid == 1001
    check a.primaryGid == 1001 and 4 in a.memberGids     # app is in adm

  test "DynamicUser=yes with Group=root holds gid 0":
    let a = res("dynx", "root", dyn = true)
    check a.known and a.dynamicUser and not a.dynamicGroup
    check a.groupIsRoot and not a.userIsRoot

  test "DynamicUser=yes with a Group= naming an alias of gid 0 holds gid 0":
    let a = res("dynx", "sneaky", dyn = true)
    check a.known and a.groupIsRoot

  test "DynamicUser=yes with no static account of the name is dynamic":
    let a = res("dynx", "", dyn = true)
    check a.known and a.dynamicUser and a.dynamicGroup
    check a.uid == DynamicId and not a.userIsRoot and not a.groupIsRoot

  test "DynamicUser=yes without User= takes the unit's name, static if it exists":
    let a = res("", "", dyn = true, unit = "svc.service")
    check a.known and not a.dynamicUser and a.uid == 1003
    let b = res("", "", dyn = true, unit = "nosuch.service")
    check b.known and b.dynamicUser

  test "%U, %u, %G and %g are root for the system manager":
    for u in ["%U", "%u"]:
      let a = res(u, "app")
      check a.known and a.userIsRoot
    for g in ["%G", "%g"]:
      let a = res("app", g)
      check a.known and a.groupIsRoot and not a.userIsRoot
    let d = res("%u", "", dyn = true)      # the static-account rule too
    check d.known and d.userIsRoot and not d.dynamicUser

  test "%i is the instance; a template's own file names none":
    check res("%i", "", unit = "f@root.service").userIsRoot
    let a = res("%i", "", unit = "f@app.service")
    check a.known and a.uid == 1001
    check not res("%i", "", unit = "f2b@.service").known
    check not res("app", "%I", unit = "f2b@.service").known
    check res("%p", "", unit = "f2b@x.service").uid == 1004

  test "a specifier or a $ that does not resolve is unknown":
    check not res("%Z", "").known
    check not res("$USER", "").known
    check not res("app", "%Z").known

  test "another name with uid 0 is root":
    let a = res("toor", "app")
    check a.known and a.userIsRoot

  test "a primary group of gid 0, or a membership of one, is the root group":
    check res("wheely", "").groupIsRoot          # primary gid 0
    let w = res("web", "")
    check w.known and w.groupIsRoot and not w.userIsRoot   # member of wheel-ish
    check not res("app", "").groupIsRoot

  test "SupplementaryGroups= resolves each group by gid":
    let a = res("app", "", supp = "adm shadow")
    check a.known and a.supplementaryGids == @[4, 42] and not a.groupIsRoot
    check res("app", "", supp = "root").groupIsRoot
    check not res("app", "", supp = "nosuchgroup").known

  test "an account that does not exist is unknown, not someone else":
    check not res("ghost", "").known
    check not res("app", "ghostgroup").known

  test "a numeric User= is that uid, with its passwd entry's groups":
    let a = res("1001", "")
    check a.known and a.uid == 1001 and a.primaryGid == 1001
    check res("0", "").userIsRoot

suite "accounts the profile creates":
  test "a sysusers entry with a pinned id of 0 is root":
    let p = parseSystemProfile("linux.sysusersEntry {\n  name = \"zero\"\n" &
      "  id = \"0\"\n}\n")
    check res("zero", "", lookup = hostAccountLookup(root, p)).userIsRoot

  test "unpinned accounts are allocated, never 0":
    let p = parseSystemProfile("linux.sysusersEntry {\n  name = \"newsvc\"\n}\n" &
      "passwd.user {\n  name = \"newu\"\n}\n")
    let l = hostAccountLookup(root, p)
    let a = res("newsvc", "", lookup = l)
    check a.known and a.uid == AllocatedId and not a.userIsRoot and
      not a.groupIsRoot
    let b = res("newu", "", lookup = l)
    check b.known and b.uid == AllocatedId and not b.groupIsRoot

  test "a membership the profile adds counts":
    let p = parseSystemProfile("passwd.group {\n  name = \"root\"\n" &
      "  members = [\"app\"]\n}\n")
    check res("app", "", lookup = hostAccountLookup(root, p)).groupIsRoot
    let q = parseSystemProfile("passwd.user {\n  name = \"newu\"\n" &
      "  groups = [\"sneaky\"]\n}\n")
    check res("newu", "", lookup = hostAccountLookup(root, q)).groupIsRoot

  test "an account already on the host keeps its ids":
    let p = parseSystemProfile("linux.sysusersEntry {\n  name = \"app\"\n" &
      "  id = \"0\"\n}\n")
    let a = res("app", "", lookup = hostAccountLookup(root, p))
    check a.known and a.uid == 1001

suite "a profile's accounts alone (profileAccountLookup)":
  test "it never reads a host database: the host's accounts are unknown":
    # The scratch root's passwd has app, and so does nearly any host's
    # /etc/passwd have root and daemon: none of them is seen.
    let p = parseSystemProfile("linux.sysusersEntry {\n  name = \"svc2\"\n" &
      "  id = \"977\"\n}\n" &
      "passwd.group {\n  name = \"svc2grp\"\n  gid = \"978\"\n" &
      "  members = [\"svc2\"]\n}\n")
    let l = profileAccountLookup(p)
    for name in ["app", "root", "daemon", "nobody", "toor"]:
      check l.uidOf(name) == UnknownId
    check l.gidOf("adm") == UnknownId and l.gidOf("root") == UnknownId
    check l.userOfUid(0) == "" and l.groupsOf("web").len == 0
    # The same name resolves through the host lookup, so the difference is
    # the host database, not the name.
    check hostAccountLookup(root).uidOf("app") == 1001
    check l.uidOf("svc2") == 977 and l.gidOf("svc2grp") == 978
    check 978 in l.groupsOf("svc2")

  test "an account only the host has does not resolve; root still does":
    let l = profileAccountLookup(SystemProfile())
    check not res("app", "", lookup = l).known
    check res("", "", lookup = l).userIsRoot
    check res("root", "", lookup = l).known

suite "what systemd would find through NSS (round 5)":
  test "a lookup over files and userdb is authoritative only when NSS names no other source":
    check host.authoritative
    let r2 = getTempDir() / ("t_service_account-nss" & testCaseScratchSlug())
    removeDir(r2)
    createDir(r2 / "etc")
    writeFile(r2 / "etc/passwd", "root:x:0:0::/root:/bin/sh\n")
    writeFile(r2 / "etc/group", "root:x:0:\n")
    check not hostAccountLookup(r2).authoritative          # no nsswitch.conf
    writeFile(r2 / "etc/nsswitch.conf", "passwd: files sss\ngroup: files sss\n")
    check not hostAccountLookup(r2).authoritative
    writeFile(r2 / "etc/nsswitch.conf", "passwd: files [NOTFOUND=return] systemd\n" &
      "group: files systemd\n")
    check hostAccountLookup(r2).authoritative

  test "under DynamicUser=yes a name a non-authoritative lookup does not know is unresolved":
    let r3 = getTempDir() / ("t_service_account-auth" & testCaseScratchSlug())
    removeDir(r3)
    createDir(r3 / "etc")
    writeFile(r3 / "etc/passwd", "root:x:0:0::/root:/bin/sh\n")
    writeFile(r3 / "etc/group", "root:x:0:\n")
    writeFile(r3 / "etc/nsswitch.conf", "passwd: files ldap\ngroup: files ldap\n")
    let a = res("dynx", "", dyn = true, lookup = hostAccountLookup(r3))
    check not a.known
    let b = res("dynx", "", dyn = true)                     # authoritative
    check b.known and b.dynamicUser

  test "a userdb record is a static account, whatever /etc/passwd says":
    let r4 = getTempDir() / ("t_service_account-userdb" & testCaseScratchSlug())
    removeDir(r4)
    createDir(r4 / "etc/userdb")
    writeFile(r4 / "etc/passwd", "root:x:0:0::/root:/bin/sh\n")
    writeFile(r4 / "etc/group", "root:x:0:\n")
    writeFile(r4 / "etc/nsswitch.conf", "passwd: files systemd\ngroup: files systemd\n")
    writeFile(r4 / "etc/userdb/ops.user",
      "{\"userName\":\"ops\",\"uid\":0,\"gid\":0}\n")
    writeFile(r4 / "etc/userdb/svc.user",
      "{\"userName\":\"svc5\",\"uid\":1500,\"memberOf\":[\"disk5\"]}\n")
    writeFile(r4 / "etc/userdb/disk5.group", "{\"groupName\":\"disk5\",\"gid\":6}\n")
    let l = hostAccountLookup(r4)
    let a = res("ops", "", dyn = true, lookup = l)
    check a.known and a.userIsRoot and not a.dynamicUser
    let b = res("svc5", "", lookup = l)
    check b.known and b.uid == 1500 and 6 in b.memberGids

  test "DynamicUser=yes without User= on an instance takes the unit's prefix":
    let a = res("", "", dyn = true, unit = "root@x.service")
    check a.known and a.userIsRoot and not a.dynamicUser
    let b = res("", "", dyn = true, unit = "svc@foo.service")
    check b.known and b.uid == 1003 and not b.dynamicUser
