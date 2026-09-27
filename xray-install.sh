#!/usr/bin/env bash

# ==============================================================================
# Xray VLESS + REALITY — Universal Management Script
# ------------------------------------------------------------------------------
# A single interactive script that handles the full lifecycle:
#   - First run  : installs Xray-core with VLESS+REALITY (interactive prompts)
#   - Re-run     : management menu (add/remove clients, uninstall)
#
# Usage:
#   sudo bash xray-install.sh
# ==============================================================================

set -euo pipefail

CONFIG="/etc/xray/config.json"
SERVER_ADDR_FILE="/etc/xray/server.addr"
# Set when the user declines the private-address block, so it is not asked again
DECLINE_FILE="/etc/xray/.no-private-block"
# Private/local destinations clients must not reach through the proxy
# (server's localhost, LAN/provider networks, cloud metadata 169.254.169.254,
#  multicast and reserved ranges)
PRIVATE_IPS_JSON='["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"]'

# ==============================================================================
# Utility functions
# ==============================================================================

# Check whether a previous installation exists.
# Deliberately does not require the service to be enabled: a disabled service
# must not trigger a fresh install that would overwrite keys and clients.
is_xray_installed() {
    [[ -f /usr/local/bin/xray ]] && \
    [[ -f "$CONFIG" ]] && \
    [[ -f /etc/systemd/system/xray.service ]]
}

# Make sure Xray starts at boot; re-enable it if autostart was turned off
ensure_xray_autostart() {
    systemctl is-enabled --quiet xray 2>/dev/null && return 0
    if systemctl enable xray &>/dev/null; then
        echo ">>> Xray autostart at boot was disabled — enabled it."
    else
        echo "Warning: could not enable Xray autostart (is the service masked?)." >&2
    fi
}

