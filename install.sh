#!/usr/bin/env bash
set -euo pipefail

PANEL_REPO="${PANEL_REPO:-https://github.com/BigDaddy3334/olcrtc-manager-panel.git}"
PANEL_REF="${PANEL_REF:-main}"
OLCRTC_REPO="${OLCRTC_REPO:-https://github.com/openlibrecommunity/olcrtc.git}"
OLCRTC_REF="${OLCRTC_REF:-master}"
GO_VERSION="${GO_VERSION:-1.25.0}"
PANEL_ADDR="${PANEL_ADDR:-127.0.0.1}"
PANEL_PORT="${PANEL_PORT:-8888}"
DNS_SERVER="${DNS_SERVER:-1.1.1.1:53}"
CLIENT_ID="${CLIENT_ID:-default}"
INSTALL_SRC_DIR="${INSTALL_SRC_DIR:-/opt/olcrtc-manager-src}"
CONFIG_DIR="${CONFIG_DIR:-/etc/olcrtc-manager}"
CONFIG_PATH="${CONFIG_PATH:-$CONFIG_DIR/config.json}"
PANEL_ENV_PATH="${PANEL_ENV_PATH:-$CONFIG_DIR/panel.env}"

# --- new: domain / TLS options -----------------------------------------
# Can be provided non-interactively via environment variables:
#   PANEL_DOMAIN=example.com
#   PANEL_TLS_CERT=/etc/letsencrypt/live/example.com/fullchain.pem
#   PANEL_TLS_KEY=/etc/letsencrypt/live/example.com/privkey.pem
# If PANEL_DOMAIN/PANEL_TLS_CERT/PANEL_TLS_KEY are unset and the script is
# attached to a terminal, it will ask interactively. Otherwise it falls
# back to a self-signed certificate on the raw IP, same as before.
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_TLS_CERT="${PANEL_TLS_CERT:-}"
PANEL_TLS_KEY="${PANEL_TLS_KEY:-}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

log() {
	printf '[olcrtc-manager] %s\n' "$*"
}

die() {
	printf '[olcrtc-manager] ERROR: %s\n' "$*" >&2
	exit 1
}

# Reads a line from the controlling terminal even when the script itself
# is being fed via a pipe (curl | sudo bash), so prompts still work.
ask() {
	local prompt="$1" default="${2:-}" reply
	if [ "$NONINTERACTIVE" = "1" ] || [ ! -e /dev/tty ]; then
		printf '%s\n' "$default"
		return
	fi
	if [ -n "$default" ]; then
		printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
	else
		printf '%s: ' "$prompt" > /dev/tty
	fi
	IFS= read -r reply < /dev/tty || reply=""
	printf '%s\n' "${reply:-$default}"
}

ask_yes_no() {
	local prompt="$1" default="${2:-n}" reply
	reply="$(ask "$prompt (y/n)" "$default")"
	case "$reply" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

need_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "run as root: curl -fsSL .../scripts/install.sh | sudo bash"
	fi
}

install_packages() {
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		apt-get install -y --no-install-recommends ca-certificates curl git tar xz-utils iproute2 iptables openssl
		return
	fi
	die "unsupported OS: this installer currently supports apt-based Linux distributions"
}

go_arch() {
	case "$(uname -m)" in
		x86_64|amd64) echo "amd64" ;;
		aarch64|arm64) echo "arm64" ;;
		*) die "unsupported CPU architecture: $(uname -m)" ;;
	esac
}

go_version_ok() {
	command -v go >/dev/null 2>&1 || return 1
	local current
	current="$(go env GOVERSION | sed 's/^go//')"
	[ "$(printf '%s\n%s\n' "$GO_VERSION" "$current" | sort -V | head -n1)" = "$GO_VERSION" ]
}

