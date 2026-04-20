#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_REPO="${CERT_REPO:-/Users/muskansethi/Documents/GitHub/whatsapp-clone}"
CERT_DIR="${CERT_DIR:-$CERT_REPO/data/certs}"
DOWNLOAD_DIR="$CERT_DIR/download"

RUN_DIR="${RUN_DIR:-$ROOT_DIR/.run}"
HTTP_PID_FILE="$RUN_DIR/syncv3-http.pid"
HTTPS_PID_FILE="$RUN_DIR/syncv3-https.pid"
CERT_PID_FILE="$RUN_DIR/certs-download.pid"
HTTP_LOG_FILE="$RUN_DIR/syncv3-http.log"
HTTPS_LOG_FILE="$RUN_DIR/syncv3-https.log"
CERT_LOG_FILE="$RUN_DIR/certs-download.log"

SYNCV3_BIN="${SYNCV3_BIN:-$ROOT_DIR/syncv3}"
SYNCV3_SECRET_FILE="${SYNCV3_SECRET_FILE:-$ROOT_DIR/.secret}"

SYNCV3_HTTP_BINDADDR="${SYNCV3_HTTP_BINDADDR:-0.0.0.0:8008}"
SYNCV3_HTTPS_BINDADDR="${SYNCV3_HTTPS_BINDADDR:-0.0.0.0:8448}"
CERT_SERVER_PORT="${CERT_SERVER_PORT:-9999}"

# Required DB setting for both instances (can be overridden per mode).
SYNCV3_DB_HTTP="${SYNCV3_DB_HTTP:-${SYNCV3_DB:-}}"
SYNCV3_DB_HTTPS="${SYNCV3_DB_HTTPS:-${SYNCV3_DB:-}}"
SYNCV3_DB_HTTP_NAME="${SYNCV3_DB_HTTP_NAME:-syncv3_http}"
SYNCV3_DB_HTTPS_NAME="${SYNCV3_DB_HTTPS_NAME:-syncv3_https}"

resolve_ip() {
    local ip=""
    local iface=""

    if [[ -n "${1:-}" ]]; then
        echo "$1"
        return 0
    fi

    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "$iface" ]]; then
        ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    fi

    if [[ -z "$ip" ]]; then
        ip="$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
    fi

    if [[ -z "$ip" ]]; then
        echo "ERROR: could not detect local IP address" >&2
        exit 1
    fi

    echo "$ip"
}

stop_pid_if_running() {
    local pid_file="$1"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(tr -d '[:space:]' < "$pid_file")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" || true
        fi
        rm -f "$pid_file"
    fi
}

