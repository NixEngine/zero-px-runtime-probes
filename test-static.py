"""Read-only validation; never import or execute either runtime probe."""
from __future__ import annotations

import base64
import hashlib
import json
import re
from pathlib import Path

import yaml  # Use only an already-installed PyYAML; do not install dependencies.

root = Path(__file__).resolve().parent
workflow_text = (root / "windows-wsl2-compose.yml").read_text(encoding="utf-8")
workflow = yaml.safe_load(workflow_text)
assert workflow["on"] == {"workflow_dispatch": {}}
assert workflow["permissions"] == {}
job = workflow["jobs"]["probe"]
assert job["runs-on"] == "windows-2025"
assert job["timeout-minutes"] == 20
assert job["if"] == "github.event.repository.private == false"
steps = job["steps"]
assert len(steps) == 2
assert all(step["shell"] == "pwsh" and "uses" not in step for step in steps)
assert all(len(step["run"]) < 21_000 for step in steps)
assert all("${{" not in step["run"] for step in steps)
hashes = {}
for filename, variable in (("probe-wsl.ps1", "windows64"), ("probe-linux.sh", "linux64")):
    source = (root / filename).read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n") + "\n"
    matches = re.findall(r"\$" + variable + r" = '([A-Za-z0-9+/=]+)'", workflow_text)
    assert len(matches) == 1
    decoded = base64.b64decode(matches[0], validate=True)
    assert decoded == source.encode("utf-8")
    digest = hashlib.sha256(decoded).hexdigest()
    hashes[filename] = digest
    assert f"# {filename} sha256: {digest}" in workflow_text
    assert digest in "\n".join(step["run"] for step in steps)
    assert not re.search(r"[A-Za-z]:[\\/]Users[\\/]", decoded.decode("utf-8"))
assert not re.search(r"(?m)^\s*(?:uses|secrets|environment):", workflow_text)
print(json.dumps({"yaml": "PASS", "source_binding": "PASS", "source_sha256": hashes,
                  "run_characters": [len(step["run"]) for step in steps],
                  "runtime_executed": False}, sort_keys=True))