install_go() {
	if go_version_ok; then
		log "Go $(go env GOVERSION) found"
		return
	fi

	local arch archive url tmp
	arch="$(go_arch)"
	archive="go${GO_VERSION}.linux-${arch}.tar.gz"
	url="https://go.dev/dl/${archive}"
	tmp="/tmp/${archive}"

	log "installing Go ${GO_VERSION}"
	curl -fsSL "$url" -o "$tmp"
	rm -rf /usr/local/go
	tar -C /usr/local -xzf "$tmp"
	ln -sf /usr/local/go/bin/go /usr/local/bin/go
	ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

clone_repo() {
	local repo="$1" ref="$2" dest="$3"
	rm -rf "$dest"
	git clone --depth 1 --branch "$ref" "$repo" "$dest"
}

build_olcrtc() {
	local src="$1"
	log "building olcrtc"
	(cd "$src" && CGO_ENABLED=0 go build -o /tmp/olcrtc ./cmd/olcrtc)
	install -m 0755 /tmp/olcrtc /usr/local/bin/olcrtc
}

build_manager() {
	local src="$1"
	log "building olcrtc-manager"
	if [ ! -f "$src/cmd/olcrtc-manager/web/dist/index.html" ]; then
		die "frontend bundle is missing in repository; build assets before publishing installer"
	fi
	(cd "$src" && CGO_ENABLED=0 go build -o /tmp/olcrtc-manager ./cmd/olcrtc-manager)
	install -m 0755 /tmp/olcrtc-manager /usr/local/bin/olcrtc-manager
}

write_config_if_missing() {
	install -d -m 0755 "$CONFIG_DIR"
	install -d -m 0700 "$CONFIG_DIR/backups"

	if [ -f "$CONFIG_PATH" ]; then
		log "keeping existing config: $CONFIG_PATH"
		return
	fi

	log "generating initial room"
	local room key
	room="$(/usr/local/bin/olcrtc -mode gen -carrier wbstream -dns "$DNS_SERVER" -amount 1 | tail -n1 | tr -d '\r')"
	[ -n "$room" ] || die "failed to generate initial room"
	key="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

	cat > "$CONFIG_PATH" <<EOF
{
  "version": 1,
  "name": "OlcRTC VPS",
  "port": $PANEL_PORT,
  "clients": [
    {
      "client-id": "$CLIENT_ID",
      "quota": {},
      "locations": [
        {
          "name": "$CLIENT_ID",
          "client-id": "$CLIENT_ID",
          "endpoint": {
            "room_id": "$room",
            "key": "$key"
          },
          "carrier": "wbstream",
          "transport": {
            "type": "datachannel"
          },
          "link": "direct",
          "data": "data",
          "dns": "$DNS_SERVER"
        }
      ]
    }
  ]
}
EOF
	chmod 0600 "$CONFIG_PATH"
	log "created config: $CONFIG_PATH"
}

# --- new: interactive domain / cert collection --------------------------
collect_tls_settings() {
	# Already fully specified via env vars -> nothing to ask.
	if [ -n "$PANEL_TLS_CERT" ] && [ -n "$PANEL_TLS_KEY" ]; then
		[ -f "$PANEL_TLS_CERT" ] || die "PANEL_TLS_CERT not found: $PANEL_TLS_CERT"
		[ -f "$PANEL_TLS_KEY" ]  || die "PANEL_TLS_KEY not found: $PANEL_TLS_KEY"
		return
	fi

	if [ "$NONINTERACTIVE" = "1" ] || [ ! -e /dev/tty ]; then
		log "non-interactive run and no PANEL_TLS_CERT/PANEL_TLS_KEY set; a self-signed certificate will be used"
		return
	fi

	if [ -z "$PANEL_DOMAIN" ]; then
		if ask_yes_no "Do you already have a domain name pointed at this server?" "n"; then
			PANEL_DOMAIN="$(ask "Domain name (e.g. panel.example.com)")"
		fi
	fi

	if [ -n "$PANEL_DOMAIN" ] && ask_yes_no "Do you already have a TLS certificate for $PANEL_DOMAIN (e.g. from Let's Encrypt/certbot)?" "y"; then
		local guess_cert="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"
		local guess_key="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
		PANEL_TLS_CERT="$(ask "Path to fullchain/certificate" "$guess_cert")"
		PANEL_TLS_KEY="$(ask "Path to private key" "$guess_key")"
		[ -f "$PANEL_TLS_CERT" ] || die "certificate not found: $PANEL_TLS_CERT"
		[ -f "$PANEL_TLS_KEY" ]  || die "private key not found: $PANEL_TLS_KEY"
	fi
}

# --- new: generate self-signed cert if nothing else was supplied -------
setup_tls() {
	install -d -m 0755 "$CONFIG_DIR"

	local cert_dst="$CONFIG_DIR/tls.crt"
	local key_dst="$CONFIG_DIR/tls.key"

	if [ -n "$PANEL_TLS_CERT" ] && [ -n "$PANEL_TLS_KEY" ]; then
		log "using provided certificate for ${PANEL_DOMAIN:-<no domain set>}"
		ln -sf "$PANEL_TLS_CERT" "$cert_dst"
		ln -sf "$PANEL_TLS_KEY" "$key_dst"
	else
		log "creating self-signed TLS certificate: $cert_dst"
		local cn="${PANEL_DOMAIN:-$(curl -fsSL https://ifconfig.me || hostname -f || echo localhost)}"
		openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
			-keyout "$key_dst" -out "$cert_dst" \
			-subj "/CN=${cn}" >/dev/null 2>&1
		chmod 0600 "$key_dst"
	fi
}

write_panel_env() {
	local user pass
	user="admin$(openssl rand -hex 3)"
	pass="$(openssl rand -hex 16)"

	install -d -m 0755 "$CONFIG_DIR"
	cat > "$PANEL_ENV_PATH" <<EOF
OLCRTC_MANAGER_USER='${user}'
OLCRTC_MANAGER_PASS='${pass}'
OLCRTC_MANAGER_TLS_CERT='${CONFIG_DIR}/tls.crt'
OLCRTC_MANAGER_TLS_KEY='${CONFIG_DIR}/tls.key'
EOF
	chmod 0600 "$PANEL_ENV_PATH"
	log "created panel env: $PANEL_ENV_PATH"
	log "Username: $user"
	log "Password: $pass"
}

install_service() {
	log "installing systemd service"
	cat > /etc/systemd/system/olcrtc-manager.service <<EOF
[Unit]
Description=OlcRTC Manager Panel
Documentation=https://github.com/BigDaddy3334/olcrtc-manager-panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=OLCRTC_PATH=/usr/local/bin/olcrtc
Environment=OLCRTC_MANAGER_ADDR=$PANEL_ADDR
EnvironmentFile=-$PANEL_ENV_PATH
ExecStart=/usr/local/bin/olcrtc-manager -config $CONFIG_PATH
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
KillSignal=SIGTERM
TimeoutStopSec=10s

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now olcrtc-manager
}

# --- new: certbot renewal hook so the panel picks up renewed certs -----
install_renew_hook() {
	[ -n "$PANEL_TLS_CERT" ] || return 0
	[ -d /etc/letsencrypt/renewal-hooks/deploy ] || return 0

	cat > /etc/letsencrypt/renewal-hooks/deploy/olcrtc-manager.sh <<'EOF'
#!/bin/bash
systemctl restart olcrtc-manager
EOF
	chmod +x /etc/letsencrypt/renewal-hooks/deploy/olcrtc-manager.sh
	log "installed certbot renewal hook to restart the panel on cert renewal"
}

sync_sources() {
	local src="$1"
	rm -rf "$INSTALL_SRC_DIR"
	mkdir -p "$INSTALL_SRC_DIR"
	tar --exclude='.git' --exclude='node_modules' -C "$src" -cf - . | tar -C "$INSTALL_SRC_DIR" -xf -
}

main() {
	need_root
	install_packages
	install_go

	local work panel_src olcrtc_src
	work="$(mktemp -d /tmp/olcrtc-manager-install.XXXXXX)"
	trap 'rm -rf "$work"' EXIT
	panel_src="$work/panel"
	olcrtc_src="$work/olcrtc"

	clone_repo "$OLCRTC_REPO" "$OLCRTC_REF" "$olcrtc_src"
	clone_repo "$PANEL_REPO" "$PANEL_REF" "$panel_src"
	build_olcrtc "$olcrtc_src"
	build_manager "$panel_src"
	write_config_if_missing

	collect_tls_settings
	# if the user gave us a real domain, listen on all interfaces so it's
	# actually reachable; otherwise keep the previous localhost-only default
	if [ -n "$PANEL_DOMAIN" ] && [ "$PANEL_ADDR" = "127.0.0.1" ]; then
		PANEL_ADDR="0.0.0.0"
	fi
	setup_tls
	write_panel_env
	install_renew_hook

	install_service
	sync_sources "$panel_src"

	log "done"
	log "service: systemctl status olcrtc-manager"
	if [ -n "$PANEL_DOMAIN" ]; then
		log "Access URL: https://${PANEL_DOMAIN}:${PANEL_PORT}/admin"
	else
		local ip
		ip="$(curl -fsSL https://ifconfig.me || echo "<server-ip>")"
		log "Access URL: https://${ip}:${PANEL_PORT}/admin"
		log "TLS uses a self-signed certificate; browsers will warn until you supply a real one (PANEL_DOMAIN + PANEL_TLS_CERT/PANEL_TLS_KEY)"
	fi
}

main "$@"
