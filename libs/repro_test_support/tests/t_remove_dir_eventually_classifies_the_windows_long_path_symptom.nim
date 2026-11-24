## `removeDirEventually` must escalate to the extended-length path on the
## Windows error a tree deeper than MAX_PATH produces, not re-raise it.
##
## The Windows runner that exposed this reported
## "The system cannot find the path specified" (ERROR_PATH_NOT_FOUND, 3) from
## `removeDir` over nim 2.2.10's `dist/nimble/tests/...` tree, after every
## assertion of t_compiler_args_transport had passed. The classification is a
## pure function so this test runs on every host; the teardown itself, which
## needs a real over-MAX_PATH tree and a host without LongPathsEnabled, is
## exercised by the Windows lane's t_compiler_args_transport.
##
## No mocks: the unit under test is a pure predicate over an error code and a
## message.
import std/unittest
import repro_test_support

suite "windows long-path symptom classification":
  test "ERROR_PATH_NOT_FOUND is the symptom, by code, whatever the locale":
    check isWindowsPathNotFound(3'i32, "")
    check isWindowsPathNotFound(3'i32, "Das System kann den angegebenen Pfad nicht finden.")
  test "the English message is the symptom when the code is unavailable":
    check isWindowsPathNotFound(0'i32, "The system cannot find the path specified.")
  test "ENOTEMPTY and unrelated failures are not this symptom":
    check not isWindowsPathNotFound(145'i32, "The directory is not empty.")
    check not isWindowsPathNotFound(5'i32, "Access is denied.")
    check not isWindowsPathNotFound(0'i32, "")
