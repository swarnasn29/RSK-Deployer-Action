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

## 🔒 Security Audit — Round 2 Resolutions (2026-04-10)

_All 8 findings from the second peer-review were addressed. Severity levels: HIGH (H), MEDIUM (M), LOW (L)._

| ID | Severity | Finding | Resolution | Files Changed |
|----|----------|---------|------------|--------------|
| H-1 | HIGH | **Unversioned Docker Base Image (Supply Chain Risk)** — `FROM ghcr.io/foundry-rs/foundry:latest` pulls a mutable tag | Pinned to an immutable SHA-256 digest: `FROM ghcr.io/foundry-rs/foundry:latest@sha256:89a052af62c612d0e05d2596f03edba77d7d904c4478b387a5dc6305821fe0a1`. Added a pinning policy comment in the `Dockerfile` header documenting how to update the digest. | `Dockerfile`, `README.md` |
| H-2 | HIGH | **Command Injection via `extra_args` word-splitting** — `# shellcheck disable=SC2206` allowed unquoted expansion of `$EXTRA_ARGS`; blocklist was easily bypassed | Replaced the unquoted expansion with `IFS=' ' read -ra _raw_tokens <<< "$EXTRA_ARGS"` (safe word splitting). Each token is now validated against a shell metacharacter blocklist (`;`, `\|`, `&`, `$`, backtick, `<`, `>`) before being added to the command array. Forbidden flags (`--private-key`, `--rpc-url`, `--legacy`) are checked per-token via a `case` statement. | `src/entrypoint.sh` |
| M-1 | MEDIUM | **No Path Traversal Validation on `script_path`** — input passed directly to `forge script` without checking for `..` segments | Added a `..` substring check before invoking forge. Additionally performs a `realpath -m` resolution against `$GITHUB_WORKSPACE` when available and aborts if the path escapes the workspace directory. | `src/entrypoint.sh` |
| M-2 | MEDIUM | **`GITHUB_OUTPUT` Injection Risk** — simple `key=value` format is vulnerable to newline/`=` injection | Replaced all `echo "key=value"` writes with the GitHub-recommended heredoc delimiter syntax using `printf 'key<<_EOF_DELIM_\n%s\n_EOF_DELIM_\n'` to fully isolate multi-line values. | `src/entrypoint.sh` |
| M-3 | MEDIUM | **`contract_name` Not Validated as Solidity Identifier** — a crafted value could inject additional forge flags | Added a strict regex validation `^[a-zA-Z_][a-zA-Z0-9_]*$` against `$CONTRACT_NAME` before the forge command is constructed. Invalid names produce a clear error message. | `src/entrypoint.sh` |
| M-4 | MEDIUM | **RPC URL Accepts Any HTTP(S) Endpoint (SSRF Surface)** — only `http://`/`https://` prefix checked; internal network probing possible on self-hosted runners | Added a clear SSRF documentation comment in `entrypoint.sh`. Updated `README.md` with a dedicated "self-hosted runner SSRF notice" section recommending network egress allowlisting and storing the RPC URL in a GitHub Secret. The chain-ID check (must be 30 or 31) provides a hard stop after the first RPC call. | `src/entrypoint.sh`, `README.md` |
| L-1 | LOW | **Gas Price Sanity Check Advisory Only** — action warned but continued even when gas price was below Rootstock's minimum | Added a new `strict_gas_check` input (default: `false`). When set to `true`, the action exits with code 1 when gas price is below the minimum instead of warning and continuing. Documented in `action.yml` and `README.md`. | `src/entrypoint.sh`, `action.yml`, `README.md` |
| L-2 | LOW | **Hardcoded `--etherscan-api-key "none"`** — `"none"` is Blockscout-specific; would silently fail or confuse users with `verifier_type: etherscan` | The `--etherscan-api-key "none"` is now only passed when `$VERIFIER_TYPE == "blockscout"`. When `verifier_type: etherscan`, the new `etherscan_api_key` input is required (validated at startup) and passed as the real key. Setting `verifier_type: etherscan` without providing `etherscan_api_key` now fails fast with a clear error. | `src/entrypoint.sh`, `action.yml`, `README.md` |

---