ensure_tools() {
    local missing=0
    for t in openssl curl go python3 psql createdb lsof; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "ERROR: required tool not found: $t" >&2
            missing=1
        fi
    done
    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

ensure_db_exists() {
    local db_name="$1"
    if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" | grep -q '^1$'; then
        createdb "$db_name"
    fi
}

ensure_db_connection_strings() {
    local user
    user="$(whoami)"

    if [[ -z "$SYNCV3_DB_HTTP" ]]; then
        ensure_db_exists "$SYNCV3_DB_HTTP_NAME"
        SYNCV3_DB_HTTP="user=${user} dbname=${SYNCV3_DB_HTTP_NAME} sslmode=disable"
    fi

    if [[ -z "$SYNCV3_DB_HTTPS" ]]; then
        ensure_db_exists "$SYNCV3_DB_HTTPS_NAME"
        SYNCV3_DB_HTTPS="user=${user} dbname=${SYNCV3_DB_HTTPS_NAME} sslmode=disable"
    fi
}

ensure_secret_file() {
    if [[ ! -f "$SYNCV3_SECRET_FILE" ]]; then
        openssl rand -hex 32 > "$SYNCV3_SECRET_FILE"
    fi
}

ensure_ca() {
    mkdir -p "$CERT_DIR" "$DOWNLOAD_DIR"

    if [[ ! -f "$CERT_DIR/ca.key" || ! -f "$CERT_DIR/ca.crt" ]]; then
        openssl genrsa -out "$CERT_DIR/ca.key" 4096
        openssl req -x509 -new -nodes \
            -key "$CERT_DIR/ca.key" \
            -sha256 -days 3650 \
            -out "$CERT_DIR/ca.crt" \
            -subj "/C=US/ST=NA/L=NA/O=WhatsAppClone/OU=Dev/CN=WhatsAppClone-CA"
    fi
}

ensure_server_cert_for_ip() {
    local ip="$1"
    local key_file="$CERT_DIR/synapse-${ip}.key"
    local csr_file="$CERT_DIR/synapse-${ip}.csr"
    local crt_file="$CERT_DIR/synapse-${ip}.crt"
    local ext_file="$CERT_DIR/synapse-${ip}.ext"

    if [[ ! -f "$crt_file" ]] || ! openssl x509 -in "$crt_file" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${ip}"; then
        openssl genrsa -out "$key_file" 2048
        openssl req -new \
            -key "$key_file" \
            -out "$csr_file" \
            -subj "/C=US/ST=NA/L=NA/O=WhatsAppClone/OU=Dev/CN=${ip}"

        cat > "$ext_file" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
IP.1=${ip}
EOF

        openssl x509 -req \
            -in "$csr_file" \
            -CA "$CERT_DIR/ca.crt" \
            -CAkey "$CERT_DIR/ca.key" \
            -CAcreateserial \
            -out "$crt_file" \
            -days 825 \
            -sha256 \
            -extfile "$ext_file"

        rm -f "$csr_file" "$ext_file"
    fi

    cp "$CERT_DIR/ca.crt" "$DOWNLOAD_DIR/synapse-ca-${ip}.crt"
}

build_syncv3() {
    # Always rebuild to avoid stale binaries with wrong CPU architecture.
    (cd "$ROOT_DIR" && go build -o "$SYNCV3_BIN" ./cmd/syncv3)
}

http_code() {
    local url="$1"
    local tls_opt="${2:-}"
    if [[ "$tls_opt" == "-k" ]]; then
        curl -sk --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' "$url" || true
    else
        curl -s --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' "$url" || true
    fi
}

wait_for_200() {
    local url="$1"
    local tls_opt="${2:-}"
    local attempts="${3:-40}"
    local code=""

    for _ in $(seq 1 "$attempts"); do
        code="$(http_code "$url" "$tls_opt")"
        if [[ "$code" == "200" ]]; then
            echo "$code"
            return 0
        fi
        perl -e 'select(undef, undef, undef, 0.25);'
    done

    echo "$code"
    return 1
}

start_cert_download_server() {
    local ip="$1"
    local stale_pids

    stale_pids="$(lsof -ti tcp:"$CERT_SERVER_PORT" || true)"
    if [[ -n "$stale_pids" ]]; then
        # Clear any stale listener so this script can control the cert endpoint.
        kill $stale_pids 2>/dev/null || true
    fi

    stop_pid_if_running "$CERT_PID_FILE"

    nohup python3 -m http.server "$CERT_SERVER_PORT" \
        --bind "$ip" \
        --directory "$DOWNLOAD_DIR" \
        > "$CERT_LOG_FILE" 2>&1 &
    echo $! > "$CERT_PID_FILE"
}

start_syncv3_http() {
    local ip="$1"

    stop_pid_if_running "$HTTP_PID_FILE"

    nohup env \
        SYNCV3_SECRET="$(cat "$SYNCV3_SECRET_FILE")" \
        SYNCV3_SERVER="http://${ip}:8080" \
        SYNCV3_BINDADDR="$SYNCV3_HTTP_BINDADDR" \
        SYNCV3_DB="$SYNCV3_DB_HTTP" \
        "$SYNCV3_BIN" \
        > "$HTTP_LOG_FILE" 2>&1 &
    echo $! > "$HTTP_PID_FILE"
}

start_syncv3_https() {
    local ip="$1"
    local cert_file="$CERT_DIR/synapse-${ip}.crt"
    local key_file="$CERT_DIR/synapse-${ip}.key"

    stop_pid_if_running "$HTTPS_PID_FILE"

    nohup env \
        SSL_CERT_FILE="$CERT_DIR/ca.crt" \
        SYNCV3_SECRET="$(cat "$SYNCV3_SECRET_FILE")" \
        SYNCV3_SERVER="https://${ip}:8480" \
        SYNCV3_BINDADDR="$SYNCV3_HTTPS_BINDADDR" \
        SYNCV3_DB="$SYNCV3_DB_HTTPS" \
        SYNCV3_TLS_CERT="$cert_file" \
        SYNCV3_TLS_KEY="$key_file" \
        "$SYNCV3_BIN" \
        > "$HTTPS_LOG_FILE" 2>&1 &
    echo $! > "$HTTPS_PID_FILE"
}

wait_for_pid_exit() {
    local pid_file="$1"
    local name="$2"

    local pid
    pid="$(tr -d '[:space:]' < "$pid_file")"
    if [[ -z "$pid" ]]; then
        echo "ERROR: ${name} PID file was empty" >&2
        exit 1
    fi

    perl -e 'select(undef, undef, undef, 0.5);'
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: ${name} exited immediately" >&2
        exit 1
    fi
}

print_status() {
    local ip="$1"

    local syn_http_url="http://${ip}:8080/_matrix/static/"
    local syn_https_url="https://${ip}:8480/_matrix/static/"
    local cert_url="http://${ip}:${CERT_SERVER_PORT}/synapse-ca-${ip}.crt"
    local sync_http_url="http://${ip}:${SYNCV3_HTTP_BINDADDR##*:}/client/"
    local sync_https_url="https://${ip}:${SYNCV3_HTTPS_BINDADDR##*:}/client/"

    echo ""
    echo "IP=${ip}"
    echo "Synapse:" 
    echo "  HTTP  : ${syn_http_url}" 
    echo "  HTTPS : ${syn_https_url}" 
    echo "  CERT  : ${cert_url}" 
    echo "Sliding Sync:"
    echo "  HTTP  : ${sync_http_url}"
    echo "  HTTPS : ${sync_https_url}"
    echo ""
}

stop_all() {
    stop_pid_if_running "$HTTP_PID_FILE"
    stop_pid_if_running "$HTTPS_PID_FILE"
    stop_pid_if_running "$CERT_PID_FILE"
}

main() {
    mkdir -p "$RUN_DIR"

    local mode="${1:-start}"
    case "$mode" in
        stop)
            stop_all
            echo "Stopped syncv3 HTTP/HTTPS and cert server."
            exit 0
            ;;
        start)
            ;;
        *)
            echo "Usage: $0 [start|stop] [ip]" >&2
            exit 1
            ;;
    esac

    local ip
    ip="$(resolve_ip "${2:-}")"

    ensure_tools
    ensure_secret_file
    ensure_ca
    ensure_server_cert_for_ip "$ip"
    ensure_db_connection_strings
    build_syncv3

    start_cert_download_server "$ip"

    local code
    code="$(wait_for_200 "http://${ip}:8080/_matrix/static/")" || {
        echo "ERROR: http://${ip}:8080/_matrix/static/ did not return 200 (last=${code})" >&2
        exit 1
    }
    code="$(wait_for_200 "https://${ip}:8480/_matrix/static/" "-k")" || {
        echo "ERROR: https://${ip}:8480/_matrix/static/ did not return 200 (last=${code})" >&2
        exit 1
    }

    start_syncv3_http "$ip"
    start_syncv3_https "$ip"

    wait_for_pid_exit "$HTTP_PID_FILE" "syncv3 HTTP"
    wait_for_pid_exit "$HTTPS_PID_FILE" "syncv3 HTTPS"

    local cert_code
    cert_code="$(wait_for_200 "http://${ip}:${CERT_SERVER_PORT}/synapse-ca-${ip}.crt")" || {
        echo "ERROR: cert URL did not return 200 (last=${cert_code})" >&2
        exit 1
    }

    print_status "$ip"
    echo "Logs:"
    echo "  $HTTP_LOG_FILE"
    echo "  $HTTPS_LOG_FILE"
    echo "  $CERT_LOG_FILE"
    echo ""
    echo "Use '$0 stop' to stop all background services."
}

main "$@"
