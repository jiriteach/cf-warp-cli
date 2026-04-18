FROM ubuntu:22.04

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    lsb-release \
    ca-certificates \
    procps \
    iproute2 \
    iputils-ping \
    iptables \
    dbus \
    && rm -rf /var/lib/apt/lists/* \
    # Switch to iptables-legacy backend.
    # Ubuntu 22.04 defaults to iptables-nft which requires nftables kernel
    # modules that are often unavailable inside containers, causing silent
    # failures. The legacy backend uses the standard ip_tables module which
    # is reliably available with NET_ADMIN + NET_RAW capabilities.
    && update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Install Cloudflare WARP
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && apt-get install -y cloudflare-warp && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# WARP stores its state here — mount a volume to persist registration across restarts
VOLUME ["/var/lib/cloudflare-warp"]

ENTRYPOINT ["/entrypoint.sh"]
