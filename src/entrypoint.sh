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
MIN_BALANCE="${INPUT_MIN_BALANCE:-100000000000000}"
VERIFIER_TYPE="${INPUT_VERIFIER_TYPE:-blockscout}"
EXTRA_ARGS="${INPUT_EXTRA_ARGS:-}"
CONTRACT_NAME="${INPUT_CONTRACT_NAME:-}"

# Basic Input Validation
if [[ ! "$INPUT_RPC_URL" =~ ^https?:// ]]; then
    error "rpc_url must start with http:// or https://"
    exit 1
fi
if ! [[ "$GAS_MULTIPLIER" =~ ^[0-9]+$ ]]; then
    error "gas_estimate_multiplier must be numeric"
    exit 1
fi
if ! [[ "$MIN_BALANCE" =~ ^[0-9]+$ ]]; then
    error "min_balance must be numeric"
    exit 1
fi
if [[ ! "$VERIFIER_TYPE" =~ ^(blockscout|etherscan)$ ]]; then
    error "verifier_type must be 'blockscout' or 'etherscan'"
    exit 1
fi

# Reject flag injection in extra_args 
if [[ "$EXTRA_ARGS" == *"--private-key"* ]] || [[ "$EXTRA_ARGS" == *"--rpc-url"* ]] || [[ "$EXTRA_ARGS" == *"--legacy"* ]]; then
    error "extra_args contains forbidden flags (--private-key, --rpc-url, or --legacy). These are managed by the action."
    exit 1
fi

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

RETRIES=3
DELAY=2
CHAIN_ID=""
for ((i=1; i<=RETRIES; i++)); do
    if CHAIN_ID=$(cast chain-id --rpc-url "$INPUT_RPC_URL" 2>/dev/null); then
        break
    fi
    warn "Failed to fetch chain ID. Retrying in $DELAY seconds... ($i/$RETRIES)"
    sleep "$DELAY"
done

if [[ -z "$CHAIN_ID" ]]; then
    error "Failed to connect to RPC endpoint after $RETRIES attempts: $INPUT_RPC_URL"
    error "Please check the rpc_url input and ensure the network is reachable."
    exit 1
fi

if [[ "$CHAIN_ID" == "30" ]]; then
    NETWORK_NAME="Rootstock Mainnet"
    EXPLORER_BASE="https://explorer.rootstock.io"
    EXPLORER_API="https://rootstock.blockscout.com/api"
elif [[ "$CHAIN_ID" == "31" ]]; then
    NETWORK_NAME="Rootstock Testnet"
    EXPLORER_BASE="https://explorer.testnet.rootstock.io"
    EXPLORER_API="https://rootstock-testnet.blockscout.com/api"
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
CURRENT_GAS_PRICE=0
for ((i=1; i<=RETRIES; i++)); do
    if CURRENT_GAS_PRICE=$(cast gas-price --rpc-url "$INPUT_RPC_URL" 2>/dev/null); then
        break
    fi
    warn "Failed to fetch gas price. Retrying in $DELAY seconds... ($i/$RETRIES)"
    sleep "$DELAY"
done

if [[ "$CURRENT_GAS_PRICE" == "0" || -z "$CURRENT_GAS_PRICE" ]]; then
    warn "Could not fetch gas price after $RETRIES attempts. Proceeding with caution..."
    CURRENT_GAS_PRICE=0
fi

# Rootstock minimum gas price is typically 0.06 Gwei = 60000000 wei
MIN_GAS_PRICE=60000000

if [[ "$CURRENT_GAS_PRICE" -lt "$MIN_GAS_PRICE" ]] && [[ "$CURRENT_GAS_PRICE" -gt 0 ]]; then
    warn "Gas price (${CURRENT_GAS_PRICE} wei) is below the Rootstock minimum (${MIN_GAS_PRICE} wei)."
    warn "This may indicate an RPC sync issue. Proceeding anyway, but watch for failures."
else
    GAS_GWEI=$(echo "scale=4; $CURRENT_GAS_PRICE / 1000000000" | bc -l 2>/dev/null || echo "unknown")
    success "Gas price: ${CURRENT_GAS_PRICE} wei (~${GAS_GWEI} Gwei)"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3 — Pre-Flight: Deployer Balance Check
# ─────────────────────────────────────────────────────────────────────────────
info "Deriving deployer address..."
# Derive the deployer address from the private key securely via stdin/args
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$INPUT_PRIVATE_KEY" 2>/dev/null) || {
    error "Failed to derive deployer address from private_key."
    error "Ensure the private_key input is a valid hex private key (with or without 0x prefix)."
    exit 1
}
success "Deployer address: ${DEPLOYER_ADDRESS}"

info "Checking deployer RBTC balance..."
RAW_BALANCE=""
for ((i=1; i<=RETRIES; i++)); do
    if RAW_BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$INPUT_RPC_URL" 2>/dev/null); then
        break
    fi
    warn "Failed to fetch balance. Retrying in $DELAY seconds... ($i/$RETRIES)"
    sleep "$DELAY"
done

if [[ -z "$RAW_BALANCE" ]]; then
    error "Failed to fetch balance for ${DEPLOYER_ADDRESS} after $RETRIES attempts."
    exit 1
fi

success "Balance: ${RAW_BALANCE} wei"

# Numeric comparison using bash arithmetic (handles large integers safely with bc)
BALANCE_OK=$(echo "$RAW_BALANCE >= $MIN_BALANCE" | bc -l 2>/dev/null)
if [[ -z "$BALANCE_OK" ]]; then
    # if `bc` evaluates unexpectedly due to shell env, assume failure by fallback but with warning
    warn "Math evaluation failed, enforcing balance check failure to be safe."
    BALANCE_OK=0
fi

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
    --broadcast
    --private-key "$INPUT_PRIVATE_KEY"
    --legacy
    --gas-estimate-multiplier "$GAS_MULTIPLIER"
    --verify
    --verifier "$VERIFIER_TYPE"
    --verifier-url "$EXPLORER_API"
)

