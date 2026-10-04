"""Check the coverage command's pass/fail contract, including absent instrumentation."""
import json
import subprocess
import sys
import unittest


class CoverageGateChecks(unittest.TestCase):
    def check_report(self, files):
        return subprocess.run(
            [sys.executable, "scripts/verify-refactor-coverage.py", "/module.swift"],
            input=json.dumps({"data": [{"files": files}]}), text=True, capture_output=True
        ).returncode

    def file(self, coverage=80, filename="/module.swift"):
        return {"filename": filename, "summary": {
            metric: {"percent": coverage} for metric in ("lines", "functions", "regions")
        }}

    def test_threshold_passes(self):
        self.assertEqual(self.check_report([self.file()]), 0)

    def test_below_threshold_fails(self):
        self.assertNotEqual(self.check_report([self.file(79.9)]), 0)

    def test_missing_module_fails(self):
        self.assertNotEqual(self.check_report([]), 0)

    def test_unexpected_module_fails(self):
        self.assertNotEqual(self.check_report([self.file(filename="/other.swift")]), 0)


if __name__ == "__main__":
    unittest.main()
