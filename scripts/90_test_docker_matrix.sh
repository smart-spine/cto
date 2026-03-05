#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_MODE="${TEST_MODE:-offline}"      # offline | live
RUN_SCRIPT2="${RUN_SCRIPT2:-false}"    # true | false
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-test-gateway-token}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

case "${TEST_MODE}" in
  offline)
    if [[ -z "${OPENAI_API_KEY}" ]]; then
      OPENAI_API_KEY="sk-test-offline"
    fi
    SKIP_CODEX_LOGIN="true"
    SKIP_MAIN_AGENT_SMOKE="true"
    SKIP_CTO_HEALTH_SMOKE="true"
    ;;
  live)
    [[ -n "${OPENAI_API_KEY}" ]] || {
      echo "OPENAI_API_KEY is required when TEST_MODE=live." >&2
      exit 1
    }
    SKIP_CODEX_LOGIN="false"
    SKIP_MAIN_AGENT_SMOKE="false"
    SKIP_CTO_HEALTH_SMOKE="false"
    ;;
  *)
    echo "Unsupported TEST_MODE='${TEST_MODE}'. Use offline or live." >&2
    exit 1
    ;;
esac

run_case() {
  local image="$1"
  echo "===== Docker test: ${image} (mode=${TEST_MODE}) ====="
  docker run --rm \
    -e OPENAI_API_KEY="${OPENAI_API_KEY}" \
    -e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
    -e TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    -e NON_INTERACTIVE=true \
    -e AUTO_CONFIRM=true \
    -e SKIP_CODEX_LOGIN="${SKIP_CODEX_LOGIN}" \
    -e SKIP_MAIN_AGENT_SMOKE="${SKIP_MAIN_AGENT_SMOKE}" \
    -e SKIP_CTO_HEALTH_SMOKE="${SKIP_CTO_HEALTH_SMOKE}" \
    -e BIND_MODE="direct" \
    -e BIND_DIRECT_USER_ID="7153051303" \
    -e TELEGRAM_ALLOWED_USER_ID="7153051303" \
    -v "${ROOT_DIR}:/workspace" \
    -w /workspace \
    "${image}" \
    bash -lc '
      set -euo pipefail
      chmod +x scripts/lib/common.sh scripts/00_bootstrap_dependencies.sh scripts/01_install_openclaw.sh scripts/02_setup_telegram_pairing.sh scripts/03_deploy_cto_agent.sh scripts/90_test_docker_matrix.sh
      AUTO_CLONE_REPO=false ./scripts/00_bootstrap_dependencies.sh
      ./scripts/01_install_openclaw.sh
      ./scripts/03_deploy_cto_agent.sh
      if [[ "'"${RUN_SCRIPT2}"'" == "true" ]]; then
        ./scripts/02_setup_telegram_pairing.sh
      fi
    '
}

run_case "ubuntu:22.04"
run_case "ubuntu:24.04"

echo "Docker matrix tests completed successfully."
