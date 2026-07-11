#!/bin/bash
# Host firewall for the venue appliance (NEH-68 Part B).
#
# On an untrusted venue LAN the appliance must expose exactly one thing: the
# nginx UI on port 80. Docker-published ports bypass ufw (Docker inserts its
# own iptables chains ahead of ufw's), so the containers are handled by
# loopback port binds in docker-compose.yml instead. This firewall's real job
# is the HOST processes — above all the native backend on 0.0.0.0:8000, which
# nginx and the frontend SSR must reach over the Docker bridge
# (host.docker.internal → host-gateway) but the venue LAN must not.
#
# Rules (all added BEFORE enabling, so an active SSH session survives):
#   - allow in on lo and tailscale0 (remote support path)
#   - allow 22/tcp (SSH) and 80/tcp (harmless next to Docker's own bypass,
#     and future-proofs a host-network nginx)
#   - allow 5353/udp (mDNS — without it digitool.local stops resolving)
#   - allow 8000/tcp from 172.16.0.0/12 only (Docker bridge → native backend;
#     never widen this to 192.168.0.0/16 — that is typically the venue LAN)
#   - default deny incoming, allow outgoing
#
# DHCP keeps working under deny-incoming: the client uses AF_PACKET sockets
# for the initial exchange and renewals are conntrack-established.
#
# Idempotent — ufw skips duplicate rules, so re-running is safe. Wired into
# provisioning via setup.sh. Do NOT run ad hoc over the network on a deployed
# unit; it must be hardware-tested on a spare Pi before any dev → main release.

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "✗ setup-firewall.sh must run as root (sudo)"
    exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
    echo "→ Installing ufw..."
    apt-get install -y ufw
fi

echo "→ Configuring host firewall (ufw)..."
ufw default deny incoming
ufw default allow outgoing

# Order matters for safety, not for ufw: every allow lands before enable.
ufw allow in on lo
ufw allow in on tailscale0 comment 'Tailscale (remote support)'
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'nginx UI'
ufw allow 5353/udp comment 'mDNS (digitool.local)'
ufw allow from 172.16.0.0/12 to any port 8000 proto tcp comment 'Docker bridge -> native backend'

ufw --force enable

echo "  Firewall active. Current rules:"
ufw status verbose | sed 's/^/  /'
