<div align="center">

# Rootstock Foundry Deployer Action

**The zero-friction GitHub Action for deploying Foundry smart contracts to Rootstock.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Rootstock](https://img.shields.io/badge/Rootstock-Mainnet%20%7C%20Testnet-orange)](https://rootstock.io)

> Stop fighting `--legacy` transaction errors and hunting for Blockscout API endpoints.  
> This action handles all of that for you.

</div>

---

## Quickstart

Copy this into your project's `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Rootstock

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Deploy
        id: deploy
        uses: rsksmart/rootstock-foundry-action@v1
        with:
          rpc_url:     'https://public-node.testnet.rsk.co'
          private_key: ${{ secrets.DEPLOYER_PRIVATE_KEY }}
          script_path: 'script/Deploy.s.sol'

      - name: Show result
        run: echo "Contract at ${{ steps.deploy.outputs.contract_address }}"
```

Add your `DEPLOYER_PRIVATE_KEY` to **Settings → Secrets and variables → Actions** and you're done.

---

## What This Action Solves

Rootstock is EVM-compatible but has specific requirements that break standard Foundry CI setups:

| Pain Point | What This Action Does |
|---|---|
| Transactions fail with "invalid transaction type" | Automatically injects `--legacy` flag |
| Verification fails — wrong API URL for Blockscout | Auto-selects the correct Blockscout API per chain |
| Cryptic RPC errors when wallet has no RBTC | Pre-flight balance check with a clear, human-readable error |
| "Out of gas" failures in CI | Default `--gas-estimate-multiplier 130` (30% buffer) |
| No way to use the deployed address in next steps | Exports `contract_address` as a GitHub Actions output |

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `rpc_url` | ✅ | — | Rootstock RPC URL (Mainnet or Testnet) |
| `private_key` | ✅ | — | Deployer private key — always use `${{ secrets.* }}` |
| `script_path` | ✅ | — | Path to Foundry deploy script, e.g. `script/Deploy.s.sol` |
| `contract_name` | ❌ | `''` | Primary contract name for targeted Blockscout verification |
| `verifier_type` | ❌ | `blockscout` | Verification provider (`blockscout` or `etherscan`) |
| `gas_estimate_multiplier` | ❌ | `130` | Gas estimate buffer percentage (130 = 30% over estimate) |
| `min_balance` | ❌ | `10000000000000000` | Minimum deployer balance in wei required before deploy (0.01 RBTC) |
| `extra_args` | ❌ | `''` | Additional flags passed directly to `forge script` |

## Outputs

| Output | Description |
|---|---|
| `contract_address` | Address of the deployed contract (from broadcast log) |
| `transaction_hash` | Deployment transaction hash |
| `chain_id` | Chain ID used: `30` (Mainnet) or `31` (Testnet) |
| `explorer_url` | Direct link to the contract on Rootstock Explorer |

---

## Network Reference

| Network | Chain ID | RPC URL | Explorer |
|---|---|---|---|
| **Mainnet** | 30 | `https://public-node.rsk.co` | [explorer.rootstock.io](https://explorer.rootstock.io) |
| **Testnet** | 31 | `https://public-node.testnet.rsk.co` | [explorer.testnet.rootstock.io](https://explorer.testnet.rootstock.io) |

The action **auto-detects** the network from the `rpc_url` — you don't need to specify the chain ID manually.

>  **Need Testnet RBTC?** Use the [Rootstock Faucet](https://faucet.rootstock.io).

---

##  Security Best Practices

**Never hardcode your private key.** Always use GitHub Secrets:

```yaml
private_key: ${{ secrets.DEPLOYER_PRIVATE_KEY }}
```

For added protection on Mainnet deployments, use [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) with required reviewers:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production   # Requires manual approval in GitHub UI
```

> ⚠️ This action never echoes your private key. We explicitly avoid `set -x` in our shell scripts to prevent secret exposure in logs.

---

## 🔗 Using the Contract Address in Downstream Steps

```yaml
- name: Deploy
  id: deploy
  uses: rsksmart/rootstock-foundry-action@v1
  with:
    rpc_url:     'https://public-node.testnet.rsk.co'
    private_key: ${{ secrets.DEPLOYER_PRIVATE_KEY }}
    script_path: 'script/Deploy.s.sol'

# Use the output in any subsequent step
- name: Update frontend
  run: echo "NEXT_PUBLIC_CONTRACT=${{ steps.deploy.outputs.contract_address }}" >> .env

- name: Open Explorer
  run: echo "View at ${{ steps.deploy.outputs.explorer_url }}"
```

---

## ⚙️ Advanced Usage

### Deploy to Mainnet with all options

```yaml
- uses: rsksmart/rootstock-foundry-action@v1
  with:
    rpc_url:                 'https://public-node.rsk.co'
    private_key:             ${{ secrets.MAINNET_PRIVATE_KEY }}
    script_path:             'script/Deploy.s.sol'
    contract_name:           'MyToken'
    gas_estimate_multiplier: '150'        # 50% buffer for congested networks
    min_balance:             '50000000000000000'  # Require 0.05 RBTC minimum
    extra_args:              '--slow'     # Space out transactions for reliability
```

### Use a custom RPC (Alchemy, QuickNode, etc.)

```yaml
rpc_url: ${{ secrets.ROOTSTOCK_RPC_URL }}
```

---

## 🔧 How It Works

The action runs in a **Docker container** based on the official Foundry image, meaning your runner's environment never matters — the Foundry version is pinned and consistent.

**Execution flow:**

```
1. Detect chain ID from RPC URL  →  Select Blockscout API endpoint
2. Pre-flight: Gas price check   →  Warn if below Rootstock minimum
3. Pre-flight: Balance check     →  Fail fast with a clear error if too low
4. forge script                  →  Always with --legacy + --verify (Blockscout)
5. Parse broadcast/<script>/<chainId>/run-latest.json with jq
6. Export outputs to $GITHUB_OUTPUT
```

---

## 🛠 Troubleshooting

### Error: "Unsupported Chain ID"
Your `rpc_url` is not pointing to Rootstock. Check the network reference table above.

### Error: "INSUFFICIENT BALANCE"
Your deployer wallet doesn't have enough RBTC. Top up via the [Rootstock Faucet](https://faucet.rootstock.io) (Testnet) or purchase RBTC (Mainnet). Override the threshold with `min_balance`.

### Error: "Broadcast log not found"
Your Foundry deploy script isn't calling `vm.broadcast()`. Ensure your script uses:
```solidity
function run() external {
    vm.startBroadcast();
    new MyContract();
    vm.stopBroadcast();
}
```

### Verification fails
- Ensure `contract_name` matches the exact Solidity contract name
- On Testnet, verification may take a few minutes — Blockscout indexes asynchronously
- **Fix:** Try adding `--delay 30 --retries 5` to `extra_args` to give Blockscout time to index before verifying:
  ```yaml
  extra_args: '--delay 30 --retries 5'
  ```

---

## 📄 License

MIT © [Rootstock (RSK)](https://rootstock.io)
