# ============================================================
#  Rootstock Foundry Deployer Action — Docker Image
#  Base: Official Foundry image (Forge + Cast + jq pre-installed)
# ============================================================
FROM ghcr.io/foundry-rs/foundry:latest

LABEL org.opencontainers.image.title="Rootstock Foundry Deployer"
LABEL org.opencontainers.image.description="GitHub Action for deploying Foundry smart contracts to Rootstock (Mainnet/Testnet)"
LABEL org.opencontainers.image.source="https://github.com/rsksmart/rootstock-foundry-action"
LABEL org.opencontainers.image.licenses="MIT"

# Install jq for broadcast JSON parsing (used to extract deployed address)
USER root
RUN apt-get update && apt-get install -y jq bash curl && rm -rf /var/lib/apt/lists/*

# Copy entrypoint script and make it executable
COPY src/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
