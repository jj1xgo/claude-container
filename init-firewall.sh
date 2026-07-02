#!/bin/bash
# Deny-by-default egress allowlist. Ported from the official Anthropic devcontainer
# (anthropics/claude-code .devcontainer/init-firewall.sh) with these deviations:
#   - No ipset: rootless podman cannot autoload the host's ip_set kernel module,
#     so plain per-CIDR iptables rules in a dedicated chain are used instead.
#   - DNS egress is limited to the resolvers in /etc/resolv.conf, not port 53 at large.
#   - IPv6 egress is dropped entirely: the allowlist resolves A records only, and
#     upstream's IPv4-only rules would otherwise leave IPv6 (pasta) as a bypass.
#   - Extra allowed domains come from /etc/claude-container/allowed-domains.txt,
#     baked into the image at build time (root-owned, not writable by node).
# Runs as root via sudo from entrypoint.sh. Must stay fail-closed: any error
# aborts container startup (opt out with CLAUDE_CONTAINER_NO_FIREWALL=1).
set -euo pipefail
IFS=$'\n\t'

ALLOWED_DOMAINS_FILE=/etc/claude-container/allowed-domains.txt
CHAIN=CLAUDE_EGRESS

# Flush existing rules. NOTE: -F only clears rules, not the -P default policy —
# if this script already ran once (policy is DROP from a prior run), traffic is
# blocked immediately after this flush until rules are rebuilt below. So the
# loopback/established/DNS-resolver ACCEPT rules are installed first, before
# anything below that needs the network (GitHub meta read is local, but the
# domain-resolution loop does live DNS lookups). This keeps re-running this
# script mid-session (e.g. to pick up a CDN's rotated IP) safe: worst case
# during rebuild is DROP-with-DNS-only, never a full lockout.
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# Allowlist chain: one ACCEPT per allowed CIDR/IP
iptables -N "$CHAIN"

add_cidr() {
  local cidr="$1" origin="$2"
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    echo "Skipping non-IPv4 range from $origin: $cidr"
    return 0
  fi
  iptables -A "$CHAIN" -d "$cidr" -j ACCEPT
}

# Loopback and established connections
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS: only to the configured resolvers (udp + tcp for large answers).
# Installed before the domain-resolution loop below, which needs it.
mapfile -t resolvers < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -E '^[0-9.]+$' || true)
if [ "${#resolvers[@]}" -eq 0 ]; then
  echo "WARNING: no IPv4 resolver in /etc/resolv.conf, allowing DNS to any host" >&2
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
else
  for resolver in "${resolvers[@]}"; do
    iptables -A OUTPUT -d "$resolver" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$resolver" -p tcp --dport 53 -j ACCEPT
  done
fi

# GitHub IP ranges (git/gh over HTTPS and SSH). No live fetch here — that would
# consume the unauthenticated GitHub API rate limit (60 req/h per IP) on every
# container start. Instead this reads the snapshot claude-container's
# stage_build_context() fetched once and baked into the image at build time —
# the ranges change rarely enough for a stale copy to stay usable.
GH_META_SNAPSHOT=/etc/claude-container/github-meta.json
echo "Loading GitHub IP ranges from build-time snapshot..."
gh_ranges=$(cat "$GH_META_SNAPSHOT" 2>/dev/null || true)
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
  echo "ERROR: GitHub meta snapshot at $GH_META_SNAPSHOT is missing or invalid" >&2
  exit 1
fi
while read -r cidr; do
  add_cidr "$cidr" "GitHub meta"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | sort -u)

# Claude Code endpoints + project-specific domains baked at build time
domains=(
  api.anthropic.com
  claude.ai
  console.anthropic.com
  statsig.anthropic.com
  statsig.com
  sentry.io
)
if [ -f "$ALLOWED_DOMAINS_FILE" ]; then
  while read -r domain; do
    domains+=("$domain")
  done < <(grep -Ev '^\s*(#|$)' "$ALLOWED_DOMAINS_FILE" | tr -d ' \t')
