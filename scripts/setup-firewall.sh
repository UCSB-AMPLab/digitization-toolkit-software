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
#   - allow 8000/tcp from 172.30.0.0/24 only — the appliance compose network,
#     pinned to that subnet in docker-compose.pi.yml precisely so this rule
#     can be exact. Never widen to 172.16.0.0/12 (a venue LAN could occupy
#     it) or 192.168.0.0/16 (typically IS the venue LAN). Container→host
#     traffic keeps the container's source address, so matching on the pinned
#     subnet covers both nginx and the frontend SSR.
#   - default deny incoming, allow outgoing
#
# DHCP keeps working under deny-incoming: the client uses AF_PACKET sockets
# for the initial exchange and renewals are conntrack-established.
#
# The ruleset is RESET before being applied, so re-provisioning always
# converges on exactly this policy (manual ad-hoc rules do not survive).
# Between reset and enable the firewall is briefly open — fail-open, never
# fail-closed, so a re-run cannot lock anyone out.
#
# Wired into provisioning via setup.sh. Do NOT run ad hoc over the network on
# a deployed unit; it must be hardware-tested on a spare Pi before any
# dev → main release.

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

# Start from a clean slate so the resulting ruleset is exactly this file.
ufw --force reset >/dev/null

ufw default deny incoming
ufw default allow outgoing

# Order matters for safety, not for ufw: every allow lands before enable.
ufw allow in on lo
ufw allow in on tailscale0 comment 'Tailscale (remote support)'
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'nginx UI'
ufw allow 5353/udp comment 'mDNS (digitool.local)'
ufw allow from 172.30.0.0/24 to any port 8000 proto tcp comment 'appliance compose network -> native backend'

ufw --force enable

echo "  Firewall active. Current rules:"
ufw status verbose | sed 's/^/  /'
