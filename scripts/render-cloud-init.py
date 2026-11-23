#!/usr/bin/env python3
"""Render the real Terraform template with a dummy password for schema validation."""
import base64
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
template = json.dumps((root / 'cloud-init-alfresco.yaml').as_posix())
bootstrap = json.dumps((root / 'scripts/bootstrap-instance.sh').as_posix())
verify = json.dumps((root / 'scripts/verify-instance.sh').as_posix())
expression = f'''base64encode(templatefile({template}, {{
  node_ip = "10.146.220.55",
  agent_password_hash = "$6$validation-only$not-a-real-password-hash",
  bootstrap_revision = "validation-revision",
  bootstrap_script_base64 = base64encode(file({bootstrap})),
  verify_script_base64 = base64encode(file({verify}))
}}))'''
expression = ' '.join(expression.splitlines())
# An empty working directory avoids reading the deployment state or requiring a backend.
with tempfile.TemporaryDirectory() as folder:
    result = subprocess.run(['terraform', f'-chdir={folder}', 'console'], input=expression + '\n', text=True, capture_output=True)
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
rendered = base64.b64decode(json.loads(result.stdout)).decode()
target = pathlib.Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(rendered, encoding='utf-8')
print('Rendered cloud-init with dummy credentials for schema validation')
