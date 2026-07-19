<p align="right">
  <a href="./README.md">English</a> | <a href="./README.zh-TW.md">繁體中文</a>
</p>

# dynip

A Zig-based DDNS background service.

`dynip` periodically checks the current public IP and updates configured DDNS providers:

- [Afraid.org](https://freedns.afraid.org/)
- [Dynu](https://www.dynu.com/)
- [No-IP](https://www.noip.com/)
- [Cloudflare DNS](https://www.cloudflare.com/)

It supports layered configuration loading, structured logging, HTTP request tracing, and duplicate-update prevention backed by either Redis or in-process memory.

## Features

- Load configuration from `app.json`
- Override config with `.env`
- Override both again with environment variables
- Run as a long-running scheduled service
- Update Cloudflare / Afraid / Dynu / No-IP independently
- Detect IPv4 and IPv6 independently; an unavailable family does not stop the other family
- Rotate across multiple public IP sources
- Write log files by level
- Record HTTP request/response logs
- Track provider-level DDNS state in Redis
- Retry failed providers without re-updating providers that are already current

## Quick Start

1. Create `app.json` or `.env` with at least one enabled provider.
2. Enable Redis if you want durable provider state and retry tracking.
3. Run the service:

```bash
zig build run
```

Run with an explicit config path:

```bash
zig build run -- service --config app.json
```

## DDNS Update Model

On each update cycle, `dynip`:

1. Checks whether the current time is inside the maintenance window `02:00` to `02:04` local time.
2. Fetches the current public IP from one of the built-in public IP sources.
3. Treats that public IP as the desired IP for every enabled DDNS provider.
4. When Redis is enabled, reconciles each provider independently against its stored provider state.
5. Updates only providers whose recorded `current_ip` is not the desired IP and whose retry backoff has expired.
6. Records provider success or failure, including retry count, next retry time, and last error.
7. When Redis is disabled, falls back to the in-memory TTL duplicate-prevention path.

Example:

```text
Public IP: 1.2.3.4

Afraid current_ip = 1.2.3.4  -> skipped
Dynu   current_ip = 1.2.3.4  -> skipped
No-IP  current_ip = 5.6.7.8  -> updated or retried
```

This means one failed provider does not force all providers to be updated again.

## Project Layout

This project now follows a more typical Zig application layout:

- `src/main.zig`: the thinnest possible executable entry point. It only forwards startup control to the CLI layer.
- `src/cli.zig`: the application bootstrap layer. It parses CLI arguments, initializes logging, installs signal handlers, loads config, and starts the long-running scheduler.
- `src/root.zig`: the shared module root. It re-exports the main internal modules and also acts as the unit test aggregation entry point for `zig build test`.
- `src/base/config.zig`: configuration loading logic. It reads `app.json`, then `.env`, then process environment variables, with later sources overriding earlier ones.
- `src/core/ddns.zig`: the main DDNS workflow. It fetches the current public IP, reconciles provider state, and updates enabled providers.
- `src/io/redis.zig`: the Redis integration layer used by DDNS provider state and legacy observer keys.
- `src/core/scheduler.zig`: the fixed-interval background loop that repeatedly triggers refresh work.
- `src/io/logging.zig`: the structured logging layer that handles console and file logging behavior.
- `src/io/http.zig`: shared HTTP fetch and response logging helpers.
- `build.zig`: the Zig build definition. It wires together the executable, the `run` step, and the test step.
- `build.ps1` / `build.bat`: Windows-oriented helper scripts for local build flows.
- `control.sh`: a helper script used mainly for container or deployment-oriented workflows.
- `Dockerfile`: the container image build definition.

If you are coming from other ecosystems, the rough mental model is:

- `main.zig` is the process entry point
- `cli.zig` is the application startup layer
- `root.zig` is the shared package root
- `build.zig` is both the build script and task entry definition

## Requirements

- Zig `0.17.0-dev` or later
- Network access to public IP sources
- Network access to the DDNS providers you enable
- Redis only if you want Redis-backed duplicate prevention

## Configuration

Configuration is loaded in this order:

1. `app.json`
2. `.env`
3. process environment variables

Later sources override earlier ones.

### Example `app.json`

```json
{
  "cloudflare": {
    "enabled": false,
    "api_token": "",
    "zone_id": "",
    "hostnames": ["home.example.com"],
    "proxied": false,
    "ttl": 1,
    "record_comment": "managed-by:dynip",
    "managed_record_comment": "managed-by:dynip",
    "http_retry_count": 2
  },
  "afraid": {
    "enabled": true,
    "url": "https://freedns.afraid.org",
    "path": "/dynamic/update.php?",
    "token": ""
  },
  "dynu": {
    "enabled": true,
    "url": "https://api.dynu.com/nic/update",
    "username": "",
    "password": ""
  },
  "noip": {
    "enabled": true,
    "url": "https://dynupdate.no-ip.com/nic/update",
    "username": "",
    "password": "",
    "hostnames": []
  },
  "ddns": {
    "refresh_interval_seconds": 60,
    "dedupe_ttl_seconds": 86400,
    "ipv4_provider": "auto",
    "ipv6_provider": "auto",
    "redis": {
      "enabled": true,
      "addr": "localhost:6379",
      "account": "",
      "password": "",
      "db": 0
    }
  },
  "logging": {
    "console_level": "info",
    "file_level": "info",
    "seq": {
      "enabled": false,
      "level": "warn",
      "server_url": "",
      "api_key": ""
    }
  }
}
```

### Provider Configuration Shape

### Cloudflare DNS

Cloudflare uses an API Token with DNS Edit permission for the configured zone. Each configured hostname is reconciled independently: IPv4 updates an A record, IPv6 updates an AAAA record, an unchanged record is skipped, and an existing record is PATCHed only at its IP content so its Cloudflare-side proxy, TTL, comments, and tags are preserved. Missing records are created with the configured proxied value, TTL, and `record_comment`; TTL 1 means Cloudflare Automatic.

Set both `record_comment` and `managed_record_comment` to a unique value such as `managed-by:dynip` when more than one DDNS instance may use the same hostname. The selector makes this instance update only records it owns. If it finds multiple matching records, it stops safely instead of choosing an arbitrary one. `http_retry_count` retries transient Cloudflare rate-limit (429), server (5xx), and transport failures with exponential backoff.

### Per-family public IP providers

`ddns.ipv4_provider` and `ddns.ipv6_provider` are independent. Each accepts `auto` (STUN/Cloudflare Trace fallback), `none`, `stun`, `cloudflare_trace`, `url:<https-url>`, `file:<absolute-path>`, or `static:<ip>`. Use `none` on an IPv4-only or IPv6-only network; it deliberately skips that family without reporting a refresh failure. `file:` reads the first non-empty, non-comment line and `static:` is intended for deterministic tests.

All three DDNS providers use the same top-level structure:

- `enabled`
- `url`
- provider-specific authentication fields

Provider-specific fields:

- `afraid`: `path`, `token`
- `dynu`: `username`, `password`
- `noip`: `username`, `password`, `hostnames`

### Redis State And Retry Behavior

When `ddns.redis.enabled = true`:

- the desired public IP is stored separately in `DDNS:DesiredIP:ipv4` and `DDNS:DesiredIP:ipv6`
- each provider has one Redis hash per family, for example `DDNS:Provider:cloudflare:ipv4` and `DDNS:Provider:cloudflare:ipv6`
- provider hashes track `current_ip`, `desired_ip`, `status`, `retry_count`, `next_retry_at`, `last_error`, and `updated_at`
- failed providers are retried with exponential backoff, while successful providers are skipped until the desired IP changes
- observer and dedupe keys are family-isolated, for example `MyPublicIP:ipv4`, `MyPublicIP:ipv4:1.2.3.4`, and `MyPublicIP:cloudflare:ipv4`

Provider hash example:

```text
DDNS:Provider:noip
  current_ip    = 5.6.7.8
  desired_ip    = 1.2.3.4
  status        = failed
  retry_count   = 2
  next_retry_at = 1781435400
  last_error    = UnexpectedNoIpResponse
  updated_at    = 1781435100
```

Retry delay starts at `30` seconds and backs off up to `15` minutes. If the public IP changes again, the provider is attempted immediately for the new desired IP instead of waiting for the old retry window.

When `ddns.redis.enabled = false`:

- duplicate-prevention state is stored in local process memory
- the same TTL logic still applies
- all duplicate-prevention state is lost after process restart

`ddns.dedupe_ttl_seconds` still controls the TTL for legacy observer keys and the desired IP key. Provider hashes are kept without a TTL so the last provider state remains available for troubleshooting.

### Supported Environment Variables

#### Cloudflare DNS

- `CLOUDFLARE_ENABLED`
- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ZONE_ID`
- `CLOUDFLARE_HOSTNAMES` (JSON string array)
- `CLOUDFLARE_PROXIED`
- `CLOUDFLARE_TTL`
- `CLOUDFLARE_RECORD_COMMENT`
- `CLOUDFLARE_MANAGED_RECORD_COMMENT`
- `CLOUDFLARE_HTTP_RETRY_COUNT`

#### [Afraid.org](https://freedns.afraid.org/)

- `AFRAID_ENABLED`
- `AFRAID_URL`
- `AFRAID_PATH`
- `AFRAID_TOKEN`

#### [Dynu](https://www.dynu.com/)

- `DYNU_ENABLED`
- `DYNU_URL`
- `DYNU_USERNAME`
- `DYNU_PASSWORD`

#### [No-IP](https://www.noip.com/)

- `NOIP_ENABLED`
- `NOIP_URL`
- `NOIP_USERNAME`
- `NOIP_PASSWORD`
- `NOIP_HOSTNAMES`

#### DDNS / Redis

- `REDIS_ENABLED`
- `REDIS_ADDR`
- `REDIS_ACCOUNT`
- `REDIS_PASSWORD`
- `REDIS_DB`
- `DDNS_DEDUPE_TTL_SECONDS`
- `DDNS_REFRESH_INTERVAL_SECONDS`
- `DDNS_IPV4_PROVIDER`
- `DDNS_IPV6_PROVIDER`
- `LOG_CONSOLE_LEVEL`
- `LOG_FILE_LEVEL`
- `LOG_SEQ_ENABLED`
- `LOG_SEQ_LEVEL`
- `LOG_SEQ_SERVER_URL`
- `LOG_SEQ_API_KEY`

### Example `.env`

```dotenv
CLOUDFLARE_ENABLED=true
CLOUDFLARE_API_TOKEN=<cloudflare-api-token>
CLOUDFLARE_ZONE_ID=<cloudflare-zone-id>
CLOUDFLARE_HOSTNAMES=["home.example.com"]
CLOUDFLARE_PROXIED=false
CLOUDFLARE_TTL=1

AFRAID_ENABLED=true
AFRAID_URL=https://freedns.afraid.org
AFRAID_PATH=/dynamic/update.php?
AFRAID_TOKEN=<set-in-env>

DYNU_ENABLED=true
DYNU_URL=https://api.dynu.com/nic/update
DYNU_USERNAME=<set-in-env>
DYNU_PASSWORD=<set-in-env>

NOIP_ENABLED=true
NOIP_URL=https://dynupdate.no-ip.com/nic/update
NOIP_USERNAME=<set-in-env>
NOIP_PASSWORD=<set-in-env>
NOIP_HOSTNAMES=["example.ddns.net","example.zapto.org"]

REDIS_ADDR=127.0.0.1:6379
REDIS_ACCOUNT=<optional>
REDIS_PASSWORD=<set-if-needed>

REDIS_ENABLED=false
DDNS_REFRESH_INTERVAL_SECONDS=60
DDNS_DEDUPE_TTL_SECONDS=86400
DDNS_IPV4_PROVIDER=auto
DDNS_IPV6_PROVIDER=auto

LOG_CONSOLE_LEVEL=info
LOG_FILE_LEVEL=info
LOG_SEQ_ENABLED=false
LOG_SEQ_LEVEL=warn
```

## Usage

### Run Tests

```bash
zig build test
```

If the project is on a mounted WSL path such as `/mnt/d/...`, use Linux-native cache directories:

```bash
zig build test \
  --cache-dir /tmp/dynip_local_cache \
  --global-cache-dir /tmp/dynip_global_cache
```

### Run the Service

Run with the default config path:

```bash
zig build run
```

Run with an explicit config path:

```bash
zig build run -- service --config app.json
```

Show help:

```bash
zig build run -- --help
```

Run the compiled binary directly:

```bash
dynip service --config app.json
```

## Web Dashboard

The service includes an integrated Web Dashboard to monitor DDNS status. By default, it is enabled and listens on port `9003`.

### Configuration

You can configure the Dashboard under the `"dashboard"` section in `app.json`:

```json
  "dashboard": {
    "enabled": true,
    "host": "0.0.0.0",
    "port": 9003
  }
```

Or override using environment variables:
- `DASHBOARD_ENABLED=true`
- `DASHBOARD_HOST=0.0.0.0`
- `DASHBOARD_PORT=9003`

If disabled (`"enabled": false`), no Web ports will be opened, and the service will only run the background scheduler.

## Operations

### Inspect Redis State

Check the current desired IP:

```bash
redis-cli GET DDNS:DesiredIP
```

Check one provider:

```bash
redis-cli HGETALL DDNS:Provider:noip
```

Check the legacy observer keys:

```bash
redis-cli GET MyPublicIP
redis-cli GET MyPublicIP:noip
```

### Common Cases

If one provider failed and others succeeded:

```text
status=failed
current_ip is not equal to desired_ip
next_retry_at is in the future
```

The service will skip providers that are already current and retry only the failed provider after `next_retry_at`.

If a provider never updates:

- confirm the provider is enabled and has all required credentials
- inspect `last_error`
- compare `current_ip` and `desired_ip`
- check whether `next_retry_at` is still in the future

If the service logs many Redis connections in one refresh cycle, that is unexpected. The Redis-enabled update path is designed to reuse one Redis session per refresh cycle.

## Logging

Logs are written to `log/`.

File naming pattern:

- `log/YYYY-MM-DD_dynip_info.log`
- `log/YYYY-MM-DD_dynip_warn.log`
- `log/YYYY-MM-DD_dynip_error.log`
- `log/YYYY-MM-DD_dynip_debug.log`

Current logging behavior includes:

- one log file per level per day
- daily rotation
- cleanup for logs older than `7` days
- formatted dump of the loaded runtime config on service startup
- provider response summaries
- HTTP request/response logs

## Public IP Sources

Built-in public IP sources:

- `STUN` (`stun.l.google.com:19302`) - UDP-based query
- `Cloudflare Trace` (`https://one.one.one.one/cdn-cgi/trace`) - HTTPS-based query

The starting source rotates between update cycles (STUN first or Cloudflare first) to balance reliability and firewall compatibility.

## Windows Build

From `cmd.exe`:

```bat
cd /d C:\dynip
build.bat
```

From PowerShell:

```powershell
Set-Location C:\dynip
powershell.exe -ExecutionPolicy Bypass -File .\build.ps1
```

The PowerShell build currently emits stripped ARM64 and ARMv7 Linux binaries into `zig-out\bin\`.

## Docker

`control.sh` is currently geared toward Docker-based workflows.

Common commands:

```bash
bash control.sh docker_build
bash control.sh docker_start
bash control.sh docker_stop
bash control.sh docker_restart
bash control.sh docker_update
```

Current assumptions:

- `control.sh`, `dynip_linux_arm64`, and `dynip_linux_armv7` are placed in the same directory for deployment
- `control.sh` does not build the binary on the production host
- `docker_build` packages the existing binaries with `Dockerfile`, which auto-selects the matching one via BuildKit's `TARGETARCH`/`TARGETVARIANT` (arm64 vs. armv7, e.g. Raspberry Pi 3)

Default names:

- image: `dynip-image`
- container: `dynip-container`
