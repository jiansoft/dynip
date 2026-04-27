<p align="right">
  <a href="./README.md">English</a> | <a href="./README.zh-TW.md">繁體中文</a>
</p>

# dynip

A Zig-based DDNS background service.

`dynip` periodically checks the current public IP and updates configured DDNS providers:

- [Afraid.org](https://freedns.afraid.org/)
- [Dynu](https://www.dynu.com/)
- [No-IP](https://www.noip.com/)

It supports layered configuration loading, structured logging, HTTP request tracing, and duplicate-update prevention backed by either Redis or in-process memory.

## Features

- Load configuration from `app.json`
- Override config with `.env`
- Override both again with environment variables
- Run as a long-running scheduled service
- Update Afraid / Dynu / No-IP independently
- Rotate across multiple public IP sources
- Write log files by level
- Record HTTP request/response logs
- Prevent duplicate updates with Redis or local memory

## How It Works

On each update cycle, `dynip`:

1. Checks whether the current time is inside the maintenance window `02:00` to `02:04` local time.
2. Fetches the current public IP from one of the built-in public IP sources.
3. Builds a key in the form `MyPublicIP:{ip}` to prevent duplicate updates.
4. Checks that key in Redis when `ddns.redis.enabled = true`, otherwise checks an in-memory TTL cache.
5. Skips the update if the key already exists.
6. Updates all enabled DDNS providers with complete credentials.
7. Stores the key after at least one provider update succeeds.

## Project Layout

This project now follows a more typical Zig application layout:

- `src/main.zig`: the thinnest possible executable entry point. It only forwards startup control to the CLI layer.
- `src/cli.zig`: the application bootstrap layer. It parses CLI arguments, initializes logging, installs signal handlers, loads config, and starts the long-running scheduler.
- `src/root.zig`: the shared module root. It re-exports the main internal modules and also acts as the unit test aggregation entry point for `zig build test`.
- `src/config.zig`: configuration loading logic. It reads `app.json`, then `.env`, then process environment variables, with later sources overriding earlier ones.
- `src/ddns.zig`: the main DDNS workflow. It fetches the current public IP, performs duplicate-prevention checks, and updates enabled providers.
- `src/redis.zig`: the Redis integration layer used by DDNS duplicate prevention.
- `src/scheduler.zig`: the fixed-interval background loop that repeatedly triggers refresh work.
- `src/logging.zig`: the structured logging layer that handles console and file logging behavior.
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

- Zig `0.16.0-dev.2979+e93834410` or a compatible nearby dev version
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
  "afraid": {
    "enabled": true,
    "url": "https://freedns.afraid.org",
    "path": "/dynamic/update.php?",
    "token": ""
  },
  "dyny": {
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
    "redis": {
      "enabled": true,
      "addr": "localhost:6379",
      "account": "",
      "password": "",
      "db": 0
    }
  }
}
```

### Provider Configuration Shape

All three DDNS providers use the same top-level structure:

- `enabled`
- `url`
- provider-specific authentication fields

Provider-specific fields:

- `afraid`: `path`, `token`
- `dyny`: `username`, `password`
- `noip`: `username`, `password`, `hostnames`

### Redis Duplicate Prevention

When `ddns.redis.enabled = true`:

- duplicate-prevention state is stored in Redis
- key format is `MyPublicIP:{ip}`
- the latest public IP is also stored in `MyPublicIP`
- successful updates write the key with `SETEX`

When `ddns.redis.enabled = false`:

- duplicate-prevention state is stored in local process memory
- the same TTL logic still applies
- all duplicate-prevention state is lost after process restart

### Supported Environment Variables

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

### Example `.env`

```dotenv
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

- `https://api.ipify.org`
- `https://ipconfig.io/ip`
- `https://ipinfo.io/ip`
- `https://ipv4.seeip.org`
- `https://api.myip.com`
- `https://api.bigdatacloud.net/data/client-ip`

The starting source rotates between update cycles instead of always beginning with the first one.

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

The PowerShell build currently emits a stripped ARM64 Linux binary into `zig-out\bin\`.

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

- `control.sh` and `dynip_linux_arm64` are placed in the same directory for deployment
- `control.sh` does not build the binary on the production host
- `docker_build` packages the existing binary with `Dockerfile`

Default names:

- image: `dynip-image`
- container: `dynip-container`
