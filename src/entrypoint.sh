#!/usr/bin/env bash
# =============================================================================
#  Rootstock Foundry Deployer — entrypoint.sh
#  The "brain" of the GitHub Action. Handles all Rootstock-specific nuances.
# =============================================================================
#
#  Rootstock specifics handled here:
#    1. Auto-detects Mainnet (30) vs Testnet (31) chain ID
#    2. Selects the correct Blockscout explorer API URL
#    3. Forces --legacy flag (required for Rootstock EIP-155 compatibility)
#    4. Pre-flight: balance check (fail-fast with human-readable error)
#    5. Pre-flight: gas price sanity check
#    6. Post-deploy: parses broadcast JSON with jq for reliable output extraction
#    7. Exports: contract_address, transaction_hash, chain_id, explorer_url
#
#  Security: We NEVER use `set -x` in this script to prevent private key
#  leakage into GitHub Action logs. GitHub masks secrets, but set -x can
#  bypass that masking.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  ANSI Color Helpers
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
#  Input Validation
# ─────────────────────────────────────────────────────────────────────────────
: "${INPUT_RPC_URL:?Variable INPUT_RPC_URL is required}"
: "${INPUT_PRIVATE_KEY:?Variable INPUT_PRIVATE_KEY is required}"
: "${INPUT_SCRIPT_PATH:?Variable INPUT_SCRIPT_PATH is required}"

GAS_MULTIPLIER="${INPUT_GAS_ESTIMATE_MULTIPLIER:-130}"
MIN_BALANCE="${INPUT_MIN_BALANCE:-10000000000000000}"
VERIFIER_TYPE="${INPUT_VERIFIER_TYPE:-blockscout}"
EXTRA_ARGS="${INPUT_EXTRA_ARGS:-}"
CONTRACT_NAME="${INPUT_CONTRACT_NAME:-}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Rootstock Foundry Deployer — GitHub Action    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  Verify Tools Exist
# ─────────────────────────────────────────────────────────────────────────────
info "Verifying toolchain..."
for tool in forge cast jq; do
    if ! command -v "$tool" &>/dev/null; then
        error "Required tool '$tool' is not installed in the Docker image."
        exit 1
    fi
done
success "Toolchain OK: forge $(forge --version | head -1), cast, jq"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 1 — Detect Chain ID
# ─────────────────────────────────────────────────────────────────────────────
info "Detecting network via cast chain-id..."
CHAIN_ID=$(cast chain-id --rpc-url "$INPUT_RPC_URL" 2>/dev/null) || {
    error "Failed to connect to RPC endpoint: $INPUT_RPC_URL"
    error "Please check the rpc_url input and ensure the network is reachable."
    exit 1
}

if [[ "$CHAIN_ID" == "30" ]]; then
    NETWORK_NAME="Rootstock Mainnet"
    EXPLORER_BASE="https://explorer.rootstock.io"
    EXPLORER_API="${EXPLORER_BASE}/api"
elif [[ "$CHAIN_ID" == "31" ]]; then
    NETWORK_NAME="Rootstock Testnet"
    EXPLORER_BASE="https://explorer.testnet.rootstock.io"
    EXPLORER_API="${EXPLORER_BASE}/api"
else
    error "Unsupported Chain ID: $CHAIN_ID"
    error "This action only supports Rootstock Mainnet (30) and Testnet (31)."
    error "If you intended to use a different network, please check your rpc_url."
    exit 1
fi

success "Network detected: ${NETWORK_NAME} (Chain ID: ${CHAIN_ID})"
info    "Explorer:        ${EXPLORER_BASE}"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 2 — Pre-Flight: Gas Price Check
# ─────────────────────────────────────────────────────────────────────────────
info "Checking current gas price..."
CURRENT_GAS_PRICE=$(cast gas-price --rpc-url "$INPUT_RPC_URL" 2>/dev/null) || {
    warn "Could not fetch gas price. Proceeding with caution..."
    CURRENT_GAS_PRICE=0
}

# Rootstock minimum gas price is typically 0.06 Gwei = 60000000 wei
MIN_GAS_PRICE=60000000

