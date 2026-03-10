#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPENAI_API_KEY="${OPENAI_API_KEY:-}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-test-gateway-token}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
RUN_SCRIPT2="${RUN_SCRIPT2:-false}"

if [[ -z "${OPENAI_API_KEY}" ]]; then
  echo "OPENAI_API_KEY is required for docker matrix test." >&2
  exit 1
fi

run_case() {
  local image="$1"
  echo "===== Docker test: ${image} ====="
  docker run --rm \
    -e OPENAI_API_KEY \
    -e OPENCLAW_GATEWAY_TOKEN \
    -e TELEGRAM_BOT_TOKEN \
    -e NON_INTERACTIVE=true \
    -e AUTO_CONFIRM=true \
    -e BIND_GROUP_ID="-1003633569118" \
    -e BIND_TOPIC_ID="654" \
    -v "${ROOT_DIR}:/workspace" \
    -w /workspace \
    "${image}" \
    bash -lc '
      set -euo pipefail
      chmod +x scripts/lib/common.sh scripts/00_bootstrap_dependencies.sh scripts/01_install_openclaw.sh scripts/02_setup_telegram_pairing.sh scripts/03_deploy_cto_agent.sh
      ./scripts/00_bootstrap_dependencies.sh
      ./scripts/01_install_openclaw.sh
      ./scripts/03_deploy_cto_agent.sh
      if [[ "'"${RUN_SCRIPT2}"'" == "true" ]]; then
        ./scripts/02_setup_telegram_pairing.sh
      fi
    '
}

run_case "ubuntu:22.04"
run_case "ubuntu:24.04"

echo "All docker matrix tests completed."
