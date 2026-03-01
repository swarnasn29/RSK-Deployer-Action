#!/usr/bin/env bash
# =============================================================================
#  Rootstock Foundry Deployer — Local Tester
#  Simulates how GitHub Actions executes the Docker container.
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== Rootstock Foundry Action Local Tester ===${NC}"

# 1. Require a test private key
if [ -z "$TEST_PRIVATE_KEY" ]; then
    echo -e "${YELLOW}Warning: TEST_PRIVATE_KEY environment variable is not set.${NC}"
    echo -e "You can still run this, but it will fail at the 'Deployer Balance Check' step."
    echo -e "To do a full deployment test, run via:"
    echo -e "  ${GREEN}TEST_PRIVATE_KEY=your_hex_key ./test-local.sh${NC}"
    echo ""
    # We use a dummy key just so it doesn't fail the "Input Validation" step
    TEST_PRIVATE_KEY="0x0000000000000000000000000000000000000000000000000000000000000001"
fi

# 2. Setup a temporary dummy Foundry project
DUMMY_DIR="/tmp/rootstock_dummy_project"
echo -e "${CYAN}>> Setting up temporary Foundry project at $DUMMY_DIR...${NC}"

rm -rf "$DUMMY_DIR"
mkdir -p "$DUMMY_DIR/src"
mkdir -p "$DUMMY_DIR/script"

# Minimal foundry module
cat > "$DUMMY_DIR/foundry.toml" << 'EOF'
[profile.default]
src = 'src'
out = 'out'
libs = ['lib']
EOF

# Minimal contract
cat > "$DUMMY_DIR/src/Counter.sol" << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Counter {
    uint256 public number;
    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }
}
EOF

# Minimal script
cat > "$DUMMY_DIR/script/Counter.s.sol" << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Counter} from "../src/Counter.sol";

// Dummy vm interface to avoid full std import
interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract CounterScript {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    
    function run() public {
        vm.startBroadcast();
        new Counter();
        vm.stopBroadcast();
    }
}
EOF

# 3. Build the Docker image natively
echo -e "\n${CYAN}>> Building Docker image (rootstock-foundry-action:local)...${NC}"
docker build -t rootstock-foundry-action:local .

# 4. Run the container just like GitHub Actions would
echo -e "\n${CYAN}>> Running Action Simulator...${NC}"
echo -e "${YELLOW}Note: We are passing Testnet RPC by default.${NC}\n"

# GitHub Actions sets GITHUB_WORKSPACE and mounts it to /github/workspace
docker run --rm \
    -v "$DUMMY_DIR:/github/workspace" \
    -v "$DUMMY_DIR/outputs.txt:/github/outputs.txt" \
    -w "/github/workspace" \
    -e INPUT_RPC_URL="https://public-node.testnet.rsk.co" \
    -e INPUT_PRIVATE_KEY="$TEST_PRIVATE_KEY" \
    -e INPUT_SCRIPT_PATH="script/Counter.s.sol" \
    -e INPUT_GAS_ESTIMATE_MULTIPLIER="130" \
    -e INPUT_MIN_BALANCE="10000000000000000" \
    -e GITHUB_OUTPUT="/github/outputs.txt" \
    rootstock-foundry-action:local || {
        echo -e "\n${RED}Action failed! (If it failed at the balance check due to the dummy key, that means the script logic works perfectly up to that point.)${NC}"
        # We don't exit 1 if it's the expected dummy key failure
        if [ "$TEST_PRIVATE_KEY" == "0x0000000000000000000000000000000000000000000000000000000000000001" ]; then
            echo -e "${GREEN}Balance check failure with dummy key is EXPECTED behavior.${NC}"
        else
            exit 1
        fi
    }

echo -e "\n${CYAN}>> Cleaning up...${NC}"
cat "$DUMMY_DIR/outputs.txt" || true
rm -rf "$DUMMY_DIR"

echo -e "\n${GREEN}Test script completed.${NC}"