fi

for domain in "${domains[@]}"; do
  echo "Resolving $domain..."
  ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
  if [ -z "$ips" ]; then
    echo "ERROR: Failed to resolve $domain" >&2
    exit 1
  fi
  while read -r ip; do
    add_cidr "$ip" "$domain"
  done <<<"$ips"
done

# Host network (gateway /24), for host-side services
host_ip=$(ip route | awk '/^default/ {print $3; exit}')
if [ -z "$host_ip" ]; then
  echo "ERROR: Failed to detect host IP" >&2
  exit 1
fi
host_network="${host_ip%.*}.0/24"
echo "Host network detected as: $host_network"
iptables -A INPUT -s "$host_network" -j ACCEPT
iptables -A OUTPUT -d "$host_network" -j ACCEPT

# Default deny + allowlist chain; REJECT tail for immediate feedback
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A OUTPUT -j "$CHAIN"
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# IPv6 handling:
#   1) Primary control: compose.yml's sysctls (net.ipv6.conf.*.disable_ipv6=1) should
#      already have disabled IPv6 before this script runs, fixing a bug where glibc's
#      getaddrinfo(AI_ADDRCONFIG) misreports IPv6 as available from a link-local-only
#      address (no default route) and Happy Eyeballs then stalls on unreachable AAAA
#      candidates for allowlisted CDN domains (observed 2026-07 with
#      cyberjapandata.gsi.go.jp behind CloudFront).
#   2) Fallback (this block): retry the same disable via /proc/sys, in case the compose
#      sysctls setting didn't apply (e.g. older podman-compose without `sysctls:`
#      support). Non-fatal — this is a reliability fix, not the security gate, so it
#      deliberately breaks from this script's usual fail-closed rule.
#   3) Security boundary (unchanged below): drop all IPv6 via ip6tables regardless of
#      whether 1)/2) succeeded. The allowlist only resolves A records, so any
#      surviving IPv6 path would otherwise bypass it entirely.
disable_ipv6_fallback() {
  local path ok=1
  for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -e "$path" ] || continue
    echo 1 > "$path" 2>/dev/null || ok=0
  done
  [ "$ok" -eq 1 ]
}
if disable_ipv6_fallback; then
  echo "IPv6 disabled via /proc/sys (fallback check passed; compose.yml sysctls is primary)"
else
  echo "WARNING: could not disable IPv6 via /proc/sys/net/ipv6/conf/*/disable_ipv6 (fallback)." >&2
  echo "WARNING: if compose.yml sysctls also failed to apply, glibc may still prefer AAAA" >&2
  echo "WARNING: records for allowlisted CDN domains, risking intermittent Happy-Eyeballs" >&2
  echo "WARNING: failures. The ip6tables DROP below remains the active security boundary." >&2
fi

# IPv6: drop everything except loopback (allowlist is IPv4-only; security boundary,
# independent of whether the disable_ipv6 sysctl above took effect)
if ip6tables -L >/dev/null 2>&1; then
  ip6tables -F
  ip6tables -X
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
else
  echo "ip6tables unavailable, assuming no IPv6 connectivity"
fi

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed - was able to reach https://example.com" >&2
  exit 1
fi
echo "Verification passed - unable to reach https://example.com as expected"
# TCP connect only (no HTTP request) so verification doesn't consume the
# unauthenticated GitHub API rate limit on every container start.
if ! timeout 10 bash -c 'exec 3<>/dev/tcp/api.github.com/443' 2>/dev/null; then
  echo "ERROR: Firewall verification failed - unable to reach api.github.com:443" >&2
  exit 1
fi
echo "Verification passed - able to reach api.github.com:443 as expected"
if ! curl --connect-timeout 10 -s -o /dev/null https://api.anthropic.com; then
  echo "ERROR: Firewall verification failed - unable to reach https://api.anthropic.com" >&2
  exit 1
fi
echo "Verification passed - able to reach https://api.anthropic.com as expected"
