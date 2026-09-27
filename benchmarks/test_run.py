import sys
import tempfile
import unittest
from pathlib import Path
from run import measure, summary


class BenchmarkTests(unittest.TestCase):
    def test_percentiles_exclude_failure(self):
        rows = [{'ok': True, 'time': n} for n in range(1, 21)]
        rows.append({'ok': False, 'time': 1000})
        self.assertEqual(summary(rows, 'time'), {'n': 20, 'median': 10.5, 'p95': 19})
        self.assertEqual(summary([], 'time'), {'n': 0, 'median': None, 'p95': None})

    def run_child(self, source, timeout):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'child.py'
            script.write_text(source)
            return measure(Path(sys.executable), script, Path('unused-model'), timeout)

    def test_timeout_is_failure_and_child_reaped(self):
        result = self.run_child('import time; time.sleep(10)', .05)
        self.assertTrue(result['timeout'])
        self.assertFalse(result['ok'])
        self.assertIsNotNone(result['exit_code'])

    def test_successful_exit_without_audio_is_failure(self):
        result = self.run_child('import sys; sys.stdin.read()', 2)
        self.assertEqual(result['exit_code'], 0)
        self.assertFalse(result['ok'])

    def test_early_child_exit_is_reported(self):
        result = self.run_child("import sys; sys.exit(7)", 2)
        self.assertEqual(result["exit_code"], 7)
        self.assertFalse(result["ok"])

    def test_large_stderr_does_not_deadlock(self):
        result = self.run_child('import sys; sys.stdin.read(); sys.stderr.write("x"*100000); sys.exit(3)', 2)
        self.assertEqual(result['exit_code'], 3)
        self.assertFalse(result['timeout'])
        self.assertEqual(len(result['error']), 2000)


if __name__ == '__main__':
    unittest.main()
