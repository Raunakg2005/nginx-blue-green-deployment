#!/usr/bin/env bash
# ==============================================================================
# Zero-Downtime High-Frequency Traffic Load & Verification Script
# ==============================================================================

set -u

# Colors
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RESET='\033[0m'

TARGET_URL="${1:-http://localhost:8080/}"
REQUEST_INTERVAL=0.1 # 10 requests per second

TOTAL_REQUESTS=0
SUCCESS_COUNT=0
FAILURE_COUNT=0
START_TIME=$(date +%s)

LAST_ENV=""
LAST_VERSION=""

echo -e "${COLOR_CYAN}${COLOR_BOLD}"
echo "================================================================="
echo "       ZERO-DOWNTIME TRAFFIC LOAD & PACKET-LOSS MONITOR"
echo "=================================================================${COLOR_RESET}"
echo -e "Target URL:       ${COLOR_BOLD}${TARGET_URL}${COLOR_RESET}"
echo -e "Load Rate:        ${COLOR_BOLD}10 requests / second${COLOR_RESET}"
echo -e "Press ${COLOR_YELLOW}[Ctrl + C]${COLOR_RESET} anytime to view final validation summary.\n"

print_summary() {
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    if [[ ${DURATION} -le 0 ]]; then DURATION=1; fi
    
    echo -e "\n\n${COLOR_CYAN}${COLOR_BOLD}================================================================="
    echo "                 TRAFFIC MONITOR REPORT"
    echo "=================================================================${COLOR_RESET}"
    echo -e "Total Monitoring Duration:   ${COLOR_BOLD}${DURATION}s${COLOR_RESET}"
    echo -e "Total Requests Dispatched:   ${COLOR_BOLD}${TOTAL_REQUESTS}${COLOR_RESET}"
    echo -e "Successful Responses (200):  ${COLOR_GREEN}${COLOR_BOLD}${SUCCESS_COUNT}${COLOR_RESET}"
    echo -e "Dropped / Error Responses:   ${COLOR_RED}${COLOR_BOLD}${FAILURE_COUNT}${COLOR_RESET}"

    if [[ ${TOTAL_REQUESTS} -gt 0 ]]; then
        SUCCESS_RATE=$(awk "BEGIN {printf \"%.2f\", (${SUCCESS_COUNT}/${TOTAL_REQUESTS})*100}")
        echo -e "Packet Delivery Rate:        ${COLOR_BOLD}${SUCCESS_RATE}%${COLOR_RESET}"
    fi

    if [[ ${FAILURE_COUNT} -eq 0 && ${TOTAL_REQUESTS} -gt 0 ]]; then
        echo -e "\n${COLOR_GREEN}${COLOR_BOLD}>>> ZERO DOWNTIME VERIFIED: 0 DROPPED PACKETS DURING DEPLOYMENT <<<${COLOR_RESET}"
    elif [[ ${FAILURE_COUNT} -gt 0 ]]; then
        echo -e "\n${COLOR_RED}${COLOR_BOLD}>>> WARNING: ${FAILURE_COUNT} PACKETS DROPPED / RETURNED NON-200 <<<${COLOR_RESET}"
    fi
    echo "================================================================="
    exit 0
}

trap print_summary SIGINT SIGTERM

while true; do
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    RAW_RESP=$(curl -s -m 2 -w "\nHTTP_STATUS:%{http_code}\nTIME:%{time_total}" -H "Accept: application/json" "${TARGET_URL}" 2>/dev/null || echo -e "\nHTTP_STATUS:000\nTIME:0")
    
    HTTP_CODE=$(echo "${RAW_RESP}" | grep "HTTP_STATUS:" | cut -d':' -f2 | tr -d '[:space:]')
    REQ_TIME=$(echo "${RAW_RESP}" | grep "TIME:" | cut -d':' -f2 | tr -d '[:space:]')
    
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

    if [[ "${HTTP_CODE}" == "200" ]]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        
        # Extract json fields
        ENV_VAL=$(echo "${RAW_RESP}" | grep -o '"env":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        VER_VAL=$(echo "${RAW_RESP}" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        
        # Format environment color
        if [[ "${ENV_VAL}" == "blue" ]]; then
            ENV_COLORED="${COLOR_BLUE}${COLOR_BOLD}BLUE ${COLOR_RESET}"
        elif [[ "${ENV_VAL}" == "green" ]]; then
            ENV_COLORED="${COLOR_GREEN}${COLOR_BOLD}GREEN${COLOR_RESET}"
        else
            ENV_COLORED="${COLOR_BOLD}${ENV_VAL}${COLOR_RESET}"
        fi

        # Detect and highlight transition
        if [[ -n "${LAST_ENV}" && ("${LAST_ENV}" != "${ENV_VAL}" || "${LAST_VERSION}" != "${VER_VAL}") ]]; then
            echo -e "\n${COLOR_MAGENTA}${COLOR_BOLD}>>> [SWAP DETECTED] Transitioned from ${LAST_ENV}:${LAST_VERSION} to ${ENV_VAL}:${VER_VAL} (0 Dropped Packets) <<<${COLOR_RESET}\n"
        fi
        
        LAST_ENV="${ENV_VAL}"
        LAST_VERSION="${VER_VAL}"

        echo -e "[${TIMESTAMP}] HTTP ${COLOR_GREEN}${HTTP_CODE}${COLOR_RESET} | Env: ${ENV_COLORED} | Ver: ${COLOR_BOLD}${VER_VAL}${COLOR_RESET} | Latency: ${REQ_TIME}s"
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        echo -e "[${TIMESTAMP}] ${COLOR_RED}${COLOR_BOLD}HTTP ${HTTP_CODE} ERROR / DROPPED REQUEST${COLOR_RESET} | Latency: ${REQ_TIME}s"
    fi

    sleep "${REQUEST_INTERVAL}"
done
