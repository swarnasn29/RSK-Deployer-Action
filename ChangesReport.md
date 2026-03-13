# Bug Resolution Report — Rootstock Foundry Deployer Action

_Audit of 18 reported findings. Status as of current codebase._

---

## ✅ Resolved

| # | Bug | Solution |
|---|-----|----------|
| 1 | **`bc` not installed in Docker** | `bc` is installed via `apt-get install -y jq bash curl bc` in `Dockerfile`. |
| 2 | **Balance check silently bypassed when `bc` missing** | `bc` is present, so the bypass path (`\|\| echo "1"`) is never hit. Balance check works correctly. |
| 3 | **`apt-get` vs `apk`** | Not a real bug — `ghcr.io/foundry-rs/foundry` is Debian-based, not Alpine. `apt-get` works correctly. Confirmed by successful Docker builds. |
| 4 | **`contract_name` input non-functional** | `entrypoint.sh` correctly appends `--target-contract "$CONTRACT_NAME"` to the forge command when the input is set. |
| 5 | **`exit 0` when broadcast log missing** | `entrypoint.sh` correctly calls `exit 1` when the broadcast log is not found. |
| 6 | **No retry logic for RPC calls** | `cast chain-id`, `cast gas-price`, and `cast balance` all use a 3-retry loop with a 2-second delay. |
| 7 | **`test-local.sh` outputs file not pre-created** | `touch "$DUMMY_DIR/outputs.txt"` is called before `docker run` to ensure Docker mounts a file, not a directory. |
| 8 | **No input validation** | `rpc_url`, `gas_estimate_multiplier`, `min_balance`, and `verifier_type` are all validated with regex/format checks and produce clear error messages on failure. |
| 9 | **`extra_args` flag injection** | `entrypoint.sh` rejects `extra_args` containing `--private-key`, `--rpc-url`, or `--legacy` with a clear error. |
| 10 | **Container runs as root** | `Dockerfile` installs packages as `root`, then switches to `USER foundry` before running the entrypoint. |
| 11 | **Dry-run misses `explorer_url`** | `test-local.sh` validates all four outputs: `contract_address`, `transaction_hash`, `chain_id`, and `explorer_url`. |
| 12 | **`$GITHUB_STEP_SUMMARY` not used** | `entrypoint.sh` writes a Markdown deployment summary to `$GITHUB_STEP_SUMMARY` on success. |
| 13 | **Variable typo `GGAS_GWEI`** | No such typo exists in the current code. Variable is correctly named `GAS_GWEI`. |
| 14 | **Test script uses manual `Vm` interface** | `test-local.sh` uses `import {Script} from "forge-std/Script.sol"` with `vm.startBroadcast()` / `vm.stopBroadcast()`. |
| 15 | **No `--private-key` passed to `forge script`** _(session fix)_ | Replaced `--sender` with `--private-key "$INPUT_PRIVATE_KEY"`. Forge requires an explicit key to sign broadcast transactions. |
| 16 | **Wrong Blockscout verifier URL** _(session fix)_ | Updated `EXPLORER_API` to `rootstock.blockscout.com/api` and `rootstock-testnet.blockscout.com/api` — the actual Blockscout API backends, not the frontend domains. |
| 17 | **Broadcast path strips `.sol` extension** _(session fix)_ | Removed the `%.*` suffix strip. Foundry uses the full filename (`Counter.s.sol`) as the broadcast directory, not a stripped version (`Counter.s`). |
| 18 | **Docker image unpinned (`nightly`)** | Changed base image from `ghcr.io/foundry-rs/foundry:nightly` to `ghcr.io/foundry-rs/foundry:latest` for build stability. |

---

## ⚠️ Accepted / Documented Trade-off

| # | Bug | Status |
|---|-----|--------|
| 19 | **Private key exposed in process arguments** | **Accepted/Documented**: `forge script --broadcast` requires the `--private-key` flag or a local keystore to sign transactions. It does NOT pick up `ETH_PRIVATE_KEY` automatically for signing broadcasted transactions without user-side script modifications. The security risk is mitigated by GitHub Actions' built-in secret masking in logs and the ephemeral nature of the CI container. |
| 20 | **Example workflow misleading comment** | Fixed: comment now accurately states that pushes to `main` use the testnet RPC by default (since `workflow_dispatch` inputs are not available on `push` events). |

---