# Resolve the server's public IPv4 address (multiple fallbacks)
detect_public_ip() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me; do
        ip="$(curl -4fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        # Accept only something that looks like an IPv4 address (not an error page)
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"; return 0
        fi
    done
    # Fallback: first public-looking IPv4 of the machine. A private address here
    # would produce an unusable client URI (e.g. NAT VPS), so private ranges are skipped.
    local cand
    for cand in $(hostname -I 2>/dev/null || true); do
        [[ "$cand" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
        case "$cand" in
            10.*|127.*|169.254.*|192.168.*|0.*) continue ;;
        esac
        [[ "$cand" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && continue
        [[ "$cand" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && continue
        echo "$cand"; return 0
    done
    return 0
}

# Return the server address clients connect to.
# Uses the address saved at install time; for older installs without it,
# auto-detects (or asks) and saves it for next time.
get_server_address() {
    local server=""
    [[ -f "$SERVER_ADDR_FILE" ]] && server="$(head -n1 "$SERVER_ADDR_FILE")"
    if [[ -z "$server" ]]; then
        server="$(detect_public_ip)"
        if [[ -z "$server" ]]; then
            echo "Unable to auto-detect public IP." >&2
            read -rp "Enter the server's public IP or domain: " server
            [[ -z "$server" ]] && { echo "Server address is required." >&2; exit 1; }
        fi
        echo "$server" > "$SERVER_ADDR_FILE"
    fi
    echo "$server"
}

# Generate a random UUID using the best available method
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # No time-based fallback: the UUID is a credential and must be unpredictable
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' \
            | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

# Generate an 8-char hex Short ID that does not collide with existing ones
# $1 — space-separated list of existing Short IDs (optional)
generate_short_id() {
    local existing="${1:-}"
    local sid=""
    for _ in {1..10}; do
        if command -v openssl &>/dev/null; then
            sid="$(openssl rand -hex 4)"
        else
            # od instead of xxd: present in both coreutils and busybox
            sid="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%08x' $((RANDOM * RANDOM)))"
        fi
        # Return immediately if unique
        if [[ ! " $existing " =~ " $sid " ]]; then
            echo "$sid"; return 0
        fi
    done
    echo "$sid"  # last resort after 10 collisions
}

# Set ownership and permissions on config.json and /etc/xray/ directory
set_config_permissions() {
    local path="${1:-$CONFIG}"
    chown root:xray "$(dirname "$path")"
    chmod 750 "$(dirname "$path")"
    chown root:xray "$path"
    chmod 640 "$path"
}

# Validate an Xray config file; print Xray's output and fail if it is invalid
# $1 — path to config (optional, defaults to $CONFIG)
validate_config() {
    local path="${1:-$CONFIG}" output
    if ! output=$(/usr/local/bin/xray run -test -format json -config "$path" 2>&1); then
        echo "Xray config validation failed ($path):" >&2
        echo "$output" >&2
        return 1
    fi
}

# Restart the Xray service and make sure it is actually running
restart_xray() {
    systemctl restart xray
    # Poll briefly: the unit may need a moment to reach "active"
    local i
    for i in {1..5}; do
        sleep 1
        systemctl is-active --quiet xray && return 0
    done
    echo "Xray service failed to start. Recent logs:" >&2
    journalctl -u xray -n 20 --no-pager >&2 || true
    exit 1
}

# Check whether the config already blocks private destinations
has_private_block() {
    jq -e '[.routing.rules[]? | select(.outboundTag == "block")] | length > 0' "$CONFIG" &>/dev/null
}

# Add the private-address block to an existing config (older installs):
# tag DNS and outbounds, route Xray's own DNS queries directly (the system
# resolver may be 127.0.0.53 / 127.0.0.11), send private IPs to blackhole.
# freedom uses ForceIP: with UseIP, names Xray's DNS can't resolve (localhost,
# entries from /etc/hosts) fall back to the system resolver and bypass the block.
add_private_block() {
    local tmp
    tmp=$(mktemp)
    jq --argjson ips "$PRIVATE_IPS_JSON" '
        .dns.tag = "dns-internal" |
        .outbounds = ((.outbounds // []) | map(if .protocol == "freedom" then (.tag //= "direct") | .settings.domainStrategy = "ForceIP" else . end)) |
        (if any(.outbounds[]; .tag == "block") then . else .outbounds += [{"tag": "block", "protocol": "blackhole"}] end) |
        .routing.domainStrategy = "IPIfNonMatch" |
        .routing.rules = [
            {"type": "field", "inboundTag": ["dns-internal"], "outboundTag": "direct"},
            {"type": "field", "ip": $ips, "outboundTag": "block"}
        ] + ((.routing.rules // []) | map(select(.outboundTag != "block" and .inboundTag != ["dns-internal"])))
    ' "$CONFIG" > "$tmp"
    validate_config "$tmp" || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$CONFIG"
    set_config_permissions
    rm -f "$DECLINE_FILE"
    restart_xray
    echo ">>> Access to private/local addresses is now blocked."
}

# Offer the private-address block if the config does not have it yet
offer_private_block() {
    command -v jq &>/dev/null || return 0
    # Only touch a config Xray accepts; a broken one is reported by start/restart
    validate_config &>/dev/null || return 0
    has_private_block && return 0
    # A previous refusal is remembered so the question is not asked on every run
    [[ -f "$DECLINE_FILE" ]] && return 0
    echo ""
    echo "Your config lets clients reach the server's local and private addresses"
    echo "(localhost services, internal networks, cloud metadata)."
    local answer
    read -rp "Block them now? [Y/n]: " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
        touch "$DECLINE_FILE"
    else
        add_private_block
    fi
}

# Create a dedicated system user/group for the Xray service
ensure_xray_user() {
    if ! id -u xray &>/dev/null; then
        local nologin="/usr/sbin/nologin"
        [[ -x "$nologin" ]] || nologin="$(command -v nologin 2>/dev/null || echo /bin/false)"
        useradd --system --no-create-home --shell "$nologin" xray
        echo ">>> Created system user 'xray'."
    fi
}

# Install jq if it is not already present
ensure_jq() {
    command -v jq &>/dev/null && return 0
    echo ">>> Installing jq..."
    if command -v apt &>/dev/null; then
        apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y jq
    elif command -v dnf &>/dev/null; then
        dnf install -y jq
    elif command -v yum &>/dev/null; then
        yum install -y epel-release && yum install -y jq
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm jq
    else
        echo "Please install 'jq' manually." >&2; exit 1
    fi
}

# Install all required packages for a fresh installation
install_deps() {
    echo -e "\n>>> Installing dependencies..."
    if command -v apt &>/dev/null; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            curl unzip tar uuid-runtime qrencode jq openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y curl unzip tar qrencode jq openssl
    elif command -v yum &>/dev/null; then
        yum install -y curl unzip tar qrencode openssl epel-release
        yum install -y jq
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm curl unzip tar qrencode jq openssl
    else
        echo "Unsupported package manager. Install dependencies manually." >&2
        exit 1
    fi
}

# Enable TCP BBR congestion control for better throughput
enable_bbr() {
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q '^bbr$'; then
        echo ">>> BBR congestion control already enabled."
        return 0
    fi
    echo -e "\n>>> Enabling TCP BBR congestion control..."
    # Use a drop-in: /etc/sysctl.conf is no longer read at boot on newer distros (e.g. Debian 13)
    local bbr_conf="/etc/sysctl.d/99-xray-bbr.conf"
    mkdir -p /etc/sysctl.d
    printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' > "$bbr_conf"
    modprobe tcp_bbr 2>/dev/null || true
    # BBR is a speed optimization, not a requirement — never abort the install over it
    if ! sysctl -p "$bbr_conf"; then
        echo "Warning: could not enable BBR (kernel too old or module unavailable). Continuing without it." >&2
    fi
}

# Validate an address used in client links: IPv4 or a domain name.
# The value is embedded into the JSON config and client URIs, so free-form input
# (which could break both) is rejected. IPv6 literals need [brackets] in URIs —
# a domain or IPv4 is required instead.
is_valid_host() {
    local addr="$1"
    [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
    [[ "$addr" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# Best effort: allow 443/tcp when a local firewall is active (never fatal)
open_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
        if ufw status 2>/dev/null | grep -q '443/tcp'; then
            echo ">>> UFW already allows 443/tcp."
        elif ufw allow 443/tcp &>/dev/null; then
            echo ">>> UFW: allowed 443/tcp."
        else
            echo "Warning: failed to add a UFW rule — open port 443 manually." >&2
        fi
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        if firewall-cmd --permanent --list-ports 2>/dev/null | grep -q '443/tcp'; then
            echo ">>> firewalld already allows 443/tcp."
        elif firewall-cmd --permanent --add-port=443/tcp &>/dev/null && firewall-cmd --reload &>/dev/null; then
            echo ">>> firewalld: allowed 443/tcp."
        else
            echo "Warning: failed to open port 443 in firewalld — do it manually." >&2
        fi
    fi
}

# Check the REALITY target against Project X's minimum requirements:
# TLS 1.3, HTTP/2 (needed by XHTTP) and no redirect to another domain.
# Warns and asks before continuing; network problems look the same as "no TLS 1.3".
check_sni_target() {
    local sni="$1" result http_ver code redirect redirect_host answer
    local problems=()
    echo -e "\n>>> Checking SNI target https://$sni (TLS 1.3, HTTP/2, no redirect)..."
    result="$(curl -sS -o /dev/null --tlsv1.3 --http2 --connect-timeout 5 --max-time 10 \
        -w '%{http_version} %{http_code} %{redirect_url}' "https://$sni/" 2>/dev/null || true)"
    read -r http_ver code redirect <<< "$result"
    if [[ -z "$code" || "$code" == "000" ]]; then
        problems+=("no TLS 1.3 connection (site unreachable or TLS 1.3 not supported)")
    else
        [[ "$http_ver" == "2" ]] || problems+=("no HTTP/2 support (got HTTP/$http_ver)")
        if [[ -n "${redirect:-}" ]]; then
            redirect_host="${redirect#*://}"; redirect_host="${redirect_host%%[/:?]*}"
            [[ "$redirect_host" == "$sni" ]] || problems+=("redirects to another domain: $redirect_host")
        fi
    fi
    if (( ${#problems[@]} == 0 )); then
        echo ">>> SNI target looks good."
        return 0
    fi
    echo "Warning: $sni does not meet REALITY target requirements:" >&2
    printf '   - %s\n' "${problems[@]}" >&2
    read -rp "Continue anyway? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted. Choose another SNI domain." >&2; exit 1; }
}

# Build a VLESS+REALITY URI and display it along with a QR code
# Arguments: uuid server public_key short_id sni [network] [xhttp_path]
# network: "tcp" (with XTLS Vision) or "xhttp" (no flow; Vision is not supported)
show_connection_info() {
    local uuid="$1" server="$2" pbk="$3" sid="$4" sni="$5" network="${6:-tcp}" path="${7:-/}"
    local fp="chrome" uri spx
    # spiderX: crawler start path, recommended to differ per client
    spx="%2F$(openssl rand -hex 4 2>/dev/null || generate_short_id)"
    if [[ "$network" == "xhttp" ]]; then
        uri="vless://${uuid}@${server}:443?type=xhttp&encryption=none&security=reality&pbk=${pbk}&sid=${sid}&fp=${fp}&sni=${sni}&spx=${spx}&path=${path//\//%2F}&mode=auto#${sid}-${sni}"
    else
        uri="vless://${uuid}@${server}:443?type=tcp&encryption=none&flow=xtls-rprx-vision&security=reality&pbk=${pbk}&sid=${sid}&fp=${fp}&sni=${sni}&spx=${spx}#${sid}-${sni}"
    fi

    echo ""
    echo "Generated VLESS+REALITY URI (copy or scan):"
    echo "$uri"

    if command -v qrencode &>/dev/null; then
        local png="/etc/xray/vless-${uuid}.png"
        if qrencode -o "$png" -l H -t png -- "$uri" 2>/dev/null; then
            chmod 600 "$png"  # the image embeds the full client credentials
            echo -e "\nQR code saved to: $png"
        else
            rm -f "$png"
            echo -e "\nWarning: could not write the QR code PNG." >&2
        fi
        # ANSIUTF8 needs qrencode >= 4.0 — fall back for older builds; never fatal
        qrencode -t ANSIUTF8 -- "$uri" 2>/dev/null \
            || qrencode -t UTF8 -- "$uri" 2>/dev/null \
            || qrencode -t ANSI -- "$uri" 2>/dev/null \
            || true
    else
        echo -e "\nqrencode not available — QR code generation skipped."
    fi
}

# ==============================================================================
# Fresh installation (interactive)
# ==============================================================================

new_install() {
    echo ""
    echo "Welcome to the Xray VLESS+REALITY installer!"
    echo ""

    # ---- Public IP ----
    local server
    local detected input
    detected="$(detect_public_ip)"
    if [[ -n "$detected" ]]; then
        echo "Detected public IP: $detected"
        read -rp "Server address for clients (IP or domain) [$detected]: " input
        server="${input:-$detected}"
    else
        echo "Unable to auto-detect public IP." >&2
        read -rp "Enter the server's public IP or domain: " server
    fi
    # Validate the format: this value is embedded into the JSON config and the URIs
    until is_valid_host "$server"; do
        read -rp "Invalid address (use a domain or IPv4). Try again: " server
    done

    # ---- SNI domain (required) ----
    local sni
    echo ""
    read -rp "Enter the SNI domain (e.g. www.cloudflare.com): " sni
    until is_valid_host "$sni"; do
        read -rp "Invalid SNI domain. Try again: " sni
    done

    # ---- DNS selection ----
    echo ""
    echo "Select a DNS server for Xray:"
    echo "   1) Current system resolvers"
    echo "   2) Google        (8.8.8.8, 8.8.4.4)"
    echo "   3) Cloudflare    (1.1.1.1, 1.0.0.1)"
    echo "   4) OpenDNS       (208.67.222.222, 208.67.220.220)"
    echo "   5) Quad9         (9.9.9.9, 149.112.112.112)"
    echo "   6) AdGuard DNS   (94.140.14.14, 94.140.15.15)"
    local dns_choice dns1 dns2
    read -rp "DNS [1-6, default 2]: " dns_choice
    case "${dns_choice:-2}" in
        1)
            dns1="$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || true)"
            dns2="$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk 'NR==2{print $2}' || true)"
            if [[ -z "$dns1" ]]; then
                dns1="8.8.8.8"; dns2="8.8.4.4"
                echo "No system resolvers found. Falling back to Google DNS."
            fi
            ;;
        3)  dns1="1.1.1.1";         dns2="1.0.0.1" ;;
        4)  dns1="208.67.222.222";   dns2="208.67.220.220" ;;
        5)  dns1="9.9.9.9";         dns2="149.112.112.112" ;;
        6)  dns1="94.140.14.14";    dns2="94.140.15.15" ;;
        *)  dns1="8.8.8.8";         dns2="8.8.4.4" ;;
    esac

    # ---- Transport ----
    local transport_choice network xhttp_path=""
    echo ""
    echo "Select a transport:"
    echo "   1) TCP + XTLS Vision  (default; supported by all client apps)"
    echo "   2) XHTTP              (newer, splits traffic into HTTP requests and is harder"
    echo "                          to fingerprint; check that your client app supports it)"
    read -rp "Transport [1-2, default 1]: " transport_choice
    if [[ "${transport_choice:-1}" == "2" ]]; then
        network="xhttp"
        xhttp_path="/$(openssl rand -hex 4 2>/dev/null || generate_short_id)"
    else
        network="tcp"
    fi

    # ---- Confirmation summary ----
    echo ""
    echo "Xray VLESS+REALITY will be installed with these settings:"
    echo ""
    echo "   Server IP  : $server"
    echo "   SNI domain : $sni"
    echo "   DNS servers: $dns1${dns2:+, $dns2}"
    echo "   Transport  : $network"
    echo ""
    read -rp "Press Enter to continue or Ctrl+C to abort..."

    # ---- Install system packages ----
    install_deps
    enable_bbr
    open_firewall

    # ---- Download latest Xray-core binary ----
    local xray_version
    xray_version="$(curl -fsSL --connect-timeout 10 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
    if [[ -z "$xray_version" ]]; then
        echo "Unable to fetch latest Xray-core version from GitHub." >&2
        exit 1
    fi
    echo -e "\n>>> Latest Xray-core version: $xray_version"

    local arch_pkg
    case "$(uname -m)" in
        x86_64|amd64)   arch_pkg="xray-linux-64" ;;
        aarch64|arm64)  arch_pkg="xray-linux-arm64-v8a" ;;
        armv7l|armv6l)  arch_pkg="xray-linux-arm32-v7a" ;;
        *) echo "Unsupported CPU architecture: $(uname -m)" >&2; exit 1 ;;
    esac

    local tmp_dir
    tmp_dir=$(mktemp -d)
    # Clean up the temp dir even if download/unzip fails and set -e aborts the script
    # shellcheck disable=SC2064  # expand now: tmp_dir is local
    trap "rm -rf '$tmp_dir'" EXIT

    local zip_name="${arch_pkg}.zip"
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${xray_version}/${zip_name}"
    echo ">>> Downloading Xray-core ${xray_version} (${arch_pkg})..."
    curl -fL --connect-timeout 10 --max-time 300 "$download_url" -o "$tmp_dir/$zip_name"

    install -d /usr/local/bin /etc/xray
    unzip -qo "$tmp_dir/$zip_name" -d "$tmp_dir"
    install -m 755 "$tmp_dir/xray" /usr/local/bin/xray
    rm -rf "$tmp_dir"
    trap - EXIT

    # ---- Verify the SNI target site ----
    check_sni_target "$sni"

    # ---- Generate X25519 key pair for REALITY ----
    local key_output private_key public_key
    key_output=$(/usr/local/bin/xray x25519)
    
    # Use $NF (last field) to handle varying output formats across Xray versions
    # Support both old ("Private key: / Public key:") and new ("PrivateKey: / Password:") formats
    private_key=$(echo "$key_output" | awk '/PrivateKey/{print $NF}')
    [[ -z "$private_key" ]] && private_key=$(echo "$key_output" | awk '/Private key:/{print $3}')

    public_key=$(echo "$key_output" | awk '/Password/{print $NF}')
    [[ -z "$public_key" ]] && public_key=$(echo "$key_output" | awk '/Public key:/{print $3}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        echo "Failed to generate X25519 keys. Raw output:" >&2
        echo "$key_output" >&2
        exit 1
    fi

    # Persist public key for future client additions
    echo "$public_key" > /etc/xray/public.key
    echo "$server" > "$SERVER_ADDR_FILE"

    # ---- Generate first client credentials ----
    local uuid short_id
    uuid="$(generate_uuid)"
    short_id="$(generate_short_id)"

    # ---- Write config.json (with DNS section) ----
    local dns_json="\"$dns1\""
    [[ -n "$dns2" ]] && dns_json="\"$dns1\", \"$dns2\""

    # Transport-specific parts: Vision flow for TCP, path/mode for XHTTP
    local client_json xhttp_json=""
    if [[ "$network" == "xhttp" ]]; then
        client_json="{ \"id\": \"$uuid\" }"
        xhttp_json=$'\n        "xhttpSettings": { "path": "'"$xhttp_path"'", "mode": "auto" },'
    else
        client_json="{ \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\" }"
    fi

    # ---- Create dedicated service user (needed before setting file permissions) ----
    ensure_xray_user

    cat > "$CONFIG" <<EOF
{
  "dns": {
    "servers": [$dns_json],
    "tag": "dns-internal"
  },
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          $client_json
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "$network",$xhttp_json
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$sni:443",
          "xver": 0,
          "serverNames": [
            "$sni"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["dns-internal"], "outboundTag": "direct" },
      { "type": "field", "ip": $PRIVATE_IPS_JSON, "outboundTag": "block" }
    ]
  },
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIP" } },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
    set_config_permissions
    validate_config || exit 1

    # ---- Create systemd unit ----
    cat > /etc/systemd/system/xray.service <<SERVICE
[Unit]
Description=Xray Service (VLESS + REALITY)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=xray
Group=xray
UMask=0077
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectProc=invisible
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable xray
    restart_xray

    # ---- Display connection info ----
    show_connection_info "$uuid" "$server" "$public_key" "$short_id" "$sni" "$network" "$xhttp_path"

    cat <<EOF

Xray-core VLESS + REALITY installation completed!

Configuration file : $CONFIG
Systemd service    : xray (running)
Fake SNI           : $sni
Connect to host    : $server
Public key         : $public_key (saved to /etc/xray/public.key)
Server address     : saved to $SERVER_ADDR_FILE
Transport          : $network${xhttp_path:+ (path $xhttp_path)}
Short ID           : $short_id
UUID               : $uuid

To manage clients or remove Xray, run this script again.
EOF
}

# ==============================================================================
# Add a new client to the running server
# ==============================================================================

add_client() {
    ensure_jq

    local server
    server="$(get_server_address)"

    # Transport of the existing inbound (tcp or xhttp) decides the client format
    local network xhttp_path
    network="$(jq -r '.inbounds[0].streamSettings.network // "tcp"' "$CONFIG")"
    xhttp_path="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/"' "$CONFIG")"

    # Generate unique credentials
    local uuid short_id existing_sids
    uuid="$(generate_uuid)"
    existing_sids=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[]? // empty' "$CONFIG" 2>/dev/null | tr '\n' ' ' || echo "")
    short_id="$(generate_short_id "$existing_sids")"

    echo ""
    echo "Adding new client..."
    echo "  UUID     : $uuid"
    echo "  Short ID : $short_id"

    # Append client and Short ID atomically (write to temp, then mv)
    local tmp
    tmp=$(mktemp)
    # XHTTP clients have no flow (XTLS Vision works only over TCP)
    jq --arg uid "$uuid" --arg sid "$short_id" --arg net "$network" '
        (.inbounds[0].settings.clients //= []) |
        .inbounds[0].settings.clients += [if $net == "xhttp" then {"id":$uid} else {"id":$uid,"flow":"xtls-rprx-vision"} end] |
        (.inbounds[0].streamSettings.realitySettings.shortIds //= []) |
        .inbounds[0].streamSettings.realitySettings.shortIds += [$sid]
    ' "$CONFIG" > "$tmp"
    validate_config "$tmp" || { rm -f "$tmp"; exit 1; }
    mv "$tmp" "$CONFIG"

    set_config_permissions
    restart_xray

    # Build and display the connection URI
    local pbk sni
    pbk="$(cat /etc/xray/public.key 2>/dev/null || true)"
    if [[ -z "$pbk" ]]; then
        # Recover: derive the public key from the private key stored in the config
        local priv_key key_out
        priv_key="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$CONFIG")"
        if [[ -n "$priv_key" ]]; then
            key_out="$(/usr/local/bin/xray x25519 -i "$priv_key" 2>/dev/null || true)"
            pbk="$(echo "$key_out" | awk '/Password/{print $NF}')"
            [[ -z "$pbk" ]] && pbk="$(echo "$key_out" | awk '/Public key:/{print $3}')"
            if [[ -n "$pbk" ]]; then
                echo "$pbk" > /etc/xray/public.key
                echo ">>> Restored missing /etc/xray/public.key."
            fi
        fi
    fi
    if [[ -z "$pbk" ]]; then
        echo "Cannot determine the REALITY public key — create /etc/xray/public.key first." >&2
        exit 1
    fi
    sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG")"
    [[ -z "$sni" ]] && sni="$(jq -r '.inbounds[0].streamSettings.realitySettings | .target // .dest' "$CONFIG" | cut -d: -f1)"

    show_connection_info "$uuid" "$server" "$pbk" "$short_id" "$sni" "$network" "$xhttp_path"

    echo ""
    echo "Client added successfully! Xray has been restarted."
}

# ==============================================================================
# Remove an existing client from the server
# ==============================================================================

remove_client() {
    ensure_jq

    local num_clients num_sids
    num_clients=$(jq '.inbounds[0].settings.clients | length' "$CONFIG")
    num_sids=$(jq '.inbounds[0].streamSettings.realitySettings.shortIds // [] | length' "$CONFIG")

    # Refuse to remove the last remaining client
    if [[ "$num_clients" -le 1 ]]; then
        echo ""
        echo "There is only one client configured."
        echo "Cannot remove the last client — use option 4 to remove Xray entirely."
        return
    fi

    echo ""
    echo "Current clients:"
    echo ""

    # List every client with its positional Short ID
    local i=0
    local uuids=()
    while IFS= read -r uid; do
        uuids+=("$uid")
        local sid
        sid=$(jq -r --argjson idx "$i" \
            '.inbounds[0].streamSettings.realitySettings.shortIds[$idx] // "N/A"' "$CONFIG")
        echo "   $((i + 1))) $uid  (Short ID: $sid)"
        i=$((i + 1))
    done < <(jq -r '.inbounds[0].settings.clients[].id' "$CONFIG")

    echo ""
    read -rp "Select the client to remove [1-$num_clients]: " choice

    # Validate the selection
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "Invalid selection." >&2
        return
    fi
    choice=$((10#$choice))  # strip leading zeros so "08" is not parsed as octal
    if (( choice < 1 || choice > num_clients )); then
        echo "Invalid selection." >&2
        return
    fi

    local idx=$(( choice - 1 ))
    local target_uuid="${uuids[$idx]}"

    echo ""
    read -rp "Confirm removal of client $target_uuid? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Aborted."; return; }

    # Remove the client object and its corresponding Short ID by index; the Short ID
    # is positional, so only touch it while clients and Short IDs stay in sync
    if [[ "$num_sids" -eq "$num_clients" ]]; then
        jq --argjson idx "$idx" '
            .inbounds[0].settings.clients |= del(.[$idx]) |
            .inbounds[0].streamSettings.realitySettings.shortIds |= del(.[$idx])
        ' "$CONFIG" > "${CONFIG}.tmp"
    else
        echo "Warning: clients ($num_clients) and Short IDs ($num_sids) are out of sync — removing the client entry only." >&2
        jq --argjson idx "$idx" '.inbounds[0].settings.clients |= del(.[$idx])' "$CONFIG" > "${CONFIG}.tmp"
    fi
    validate_config "${CONFIG}.tmp" || { rm -f "${CONFIG}.tmp"; exit 1; }
    mv "${CONFIG}.tmp" "$CONFIG"

    set_config_permissions
    restart_xray

    # Clean up QR code image if it exists
    rm -f "/etc/xray/vless-${target_uuid}.png"

    echo "Client removed. Xray has been restarted."
}

# ==============================================================================
# Completely uninstall Xray and clean up all related files
# ==============================================================================

remove_xray() {
    echo ""
    read -rp "Are you sure you want to completely remove Xray? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Aborted."; return; }

    echo ""
    echo ">>> Stopping and disabling Xray service..."
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    echo ">>> Removing Xray binary, configuration and service unit..."
    rm -f /usr/local/bin/xray
    rm -rf /etc/xray
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/sysctl.d/99-xray-bbr.conf
    if id -u xray &>/dev/null; then
        userdel xray 2>/dev/null || echo "Note: could not remove the system user 'xray'." >&2
    fi
    systemctl daemon-reload

    echo ""
    echo "Xray has been completely removed."
}

# ==============================================================================
# Management menu (shown when Xray is already installed)
# ==============================================================================

# Print a short summary of the service state and configuration
show_status() {
    local state since autostart version server clients sni
    state="$(systemctl is-active xray 2>/dev/null || true)"
    autostart="$(systemctl is-enabled xray 2>/dev/null || true)"
    [[ "$state" == "active" ]] && since="$(systemctl show xray -p ActiveEnterTimestamp --value 2>/dev/null || true)"
    version="$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}' || true)"
    server="$(head -n1 "$SERVER_ADDR_FILE" 2>/dev/null || true)"

    # Don't install jq just to show the menu — print "?" if it is missing
    local transport="?"
    clients="?"; sni="?"
    if command -v jq &>/dev/null; then
        clients="$(jq '.inbounds[0].settings.clients | length' "$CONFIG" 2>/dev/null || echo "?")"
        sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // "?"' "$CONFIG" 2>/dev/null || echo "?")"
        transport="$(jq -r '.inbounds[0].streamSettings | if .network == "xhttp" then "XHTTP (path \(.xhttpSettings.path // "/"))" else "TCP + XTLS Vision" end' "$CONFIG" 2>/dev/null || echo "?")"
    fi

    echo ""
    echo "   Service  : ${state:-unknown}${since:+ (since $since)}"
    echo "   Autostart: ${autostart:-unknown}"
    echo "   Version  : ${version:-unknown}"
    echo "   Address  : ${server:-not saved}"
    echo "   SNI      : $sni"
    echo "   Transport: $transport"
    echo "   Clients  : $clients"
    echo "   Log      : journalctl -u xray"
}

manage_menu() {
    echo ""
    echo "Xray VLESS+REALITY is already installed."
    show_status
    echo ""
    echo "Select an option:"
    echo "   1) Add a new client"
    echo "   2) Remove an existing client"
    echo "   3) Start / restart Xray"
    echo "   4) Remove Xray"
    echo "   5) Exit"

    local option
    read -rp "Option [1-5]: " option
    case "$option" in
        1) add_client ;;
        2) remove_client ;;
        3) validate_config || exit 1; restart_xray; echo ">>> Xray restarted." ;;
        4) remove_xray ;;
        5) exit 0 ;;
        *) echo "Invalid option." >&2; exit 1 ;;
    esac
}

# ==============================================================================
# Entry point
# ==============================================================================

# This script must be executed as root
if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root. Use: sudo bash $0" >&2
    exit 1
fi

if is_xray_installed; then
    ensure_xray_autostart
    offer_private_block
    manage_menu
else
    new_install
fi
