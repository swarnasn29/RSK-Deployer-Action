# ============================================================
#  Rootstock Foundry Deployer Action — Docker Image
#  Base: Official Foundry image (Forge + Cast + jq pre-installed)
# ============================================================
FROM ghcr.io/foundry-rs/foundry:latest
LABEL org.opencontainers.image.title="Rootstock Foundry Deployer"
LABEL org.opencontainers.image.description="GitHub Action for deploying Foundry smart contracts to Rootstock (Mainnet/Testnet)"
LABEL org.opencontainers.image.source="https://github.com/rsksmart/rootstock-foundry-action"
LABEL org.opencontainers.image.licenses="MIT"

# Install dependencies (jq for JSON parsing, bc for math, bash for script, curl for RPC tests)
USER root
RUN apt-get update && apt-get install -y jq bash curl bc && rm -rf /var/lib/apt/lists/*

# User foundry already exists in the base image

# Copy entrypoint script and make it executable
COPY src/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch to the non-privileged user
USER foundry

ENTRYPOINT ["/entrypoint.sh"]