if [[ "$CURRENT_GAS_PRICE" -lt "$MIN_GAS_PRICE" ]] && [[ "$CURRENT_GAS_PRICE" -gt 0 ]]; then
    warn "Gas price (${CURRENT_GAS_PRICE} wei) is below the Rootstock minimum (${MIN_GAS_PRICE} wei)."
    warn "This may indicate an RPC sync issue. Proceeding anyway, but watch for failures."
else
    GGAS_GWEI=$(echo "scale=4; $CURRENT_GAS_PRICE / 1000000000" | bc -l 2>/dev/null || echo "unknown")
    success "Gas price: ${CURRENT_GAS_PRICE} wei (~${GGAS_GWEI} Gwei)"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3 — Pre-Flight: Deployer Balance Check
# ─────────────────────────────────────────────────────────────────────────────
info "Deriving deployer address..."
# Derive the deployer address from the private key without echoing the key
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$INPUT_PRIVATE_KEY" 2>/dev/null) || {
    error "Failed to derive deployer address from private_key."
    error "Ensure the private_key input is a valid hex private key (with or without 0x prefix)."
    exit 1
}
success "Deployer address: ${DEPLOYER_ADDRESS}"

info "Checking deployer RBTC balance..."
RAW_BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$INPUT_RPC_URL" 2>/dev/null) || {
    error "Failed to fetch balance for ${DEPLOYER_ADDRESS}."
    exit 1
}

success "Balance: ${RAW_BALANCE} wei"

# Numeric comparison using bash arithmetic (handles large integers safely with bc)
BALANCE_OK=$(echo "$RAW_BALANCE >= $MIN_BALANCE" | bc -l 2>/dev/null || echo "1")
if [[ "$BALANCE_OK" == "0" ]]; then
    RBTC_BALANCE=$(echo "scale=8; $RAW_BALANCE / 1000000000000000000" | bc -l 2>/dev/null || echo "unknown")
    RBTC_MIN=$(echo "scale=8; $MIN_BALANCE / 1000000000000000000" | bc -l 2>/dev/null || echo "unknown")
    error "╔══════════════════════════════════════════════════╗"
    error "║           INSUFFICIENT BALANCE — HALTED          ║"
    error "╠══════════════════════════════════════════════════╣"
    error "║  Deployer:  ${DEPLOYER_ADDRESS}"
    error "║  Balance:   ${RBTC_BALANCE} RBTC"
    error "║  Required:  ${RBTC_MIN} RBTC (configurable via min_balance)"
    error "║                                                  ║"
    error "║  Top up your account before retrying.            ║"
    error "║  Testnet faucet: https://faucet.rootstock.io     ║"
    error "╚══════════════════════════════════════════════════╝"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 4 — Execute Deployment
# ─────────────────────────────────────────────────────────────────────────────
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "🚀  Deploying to ${NETWORK_NAME}..."
info "    Script:              ${INPUT_SCRIPT_PATH}"
info "    Gas multiplier:      ${GAS_MULTIPLIER}%"
info "    Verifier:            ${VERIFIER_TYPE}"
info "    Transaction type:    Legacy (EIP-155 forced for Rootstock)"
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Build the forge command. Using an array avoids word-splitting issues.
FORGE_CMD=(
    forge script "$INPUT_SCRIPT_PATH"
    --rpc-url "$INPUT_RPC_URL"
    --private-key "$INPUT_PRIVATE_KEY"
    --broadcast
    --legacy
    --gas-estimate-multiplier "$GAS_MULTIPLIER"
    --verify
    --verifier "$VERIFIER_TYPE"
    --verifier-url "$EXPLORER_API"
)

# Append contract name if provided (targeted verification)
if [[ -n "$CONTRACT_NAME" ]]; then
    FORGE_CMD+=(--etherscan-api-key "none")  # Blockscout doesn't require a real key
fi

# Append any user-provided extra args
# shellcheck disable=SC2206
[[ -n "$EXTRA_ARGS" ]] && FORGE_CMD+=($EXTRA_ARGS)

