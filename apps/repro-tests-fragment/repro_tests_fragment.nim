## repro-tests-fragment: lists a test binary's tests through its ``tests``
## entry and writes the dynamic graph fragment that runs each of them as an
## action of its own.
##
## The listing edge of ``NimUnittestBinary.runPerTest``
## (``libs/ct_test_nim_unittest``) runs it as
##
##   repro-tests-fragment --binary=<test binary> --out=<fragment>
##     --id-prefix=<id> --collector=<id> [--stats-name=<name>] [--cwd=<dir>]
##
## and that edge's collector as ``repro-tests-fragment --check=<fragment>``.
## Everything it does is ``ct_test_nim_unittest/tests_fragment``'s
## ``runProducer``; see that module for the fragment it writes and what it
## refuses.

import std/os

import ct_test_nim_unittest/tests_fragment

when isMainModule:
  quit runProducer(commandLineParams())
