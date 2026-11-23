#!/usr/bin/env bash
# Runs as root from cloud-init; safe to repeat on this single-node POC.
set -Eeuo pipefail
export PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=/dev/null
source /etc/alfresco-poc.env
umask 027
exec 9>/run/lock/alfresco-poc-bootstrap.lock
flock -n 9 || { echo 'Another bootstrap is already running' >&2; exit 1; }
install -d -m 0750 /var/lib/alfresco-poc
exec > >(tee -a /var/log/alfresco-poc-bootstrap.log) 2>&1
trap 'echo "Bootstrap failed at line $LINENO; see /var/log/alfresco-poc-bootstrap.log" >&2' ERR
mk8s=/snap/bin/microk8s
data=/var/snap/microk8s/current

echo 'Preparing SSH, Docker, workspace and node prerequisites'
sshd -t
systemctl enable --now ssh docker
systemctl reload ssh
docker compose version
docker buildx version
docker info >/dev/null
usermod -aG docker agent
install -d -o agent -g agent -m 0750 /home/agent/alfresco-poc

# Preserve unrelated Docker settings. Keep forwarding usable for the Kubernetes CNI.
python3 - <<'PY'
import json
import pathlib
path = pathlib.Path('/etc/docker/daemon.json')
config = json.loads(path.read_text()) if path.exists() else {}
registries = config.setdefault('insecure-registries', [])
if 'localhost:32000' not in registries:
    registries.append('localhost:32000')
config['ip-forward-no-drop'] = True
path.write_text(json.dumps(config, indent=2) + '\n')
PY
systemctl restart docker

cat >/etc/modules-load.d/alfresco-poc.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-alfresco-poc.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl -p /etc/sysctl.d/99-alfresco-poc.conf

timeout 300 snap wait system seed
if ! snap list microk8s >/dev/null 2>&1; then
  timeout 600 snap install microk8s --classic --channel="$MICROK8S_CHANNEL"
fi
usermod -aG microk8s agent

# Never copy certs from another installation over an initialized cluster.
# The mounted directory is retained as an export destination, not a restore source.
python3 - "$data" "$NODE_IP" "$API_ADDRESS" <<'PY'
import ipaddress
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
node_ip, api_ip = (str(ipaddress.IPv4Address(x)) for x in sys.argv[2:])
kubelet = root / 'args/kubelet'
text = re.sub(r'^--node-ip(?:=|\s).*\n?', '', kubelet.read_text(), flags=re.M)
kubelet.write_text(text.rstrip() + '\n--node-ip=' + node_ip + '\n')
template = root / 'certs/csr.conf.template'
text = template.read_text()
section = re.search(r'^\[\s*alt_names\s*\]\s*\n(.*?)(?=^\[|\Z)', text, re.M | re.S)
if section is None:
    raise SystemExit('Missing alt_names section in MicroK8s CSR template')
body = section.group(1)
indexes = [int(x) for x in re.findall(r'^IP\.(\d+)\s*=', body, re.M)]
index = max(indexes, default=0)
for address in (node_ip, api_ip):
    if not re.search(r'^IP\.\d+\s*=\s*' + re.escape(address) + r'\s*$', body, re.M):
        index += 1
        body = body.rstrip() + f'\nIP.{index} = {address}\n'
template.write_text(text[:section.start(1)] + body + text[section.end(1):])
PY

echo 'Checking node certificate consistency'
repaired_credentials=false
# Compare public CAs without logging client certificates, tokens or private keys.
if ! python3 - "$data" <<'PY'
import base64
import pathlib
import subprocess
import sys
import yaml

root = pathlib.Path(sys.argv[1])
expected = subprocess.check_output(['openssl', 'x509', '-in', str(root / 'certs/ca.crt'), '-outform', 'DER'])
for name in ('client', 'controller', 'scheduler', 'proxy', 'kubelet'):
    config = yaml.safe_load((root / f'credentials/{name}.config').read_text())
    cluster = config['clusters'][0]['cluster']
    if 'certificate-authority-data' in cluster:
        pem = base64.b64decode(cluster['certificate-authority-data'])
    else:
        pem = pathlib.Path(cluster['certificate-authority']).read_bytes()
    actual = subprocess.check_output(['openssl', 'x509', '-outform', 'DER'], input=pem)
    if expected != actual:
        raise SystemExit('Component kubeconfig CA mismatch: ' + name)