# Execute (no set -x to protect the private key)
if ! "${FORGE_CMD[@]}"; then
    error "forge script failed. Review the output above for details."
    error "Common causes:"
    error "  - Insufficient RBTC for gas"
    error "  - Script compilation errors"
    error "  - RPC endpoint connectivity issues"
    exit 1
fi

success "Forge script completed successfully!"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 5 — Extract Outputs from Broadcast Log
# ─────────────────────────────────────────────────────────────────────────────
echo ""
info "Parsing deployment artifacts..."

# Derive the script name (filename without extension) for the broadcast path
# e.g. script/Deploy.s.sol -> Deploy.s
SCRIPT_BASENAME=$(basename "$INPUT_SCRIPT_PATH")
# Remove only the last extension component to keep .s.sol as script name
SCRIPT_NAME="${SCRIPT_BASENAME%.*}"

BROADCAST_JSON="broadcast/${SCRIPT_NAME}/${CHAIN_ID}/run-latest.json"

if [[ ! -f "$BROADCAST_JSON" ]]; then
    warn "Broadcast log not found at: $BROADCAST_JSON"
    warn "Deployment completed but contract_address output cannot be extracted."
    warn "Ensure your Foundry script uses vm.broadcast() or vm.startBroadcast()."
    # Don't fail — deployment itself succeeded
    exit 0
fi

success "Broadcast log found: $BROADCAST_JSON"

# Parse with jq — robust extraction regardless of how many contracts were deployed
CONTRACT_ADDRESS=$(jq -r '
  .transactions
  | map(select(.transactionType == "CREATE" or .transactionType == "CREATE2"))
  | first
  | .contractAddress // empty
' "$BROADCAST_JSON" 2>/dev/null) || CONTRACT_ADDRESS=""

TX_HASH=$(jq -r '
  .transactions
  | map(select(.transactionType == "CREATE" or .transactionType == "CREATE2"))
  | first
  | .hash // empty
' "$BROADCAST_JSON" 2>/dev/null) || TX_HASH=""

# Fallback: if no CREATE tx found, grab first transaction regardless of type
if [[ -z "$CONTRACT_ADDRESS" || "$CONTRACT_ADDRESS" == "null" ]]; then
    CONTRACT_ADDRESS=$(jq -r '.transactions[0].contractAddress // empty' "$BROADCAST_JSON" 2>/dev/null) || CONTRACT_ADDRESS=""
fi
if [[ -z "$TX_HASH" || "$TX_HASH" == "null" ]]; then
    TX_HASH=$(jq -r '.transactions[0].hash // empty' "$BROADCAST_JSON" 2>/dev/null) || TX_HASH=""
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 6 — Set GitHub Action Outputs
# ─────────────────────────────────────────────────────────────────────────────
EXPLORER_CONTRACT_URL=""
if [[ -n "$CONTRACT_ADDRESS" && "$CONTRACT_ADDRESS" != "null" ]]; then
    EXPLORER_CONTRACT_URL="${EXPLORER_BASE}/address/${CONTRACT_ADDRESS}"
fi

{
    echo "contract_address=${CONTRACT_ADDRESS}"
    echo "transaction_hash=${TX_HASH}"
    echo "chain_id=${CHAIN_ID}"
    echo "explorer_url=${EXPLORER_CONTRACT_URL}"
} >> "$GITHUB_OUTPUT"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 7 — Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          ✅  DEPLOYMENT SUCCESSFUL!               ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Network:   ${NETWORK_NAME} (Chain ID: ${CHAIN_ID})"
if [[ -n "$CONTRACT_ADDRESS" && "$CONTRACT_ADDRESS" != "null" ]]; then
    echo -e "${BOLD}${GREEN}║${NC}  Contract:  ${CONTRACT_ADDRESS}"
    echo -e "${BOLD}${GREEN}║${NC}  Explorer:  ${EXPLORER_CONTRACT_URL}"
fi
if [[ -n "$TX_HASH" && "$TX_HASH" != "null" ]]; then
    echo -e "${BOLD}${GREEN}║${NC}  Tx Hash:   ${TX_HASH}"
fi
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
