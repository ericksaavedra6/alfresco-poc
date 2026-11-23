#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/snap/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=/dev/null
source /etc/alfresco-poc.env
kube=(/snap/bin/microk8s kubectl --kubeconfig=/home/agent/.kube/config --context=alfresco-poc --request-timeout=15s)

echo 'Checking Docker access, Compose and Buildx as the agent user'
test "$(id -un)" = agent
docker info >/dev/null
docker compose version
docker buildx version
"${kube[@]}" get --raw=/readyz
"${kube[@]}" get namespace "$POC_NAMESPACE"
"${kube[@]}" get storageclass microk8s-hostpath
"${kube[@]}" -n kube-system rollout status daemonset/calico-node --timeout=60s
"${kube[@]}" -n kube-system rollout status deployment/coredns --timeout=60s
"${kube[@]}" -n container-registry rollout status deployment/registry --timeout=60s
# Pod readiness may still be cached while kube-proxy restores routes after boot.
# Require a real registry response, allowing a bounded network convergence period.
registry_deadline=$((SECONDS + 120))
until curl --fail --silent --show-error --connect-timeout 2 --max-time 5 http://localhost:32000/v2/ >/dev/null; do
  (( SECONDS < registry_deadline )) || { echo 'Local registry did not become reachable' >&2; exit 1; }
  sleep 2
done
# A stored Ready condition can be stale if the kubelet lost its API connection.
"${kube[@]}" get leases -n kube-node-lease -o json | python3 -c '
import datetime, json, sys
leases = json.load(sys.stdin)["items"]
now = datetime.datetime.now(datetime.timezone.utc)
if not leases:
    raise SystemExit("No node heartbeats found")
for lease in leases:
    renewed = datetime.datetime.fromisoformat(lease["spec"]["renewTime"].replace("Z", "+00:00"))
    if (now - renewed).total_seconds() > 90:
        raise SystemExit("Stale node heartbeat: " + lease["metadata"]["name"])
'

if [[ ${1:-} == --smoke ]]; then
  work=$(mktemp -d)
  name="bootstrap-check-$(date +%s)"
  image=localhost:32000/alfresco-poc/bootstrap-check:smoke
  cleanup() {
    "${kube[@]}" -n "$POC_NAMESPACE" delete pod "$name" --ignore-not-found --wait=false >/dev/null || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -f "$work/Dockerfile"
    rmdir "$work"
  }
  trap cleanup EXIT
  printf 'FROM busybox:1.37.0\nRUN test -x /bin/sh\nCMD ["true"]\n' > "$work/Dockerfile"
  docker buildx build --load --tag "$image" "$work"
  docker run --rm "$image"
  docker push "$image"
  # Test containerd pull, CNI and cluster DNS using a tiny temporary pod.
  "${kube[@]}" -n "$POC_NAMESPACE" run "$name" --image="$image" --restart=Never \
    --overrides='{"spec":{"containers":[{"name":"check","image":"'"$image"'","imagePullPolicy":"Always","command":["sh","-ec","nslookup kubernetes.default.svc.cluster.local"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
  if ! "${kube[@]}" -n "$POC_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=180s; then
    "${kube[@]}" -n "$POC_NAMESPACE" describe pod "$name"
    exit 1
  fi
  "${kube[@]}" -n "$POC_NAMESPACE" logs "$name"
fi
echo 'Infrastructure verification passed'