# Append contract name if provided (targeted verification)
if [[ -n "$CONTRACT_NAME" ]]; then
    FORGE_CMD+=(--target-contract "$CONTRACT_NAME")
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

# Derive the script filename for the broadcast path.
# Foundry uses the FULL filename (including .s.sol) as the broadcast directory.
# e.g. script/Deploy.s.sol -> broadcast/Deploy.s.sol/31/run-latest.json
SCRIPT_BASENAME=$(basename "$INPUT_SCRIPT_PATH")

BROADCAST_JSON="broadcast/${SCRIPT_BASENAME}/${CHAIN_ID}/run-latest.json"

if [[ ! -f "$BROADCAST_JSON" ]]; then
    error "Broadcast log not found at: $BROADCAST_JSON"
    error "Deployment may have failed, or no broadcast log was generated."
    error "Ensure your Foundry script uses vm.broadcast() or vm.startBroadcast()."
    exit 1
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

# Write to GitHub Step Summary
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "### 🚀 Deployment Successful" >> "$GITHUB_STEP_SUMMARY"
    echo "- **Network:** ${NETWORK_NAME} (Chain ID: ${CHAIN_ID})" >> "$GITHUB_STEP_SUMMARY"
    if [[ -n "$CONTRACT_ADDRESS" && "$CONTRACT_ADDRESS" != "null" ]]; then
        echo "- **Contract Address:** \`${CONTRACT_ADDRESS}\`" >> "$GITHUB_STEP_SUMMARY"
        echo "- **Explorer URL:** [View on Blockscout](${EXPLORER_CONTRACT_URL})" >> "$GITHUB_STEP_SUMMARY"
    fi
    if [[ -n "$TX_HASH" && "$TX_HASH" != "null" ]]; then
        echo "- **Transaction Hash:** \`${TX_HASH}\`" >> "$GITHUB_STEP_SUMMARY"
    fi
fi