PY
then
  # Re-import the SAME current CA through the supported command, rebuilding all
  # client credentials. Refreshing only server.crt cannot repair a CA mismatch.
  repair_dir=$(mktemp -d /var/lib/alfresco-poc/ca-repair.XXXXXX)
  chmod 0700 "$repair_dir"
  install -m 0600 "$data/certs/ca.crt" "$data/certs/ca.key" "$repair_dir/"
  timeout 180 "$mk8s" refresh-certs "$repair_dir"
  rm -f "$repair_dir/ca.crt" "$repair_dir/ca.key"
  rmdir "$repair_dir"
  repaired_credentials=true
fi

timeout 180 "$mk8s" refresh-certs --cert server.crt
timeout 120 "$mk8s" start
# API readiness must precede credential renewal on the CNI pods. Waiting for
# all of MicroK8s first can deadlock on pods still mounting the previous CA.
deadline=$((SECONDS + 180))
until "$mk8s" kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { echo 'Kubernetes API did not become ready' >&2; exit 1; }
  sleep 5
done
if "$repaired_credentials"; then
  # Refresh projected credentials on the infrastructure pods after repairing the
  # old bootstrap's inconsistent CA/client configuration.
  "$mk8s" kubectl -n kube-system rollout restart daemonset/calico-node deployment/calico-kube-controllers
fi
"$mk8s" kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
"$mk8s" kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s
timeout 600 "$mk8s" status --wait-ready
"$mk8s" kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo 'Preparing DNS, persistent storage and local image registry'
timeout 600 "$mk8s" enable dns hostpath-storage registry
"$mk8s" kubectl -n kube-system rollout status deployment/coredns --timeout=300s
"$mk8s" kubectl -n kube-system rollout status deployment/hostpath-provisioner --timeout=300s
"$mk8s" kubectl -n container-registry rollout status deployment/registry --timeout=300s
"$mk8s" kubectl create namespace "$POC_NAMESPACE" --dry-run=client -o yaml | "$mk8s" kubectl apply -f -

echo 'Installing kubectl and private kubeconfigs for agent'
cat >/usr/local/bin/kubectl <<'EOF'
#!/bin/sh
exec /snap/bin/microk8s kubectl --kubeconfig="${KUBECONFIG:-$HOME/.kube/config}" "$@"
EOF
chmod 0755 /usr/local/bin/kubectl
install -d -o agent -g agent -m 0700 /home/agent/.kube
"$mk8s" config > /home/agent/.kube/config
"$mk8s" kubectl --kubeconfig=/home/agent/.kube/config config rename-context microk8s alfresco-poc
"$mk8s" kubectl --kubeconfig=/home/agent/.kube/config config set-context alfresco-poc --namespace="$POC_NAMESPACE"
chown agent:agent /home/agent/.kube/config
chmod 0600 /home/agent/.kube/config

# Export access on the existing host mount; never upload kubeconfigs as artifacts.
install -d -m 0700 /mnt/microk8s-certs
"$mk8s" config | sed "s@https://127.0.0.1:16443@https://$API_ADDRESS:16443@" > /mnt/microk8s-certs/alfresco-poc.kubeconfig
chmod 0600 /mnt/microk8s-certs/alfresco-poc.kubeconfig
"$mk8s" kubectl --kubeconfig=/mnt/microk8s-certs/alfresco-poc.kubeconfig config rename-context microk8s alfresco-poc

runuser -l agent -c '/usr/local/bin/alfresco-poc-verify'
printf '%s\n' "$BOOTSTRAP_REVISION" > /var/lib/alfresco-poc/bootstrap-revision
echo 'Alfresco POC infrastructure bootstrap completed'
