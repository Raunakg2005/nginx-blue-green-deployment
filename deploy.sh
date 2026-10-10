#!/usr/bin/env bash
# ==============================================================================
# Production Zero-Downtime Blue-Green Deployment Automation Script
# ==============================================================================

set -euo pipefail

# Visual terminal formatting
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RESET='\033[0m'

# Configuration & Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

STATE_FILE=".active_env"
UPSTREAM_CONF="nginx/conf.d/upstream.conf"
HEALTH_MAX_RETRIES=15
HEALTH_RETRY_INTERVAL=2
DRAIN_WAIT_SECONDS=7

# Cross-platform Docker Compose wrapper (seamless across Linux, macOS, WSL, and Windows Git Bash)
run_compose() {
    if command -v docker.exe >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
        docker.exe compose "$@"
    else
        docker compose "$@"
    fi
}

# Helper logging functions
log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $1"
}

log_step() {
    echo -e "\n${COLOR_BOLD}===> $1${COLOR_RESET}"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

# Print header banner
print_banner() {
    echo -e "${COLOR_CYAN}${COLOR_BOLD}"
    echo "================================================================="
    echo "   ZERO-DOWNTIME BLUE-GREEN APPLICATION DEPLOYMENT AUTOMATION"
    echo "================================================================="
    echo -e "${COLOR_RESET}"
}

usage() {
    echo "Usage: $0 [OPTIONS] <VERSION_TAG>"
    echo ""
    echo "Arguments:"
    echo "  VERSION_TAG           Required application version (e.g. v1.0.0, v2.0.0)"
    echo ""
    echo "Options:"
    echo "  --simulate-failure    Simulate an unhealthy build to test auto-rollback"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 v2.0.0"
    echo "  $0 --simulate-failure v2.1.0"
    exit 1
}

# Parse command line arguments
SIMULATE_FAIL=false
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulate-failure)
            SIMULATE_FAIL=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "${TARGET_VERSION}" ]]; then
                TARGET_VERSION="$1"
            else
                log_error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "${TARGET_VERSION}" ]]; then
    log_error "Version tag is required."
    usage
fi

print_banner

# Step 1: Detect currently active environment
log_step "Step 1: Detecting Currently Active Environment"

ACTIVE_ENV=""
if [[ -f "${STATE_FILE}" ]]; then
    ACTIVE_ENV=$(tr -d '[:space:]' < "${STATE_FILE}")
fi

if [[ "${ACTIVE_ENV}" != "blue" && "${ACTIVE_ENV}" != "green" ]]; then
    if grep -q "app-green" "${UPSTREAM_CONF}" 2>/dev/null; then
        ACTIVE_ENV="green"
    else
        ACTIVE_ENV="blue"
    fi
fi

if [[ "${ACTIVE_ENV}" == "blue" ]]; then
    TARGET_ENV="green"
    TARGET_SERVICE="app-green"
    TARGET_PORT=8082
    PREV_SERVICE="app-blue"
    PREV_PORT=8081
    ACTIVE_COLOR="${COLOR_BLUE}"
    TARGET_COLOR="${COLOR_GREEN}"
else
    TARGET_ENV="blue"
    TARGET_SERVICE="app-blue"
    TARGET_PORT=8081
    PREV_SERVICE="app-green"
    PREV_PORT=8082
    ACTIVE_COLOR="${COLOR_GREEN}"
    TARGET_COLOR="${COLOR_BLUE}"
fi

echo -e "Currently Active Environment: ${ACTIVE_COLOR}${COLOR_BOLD}${ACTIVE_ENV^^}${COLOR_RESET}"
echo -e "Target Deployment Candidate:  ${TARGET_COLOR}${COLOR_BOLD}${TARGET_ENV^^}${COLOR_RESET}"
echo -e "Target Port:                  ${COLOR_BOLD}${TARGET_PORT}${COLOR_RESET}"
echo -e "Release Version:              ${COLOR_BOLD}${TARGET_VERSION}${COLOR_RESET}"
if [[ "${SIMULATE_FAIL}" == true ]]; then
    echo -e "Simulation Mode:              ${COLOR_YELLOW}${COLOR_BOLD}SIMULATE_FAILURE ENABLED (Test Rollback)${COLOR_RESET}"
fi

# Step 2: Build & Start Target Environment
log_step "Step 2: Building & Provisioning Target Container [${TARGET_SERVICE}]"

export APP_VERSION="${TARGET_VERSION}"
if [[ "${TARGET_ENV}" == "green" ]]; then
    export SIMULATE_FAILURE_GREEN="${SIMULATE_FAIL}"
    export SIMULATE_FAILURE_BLUE="false"
else
    export SIMULATE_FAILURE_BLUE="${SIMULATE_FAIL}"
    export SIMULATE_FAILURE_GREEN="false"
fi

# Ensure variables propagate across all environments (WSL, Docker Compose, Linux, Windows)
cat <<EOF > .env
APP_VERSION=${APP_VERSION}
SIMULATE_FAILURE_BLUE=${SIMULATE_FAILURE_BLUE}
SIMULATE_FAILURE_GREEN=${SIMULATE_FAILURE_GREEN}
EOF
export WSLENV="APP_VERSION:SIMULATE_FAILURE_BLUE:SIMULATE_FAILURE_GREEN:${WSLENV:-}"

