"""Enforce coverage of the refactored logic modules, excluding UI and old adapters."""
import json
import sys
from pathlib import Path

report = json.load(sys.stdin)
failed = []
files = report["data"][0]["files"]
expected = {str(Path(path).resolve()) for path in sys.argv[1:]}
measured = {str(Path(file["filename"]).resolve()) for file in files}
if not expected or measured != expected:
    failed.append("Coverage module set mismatch: missing or unexpected instrumentation")
for file in files:
    for metric in ("lines", "functions", "regions"):
        coverage = file["summary"][metric]["percent"]
        if coverage < 80:
            failed.append(f'{file["filename"]}: {metric} {coverage:.2f}% < 80%')
if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print("Coverage gate passed: every refactored module has >=80% line, function and region coverage")
