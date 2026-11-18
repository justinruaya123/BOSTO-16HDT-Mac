"""Offline release policy tests. Run: python3 -m unittest discover -s UnifiedDriver/tests -p test_version.py"""
import sys
import contextlib
import io
import subprocess
from unittest.mock import patch
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from version import build_version, main, next_version, parse_version


class VersionTests(unittest.TestCase):
    def test_bundle_build_number(self):
        self.assertEqual(build_version('9'), '9')
        self.assertEqual(build_version('9', '42'), '51')
        self.assertLess(int(build_version('9', '42')), int(build_version('9', '43')))
        for value in ['', '0', '-1', '01', '1.2', '1\n', '١']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                build_version('9', value)
            with self.subTest(source=value), self.assertRaises(ValueError):
                build_version(value)

    def test_next_checks_ancestry_but_allows_tagged_reruns(self):
        for status in [0, 1, 128]:
            with self.subTest(status=status), patch('sys.argv', ['version.py', '--next', 'target']), patch(
                'version.subprocess.check_output', side_effect=['target', 'v0.1.4', 'highest']
            ), patch('version.subprocess.run', return_value=subprocess.CompletedProcess([], status)) as ancestry:
                with contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()):
                    if status == 0:
                        main()
                        self.assertEqual(output.getvalue().strip(), '0.1.5')
                    else:
                        with self.assertRaises(SystemExit):
                            main()
                ancestry.assert_called_once_with(['git', 'merge-base', '--is-ancestor', 'highest', 'target'])
        with patch('sys.argv', ['version.py', '--next', 'target']), patch(
            'version.subprocess.check_output', side_effect=['target', 'v0.1.4\nv0.1.5', 'target', 'newer']
        ), patch('version.subprocess.run') as ancestry, contextlib.redirect_stdout(io.StringIO()) as output:
            main()
            self.assertEqual(output.getvalue().strip(), '0.1.4')
            ancestry.assert_not_called()

    def test_first_release(self):
        self.assertEqual(next_version('0.1.4', [('v0.1.3', 'old')], 'new'), '0.1.4')

    def test_numeric_order_and_increment(self):
        tags = [('v0.9.99', 'a'), ('v0.10.9', 'b'), ('v0.10.10', 'c')]
        self.assertEqual(next_version('0.1.4', tags, 'new'), '0.10.11')
        self.assertEqual(next_version('0.1.4', [('v2.0.0', 'old')], 'new'), '2.0.1')

    def test_source_minimum(self):
        self.assertEqual(next_version('1.0.0', [('v0.9.99', 'old')], 'new'), '1.0.0')
        self.assertEqual(next_version('0.2.0', [('v0.1.9', 'old')], 'new'), '0.2.0')

    def test_no_tags(self):
        self.assertEqual(next_version('0.1.4', [], 'new'), '0.1.4')

    def test_rerun_reuses_tag_even_after_newer_release(self):
        tags = [('v0.1.4', 'same'), ('v0.1.5', 'newer')]
        self.assertEqual(next_version('1.0.0', tags, 'same'), '0.1.4')

    def test_invalid_tags_ignored(self):
        tags = [(name, 'old') for name in ['v01.2.3', 'v1.02.3', 'v1.2.03', 'v1.2', 'v1.2.3-rc1', 'v1.2.3+build', '1.2.3', 'v9.9.9\n', 'v١.2.3']]
        self.assertEqual(next_version('0.1.4', tags, 'new'), '0.1.4')

    def test_invalid_source_or_override_rejected(self):
        for value in ['', 'v1.2.3', '1.2', '-1.2.3', '01.2.3', '1.2.3\n', '1.2.3-rc1']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_version(value)
        with self.assertRaises(ValueError):
            next_version('invalid', [], 'new')


if __name__ == '__main__':
    unittest.main()