log_info "Running: docker compose up -d --build ${TARGET_SERVICE}"
run_compose up -d --build "${TARGET_SERVICE}"

# Step 3: Health Check Probe Loop
log_step "Step 3: Performing Automated Health Probes on [${TARGET_SERVICE}:http://localhost:${TARGET_PORT}/health]"

log_info "Polling health check endpoint (Max ${HEALTH_MAX_RETRIES} attempts, interval ${HEALTH_RETRY_INTERVAL}s)..."

HEALTH_PASSED=false
PROBE_URL="http://127.0.0.1:${TARGET_PORT}/health"

for ((i=1; i<=HEALTH_MAX_RETRIES; i++)); do
    HTTP_CODE=$(curl -s -o /tmp/health_resp.json -w "%{http_code}" "${PROBE_URL}" 2>/dev/null || echo "000")
    
    if [[ "${HTTP_CODE}" == "200" ]]; then
        RESP_STATUS=$(grep -o '"status":"[^"]*"' /tmp/health_resp.json 2>/dev/null || echo "")
        RESP_VER=$(grep -o '"version":"[^"]*"' /tmp/health_resp.json 2>/dev/null || echo "")
        log_success "Attempt ${i}/${HEALTH_MAX_RETRIES}: Healthy! HTTP 200 OK (${RESP_STATUS}, ${RESP_VER})"
        HEALTH_PASSED=true
        break
    else
        log_warn "Attempt ${i}/${HEALTH_MAX_RETRIES}: Received HTTP ${HTTP_CODE}. Waiting ${HEALTH_RETRY_INTERVAL}s..."
        sleep "${HEALTH_RETRY_INTERVAL}"
    fi
done

# Step 4: Handle Failure / Rollback
if [[ "${HEALTH_PASSED}" != true ]]; then
    echo -e "\n${COLOR_RED}${COLOR_BOLD}================================================================="
    echo "  DEPLOYMENT ABORTED: HEALTH CHECK FAILED FOR ${TARGET_ENV^^}"
    echo "=================================================================${COLOR_RESET}"
    log_error "Target container ${TARGET_SERVICE} failed health validation on port ${TARGET_PORT}."
    log_warn "Initiating automated rollback: Nginx configuration remains untouched."
    log_info "Stopping unhealthy candidate container: ${TARGET_SERVICE}..."
    
    run_compose stop "${TARGET_SERVICE}" >/dev/null 2>&1 || true
    
    log_success "Rollback complete. Existing environment ${ACTIVE_ENV^^} continues serving 100% of live traffic."
    exit 1
fi

# Step 5: Atomic Upstream Configuration Swap
log_step "Step 5: Atomically Updating Nginx Upstream Configuration"

cat <<EOF > "${UPSTREAM_CONF}.tmp"
# Dynamically managed upstream configuration
# Updated by deploy.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
upstream active_app {
    server ${TARGET_SERVICE}:${TARGET_PORT};
    keepalive 32;
}
EOF

mv "${UPSTREAM_CONF}.tmp" "${UPSTREAM_CONF}"
log_success "Nginx upstream pointed to: ${TARGET_SERVICE}:${TARGET_PORT}"

# Step 6: Test & Reload Nginx Configuration
log_step "Step 6: Validating Nginx Configuration & Triggering Graceful Reload"

log_info "Testing Nginx syntax..."
run_compose exec -T nginx nginx -t

log_info "Issuing zero-downtime reload signal (nginx -s reload)..."
run_compose exec -T nginx nginx -s reload
log_success "Nginx dynamically reloaded without dropping active worker connections."

# Step 7: Graceful Connection Draining
log_step "Step 7: Draining Active In-Flight Connections (${DRAIN_WAIT_SECONDS}s)"
log_info "Allowing ongoing HTTP requests on ${PREV_SERVICE} to finish gracefully..."
sleep "${DRAIN_WAIT_SECONDS}"

# Step 8: Decommission Previous Environment
log_step "Step 8: Decommissioning Previous Container [${PREV_SERVICE}]"
log_info "Stopping ${PREV_SERVICE}..."
run_compose stop "${PREV_SERVICE}"
log_success "Previous container ${PREV_SERVICE} successfully stopped."

# Step 9: Persist State
echo "${TARGET_ENV}" > "${STATE_FILE}"

# Deployment Summary
echo -e "\n${COLOR_GREEN}${COLOR_BOLD}================================================================="
echo "       ZERO-DOWNTIME DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "=================================================================${COLOR_RESET}"
echo -e "Previous Active Environment: ${ACTIVE_COLOR}${ACTIVE_ENV^^}${COLOR_RESET}"
echo -e "Current Live Environment:    ${TARGET_COLOR}${COLOR_BOLD}${TARGET_ENV^^}${COLOR_RESET}"
echo -e "Deployed Application Version: ${COLOR_BOLD}${TARGET_VERSION}${COLOR_RESET}"
echo -e "Public Service Gateway:      ${COLOR_CYAN}http://localhost:8080/${COLOR_RESET}"
echo -e "Health Diagnostic Endpoint:  ${COLOR_CYAN}http://localhost:8080/health${COLOR_RESET}"
echo "================================================================="
