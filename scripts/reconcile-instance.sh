#!/usr/bin/env bash
# Run on the trusted self-hosted runner, after applying the reviewed Terraform plan.
set -Eeuo pipefail
project=alfresco-poc
instance=alfresco-poc-app
expected=$(terraform output -raw bootstrap_revision)

deadline=$((SECONDS + 120))
until lxc --project "$project" exec "$instance" -- true; do
  (( SECONDS < deadline )) || { echo 'LXD guest agent did not become available' >&2; exit 1; }
  sleep 5
done

# Updating LXD user-data takes effect at the next boot. Never recreate the VM.
# Allow a newly created instance to reach write_files before deciding to restart.
deadline=$((SECONDS + 60))
until lxc --project "$project" exec "$instance" -- grep -qF "BOOTSTRAP_REVISION='$expected'" /etc/alfresco-poc.env 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    echo 'Restarting the existing VM to load updated cloud-init user-data'
    lxc --project "$project" restart "$instance" --timeout=60
    break
  fi
  sleep 5
done

deadline=$((SECONDS + 120))
until lxc --project "$project" exec "$instance" -- true; do
  (( SECONDS < deadline )) || { echo 'LXD guest agent did not return after restart' >&2; exit 1; }
  sleep 5
done
timeout 1500 lxc --project "$project" exec "$instance" -- timeout 1440 cloud-init status --wait
actual=$(lxc --project "$project" exec "$instance" -- cat /var/lib/alfresco-poc/bootstrap-revision)
[[ "$actual" == "$expected" ]] || { echo 'The expected bootstrap did not complete' >&2; exit 1; }
lxc --project "$project" exec "$instance" -- runuser -l agent -c '/usr/local/bin/alfresco-poc-verify --smoke'
