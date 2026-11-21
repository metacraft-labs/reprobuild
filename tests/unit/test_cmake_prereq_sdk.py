"""Exercise the prerequisite shell script with real temporary SDK/cache trees.

The fake uname permits Darwin and Linux policy checks on either host. Fake
xcrun controls developer-tool discovery and fake find supplies an unrelated
store SDK, so installed store contents cannot hide the regression. Fake cmake
records configuration/build calls instead of rebuilding the entire CMake fork;
this test verifies orchestration, not CMake's own compiler implementation.
"""
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/build_reprobuild_cmake_prereq.sh'


class CMakePrerequisiteSDKTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='cmake-prereq-sdk-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.work = self.root / 'reprobuild'
        self.fork = self.root / 'reprobuild-cmake'
        self.bin = self.root / 'tools'
        for path in (self.work, self.fork, self.bin):
            path.mkdir()
        self.sdk = self.root / 'SDK [14.4]+ (toolchain).sdk'
        self.other = self.root / 'unrelated-11.3.sdk'
        for path in (self.sdk, self.other):
            (path / 'System/Library/Frameworks').mkdir(parents=True)
        self.calls = self.root / 'calls.jsonl'
        self.env = os.environ.copy()
        self.env.pop('SDKROOT', None)
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env['PATH'],
                        SDK_TEST_OS='Darwin', SDK_TEST_STORE=str(self.other),
                        SDK_TEST_XCRUN=str(self.other), SDK_TEST_CALLS=str(self.calls))
        self.tool('uname', '#!/bin/sh\necho "$SDK_TEST_OS"\n')
        self.tool('find', '#!/bin/sh\ncase "$*" in *MacOSX*) echo "$SDK_TEST_STORE";; esac\n')
        self.tool('xcrun', '#!/bin/sh\n[ "$*" = "--sdk macosx --show-sdk-path" ] || exit 2\n[ -z "$SDK_TEST_XCRUN" ] && exit 1\necho "$SDK_TEST_XCRUN"\n')
        self.tool('cmake', '#!' + sys.executable + '\n' + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['SDK_TEST_CALLS'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
if '-S' in args:
    build = Path('build')
    build.mkdir(exist_ok=True)
    rows = ['ENABLE_IPV6:BOOL=OFF']
    rows += [a[2:].replace('=', ':STRING=', 1) for a in args if a.startswith('-D')]
    (build / 'CMakeCache.txt').write_text('\\n'.join(rows) + '\\n')
''')

    def tool(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_script(self):
        result = subprocess.run(['bash', str(SCRIPT)], cwd=self.work, env=self.env,
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls

    def cache(self, sdk):
        build = self.fork / 'build'
        (build / 'bin').mkdir(parents=True)
        (build / 'bin/cmake').write_text('#!/bin/sh\nexit 0\n')
        (build / 'bin/cmake').chmod(0o755)
        (build / 'CMakeCache.txt').write_text(f'CMAKE_OSX_SYSROOT:PATH={sdk}\n')
        return build

    def configure(self, calls):
        return next(args for args in calls if '-S' in args)

    def test_sdkroot_overrides_unrelated_store_and_xcrun(self):
        self.env['SDKROOT'] = str(self.sdk)
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-DCMAKE_OSX_SYSROOT=' + str(self.sdk), self.configure(calls))
        # Framework paths must survive the second parsing of CMake flags by a shell.
        import shlex
        flags = next(a.split('=', 1)[1] for a in self.configure(calls) if a.startswith('-DCMAKE_CXX_FLAGS='))
        self.assertEqual(shlex.split(flags), ['-F' + str(self.sdk / 'System/Library/Frameworks')])

    def test_unset_sdkroot_uses_xcrun(self):
        self.env['SDK_TEST_XCRUN'] = str(self.sdk)
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-DCMAKE_OSX_SYSROOT=' + str(self.sdk), self.configure(calls))

    def test_invalid_sdkroot_fails_without_fallback(self):
        self.env['SDKROOT'] = str(self.root / 'missing.sdk')
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SDKROOT', result.stderr)
        self.assertEqual(calls, [])

    def test_empty_explicit_sdkroot_fails_without_fallback(self):
        self.env['SDKROOT'] = ''
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SDKROOT', result.stderr)
        self.assertEqual(calls, [])

    def test_xcrun_failure_and_invalid_directory_fail(self):
        for sdk in ('', str(self.root / 'missing.sdk')):
            with self.subTest(sdk=sdk):
                self.env['SDK_TEST_XCRUN'] = sdk
                result, calls = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('xcrun', result.stderr)
                self.assertEqual(calls, [])

    def test_cached_wrong_sdk_is_reconfigured_before_refresh(self):
        self.env['SDKROOT'] = str(self.sdk)
        build = self.cache(self.other)
        marker = build / 'stale-marker'
        marker.touch()
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-S', calls[0])
        self.assertIn('-DCMAKE_OSX_SYSROOT=' + str(self.sdk), self.configure(calls))
        self.assertFalse(marker.exists())

    def test_cached_missing_sdk_is_reconfigured(self):
        self.env['SDKROOT'] = str(self.sdk)
        build = self.cache(self.sdk)
        (build / 'CMakeCache.txt').write_text('ENABLE_IPV6:BOOL=OFF\n')
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-S', calls[0])
        self.assertIn('-DCMAKE_OSX_SYSROOT=' + str(self.sdk), self.configure(calls))

    def test_sdkroot_file_is_rejected(self):
        sdk_file = self.root / 'sdk-file'
        sdk_file.touch()
        self.env['SDKROOT'] = str(sdk_file)
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SDKROOT', result.stderr)
        self.assertEqual(calls, [])

    def test_cached_matching_sdk_keeps_incremental_refresh(self):
        self.env['SDKROOT'] = str(self.sdk)
        build = self.cache(self.sdk)
        marker = build / 'keep-marker'
        marker.touch()
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ['--build', 'build'])
        self.assertTrue(marker.exists())

    def test_invalid_sdkroot_cannot_use_cached_binary(self):
        self.env['SDKROOT'] = str(self.root / 'missing.sdk')
        self.cache(self.sdk)
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SDKROOT', result.stderr)
        self.assertEqual(calls, [])

    def test_linux_ignores_sdk_selection(self):
        self.env['SDK_TEST_OS'] = 'Linux'
        self.env['SDKROOT'] = str(self.root / 'missing.sdk')
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(a.startswith('-DCMAKE_OSX_SYSROOT=') for a in self.configure(calls)))


if __name__ == '__main__':
    unittest.main()
