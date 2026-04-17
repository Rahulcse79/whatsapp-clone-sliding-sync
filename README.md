# WhatsApp Clone - Sliding Sync

A high-performance real-time messaging backend built with Go, implementing the Sliding Sync protocol for efficient, scalable chat synchronization — inspired by WhatsApp's seamless messaging experience.

## Features

- **Sliding Window Sync** — Efficiently syncs only the data clients need, reducing bandwidth and latency
- **Real-Time Messaging** — Instant message delivery with long-polling support
- **End-to-End Encryption Support** — Device list tracking and to-device message delivery for E2EE
- **Room Management** — Create, join, and manage chat rooms with full state tracking
- **Typing Indicators & Read Receipts** — Real-time presence and read status
- **Scalable Architecture** — PostgreSQL-backed storage with connection pooling
- **Observability** — Built-in Prometheus metrics, OTLP tracing, and Sentry error reporting
- **Profiling Tools** — CPU, memory, and request tracing via pprof
- **Docker Support** — Ready-to-deploy containerized setup
- **TLS Support** — Optional HTTPS with custom certificates

## Tech Stack

- **Language:** Go
- **Database:** PostgreSQL 13+
- **Containerization:** Docker
- **Monitoring:** Prometheus, Grafana, OTLP
- **Error Tracking:** Sentry
- **Frontend Client:** Vanilla JavaScript (included stub client)

## Project Structure

```
├── cmd/syncv3/          # Application entrypoint
├── sync2/               # Upstream sync poller and v2 protocol handling
├── sync3/               # Sliding sync (v3) core logic
│   ├── caches/          # In-memory caching layer
│   ├── extensions/      # Protocol extensions (typing, receipts, etc.)
│   └── handler/         # HTTP request handlers
├── state/               # Database tables and persistent storage
│   └── migrations/      # Schema migrations
├── internal/            # Shared utilities and data structures
├── pubsub/              # Internal publish/subscribe messaging
├── sqlutil/             # SQL helper utilities
├── client/              # Built-in web client (HTML/JS/CSS)
├── grafana/             # Grafana dashboard configuration
├── tests-e2e/           # End-to-end test suite
├── tests-integration/   # Integration test suite
└── testutils/           # Shared test helpers
```

## Prerequisites

- Go 1.21+
- PostgreSQL 13+
- Docker (optional, for containerized deployment)

## Getting Started

### 1. Database Setup

```bash
createdb syncv3
echo -n "$(openssl rand -hex 32)" > .secret
```

The `.secret` file must remain the same for the lifetime of the database.

### 2. Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SYNCV3_SERVER` | Yes | — | Destination homeserver URL |
| `SYNCV3_DB` | Yes | — | PostgreSQL connection string |
| `SYNCV3_SECRET` | Yes | — | Secret key to encrypt access tokens |
| `SYNCV3_BINDADDR` | No | `0.0.0.0:8008` | Address and port to listen on |
| `SYNCV3_TLS_CERT` | No | — | Path to TLS certificate file |
| `SYNCV3_TLS_KEY` | No | — | Path to TLS key file |
| `SYNCV3_PPROF` | No | — | Bind address for pprof (e.g. `:6060`) |
| `SYNCV3_PROM` | No | — | Bind address for Prometheus metrics |
| `SYNCV3_OTLP_URL` | No | — | OTLP HTTP endpoint for tracing |
| `SYNCV3_OTLP_USERNAME` | No | — | OTLP Basic auth username |
| `SYNCV3_OTLP_PASSWORD` | No | — | OTLP Basic auth password |
| `SYNCV3_SENTRY_DSN` | No | — | Sentry DSN for error reporting |
| `SYNCV3_LOG_LEVEL` | No | `info` | Log level (trace, debug, info, warn, error, fatal) |
| `SYNCV3_MAX_DB_CONN` | No | — | Max database connections (0 = unlimited) |

### 3. Run the Server

**From source:**

```bash
CGO_ENABLED=0 go build ./cmd/syncv3

SYNCV3_SECRET=$(cat .secret) \
SYNCV3_SERVER="https://your-homeserver.com" \
SYNCV3_DB="user=$(whoami) dbname=syncv3 sslmode=disable password='YOUR_PASSWORD'" \
SYNCV3_BINDADDR=0.0.0.0:8008 \
./syncv3
```

**With Docker:**

```bash
docker run --rm \
  -e "SYNCV3_SERVER=https://your-homeserver.com" \
  -e "SYNCV3_SECRET=$(cat .secret)" \
  -e "SYNCV3_BINDADDR=:8008" \
  -e "SYNCV3_DB=user=$(whoami) dbname=syncv3 sslmode=disable host=host.docker.internal password='YOUR_PASSWORD'" \
  -p 8008:8008 \
  ghcr.io/matrix-org/sliding-sync:latest
```

### 4. Try the Built-in Client

Visit `http://localhost:8008/client/` in your browser, paste an access token, and hit Sync.

## Monitoring

### Prometheus Metrics

Enable metrics by setting `SYNCV3_PROM=:2112`, then scrape `GET /metrics`.

Example `prometheus.yml`:

```yaml
global:
    scrape_interval: 30s
    scrape_timeout: 10s
scrape_configs:
    - job_name: sliding-sync
      static_configs:
       - targets: ["host.docker.internal:2112"]
```

### Useful Metrics

| Metric | Description |
|---|---|
| `sliding_sync_poller_num_payloads` | Payload rate from pollers to API processes |
| `sliding_sync_poller_num_pollers` | Active /sync v2 pollers count |
| `sliding_sync_api_num_active_conns` | Active sliding sync connections |
| `sliding_sync_poller_process_duration_secs` | Time to process /sync v2 responses |
| `sliding_sync_api_process_duration_secs` | Time to calculate sliding sync responses |

## Profiling

Enable pprof by setting `SYNCV3_PPROF=:6060`.

```bash
# Trace a slow request (20s capture window)
wget -O trace.pprof 'http://localhost:6060/debug/pprof/trace?seconds=20'
go tool trace trace.pprof

# Memory profiling
wget -O heap.pprof 'http://localhost:6060/debug/pprof/heap'
go tool pprof heap.pprof

# CPU profiling
wget -O profile.pprof 'http://localhost:6060/debug/pprof/profile?seconds=10'
go tool pprof -http :5656 profile.pprof
```

## Development

### Build

```bash
CGO_ENABLED=0 go build ./cmd/syncv3
```

### Run Tests

```bash
# Unit and integration tests
go test -p 1 -count 1 $(go list ./... | grep -v tests-e2e) -timeout 120s

# End-to-end tests
export SYNCV3_SECRET=foobar
export SYNCV3_SERVER=http://localhost:8888
export SYNCV3_DB="user=$(whoami) dbname=syncv3_test sslmode=disable"
go build ./cmd/syncv3 && dropdb syncv3_test && createdb syncv3_test && cd tests-e2e && ./run-tests.sh -count=1 .
```

## Database Notes

Most data is a cached copy from the upstream homeserver. The following tables contain critical E2EE data that cannot be recovered if lost:

- `syncv3_device_list_updates` — Device list changes
- `syncv3_to_device_messages` — To-device messages for key exchange

Deleting these tables may cause messages to become undecryptable.

## License

This project is licensed under the MIT License. See the LICENSE file for details.

## Author

**Rahul Singh**
