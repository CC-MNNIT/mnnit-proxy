#!/usr/bin/env bash
# Runs the mnnit-proxy integration test suite inside a systemd-enabled Fedora
# container. Verifies the RHEL-family path (dnf, binary install, NM backend).
# Requires: docker, network access.
#
# Usage: bash tests/docker-fedora.sh [path-to-repo]
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NAME="mnnit-proxy-test-fedora-$$"
IMAGE="mnnit-proxy-test-fedora:latest"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "── building test image ──"
docker build -q -f "$REPO/tests/Dockerfile.fedora" "$REPO/tests/" -t "$IMAGE" || {
  echo "docker build failed"; exit 1
}

echo "── starting systemd container ──"
docker run -d --name "$NAME" --privileged \
  -v "$REPO:/repo:ro" "$IMAGE" >/dev/null || { echo "docker run failed"; exit 1; }

# Wait for systemd to be operational
for i in $(seq 1 30); do
  state=$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || echo "starting")
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
echo "systemd state: $state"

echo ""
echo "── running integration tests ──"
docker exec "$NAME" bash /repo/tests/integration-test.sh /repo
RC=$?
exit $RC
