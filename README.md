<p align="right">
  <a href="./README.md">English</a> | <a href="./README.zh-TW.md">繁體中文</a>
</p>

# dynip

A DDNS background service written in Zig.

`dynip` periodically checks the current public IP and updates configured DDNS providers:

- Afraid.org
- Dynu
- No-IP

It supports layered configuration loading, structured logging, HTTP request tracing, and dedupe control through either Redis or in-process memory.

## Features

- Load configuration from `app.json`
- Override config with `.env`
- Override both with process environment variables
- Run as a long-lived scheduler
- Update Afraid / Dynu / No-IP independently
- Rotate across multiple public IP lookup providers
- Write log files by level
- Record HTTP request and response logs
- Dedupe updates with Redis or local memory

## How It Works

For each refresh cycle, `dynip`:

1. Checks whether the current time is inside the maintenance window `02:00` to `02:04` local time.
2. Fetches the current public IP from one of the built-in public IP providers.
3. Builds a dedupe key in the form `MyPublicIP:{ip}`.
4. Checks that key in Redis when `ddns.redis.enabled = true`, otherwise checks an in-memory local TTL cache.
5. Skips the update if the key already exists.
6. Updates all enabled DDNS providers with complete credentials.
7. Stores the key after at least one provider update succeeds.

## Project Layout

- `src/main.zig`: CLI entry point
- `src/config.zig`: config loading, `.env` parsing, environment overrides
- `src/ddns.zig`: DDNS refresh flow and provider update logic
- `src/redis.zig`: Redis client wrapper
- `src/scheduler.zig`: fixed-interval scheduler
- `src/logging.zig`: file logging and rotation
- `src/tests.zig`: test entrypoint
- `build.zig`: build definition
- `build.ps1`: Windows release build script
- `build.bat`: Windows batch wrapper
- `control.sh`: Docker-oriented helper script
- `Dockerfile`: container image build

## Requirements

- Zig `0.16.0-dev.2979+e93834410` or a compatible nearby dev version
- Network access to public IP lookup providers
- Network access to the DDNS providers you enable
- Redis only if you want Redis-backed dedupe

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

### Provider Config Shape

All three DDNS providers follow the same structure:

- `enabled`
- `url`
- provider-specific authentication fields

Provider-specific fields:

- `afraid`: `path`, `token`
- `dyny`: `username`, `password`
- `noip`: `username`, `password`, `hostnames`

### Redis Dedupe

When `ddns.redis.enabled = true`:

- dedupe is stored in Redis
- key format is `MyPublicIP:{ip}`
- the latest public IP is also stored in `MyPublicIP`
- successful updates write the key with `SETEX`

When `ddns.redis.enabled = false`:

- dedupe is stored in local process memory
- the same TTL logic still applies
- dedupe state is lost after process restart

### Supported Environment Variables

#### Afraid

- `AFRAID_ENABLED`
- `AFRAID_URL`
- `AFRAID_PATH`
- `AFRAID_TOKEN`

#### Dynu

- `DYNU_ENABLED`
- `DYNU_URL`
- `DYNU_USERNAME`
- `DYNU_PASSWORD`

#### No-IP

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
AFRAID_TOKEN=your-afraid-token

DYNU_ENABLED=true
DYNU_URL=https://api.dynu.com/nic/update
DYNU_USERNAME=your-dynu-username
DYNU_PASSWORD=your-dynu-password

NOIP_ENABLED=true
NOIP_URL=https://dynupdate.no-ip.com/nic/update
NOIP_USERNAME=your-noip-username
NOIP_PASSWORD=your-noip-password
NOIP_HOSTNAMES=["example.ddns.net","example.zapto.org"]

REDIS_ENABLED=false
DDNS_REFRESH_INTERVAL_SECONDS=60
DDNS_DEDUPE_TTL_SECONDS=86400
```

## Usage

### Run Tests

```bash
zig build test
```

If the repo is on a mounted WSL path such as `/mnt/d/...`, use Linux-native cache directories:

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
- daily rollover
- generation suffixes after `10 MB`
- cleanup for logs older than `7` days
- formatted dump of the loaded runtime config on service startup
- provider response summaries
- HTTP request and response logs

## Public IP Providers

Built-in lookup providers:

- `https://api.ipify.org`
- `https://ipconfig.io/ip`
- `https://ipinfo.io/ip`
- `https://ipv4.seeip.org`
- `https://api.myip.com`
- `https://api.bigdatacloud.net/data/client-ip`

The lookup start position rotates between refresh cycles instead of always starting from the first provider.

## Windows Build

From `cmd.exe`:

```bat
cd /d D:\Project\Eddie\stock_zig
build.bat
```

From PowerShell:

```powershell
Set-Location D:\Project\Eddie\stock_zig
powershell.exe -ExecutionPolicy Bypass -File .\build.ps1
```

The PowerShell build currently emits a stripped ARM64 Linux binary into `zig-out\bin\`.

## Docker

`control.sh` is currently geared toward Docker workflows.

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
- `control.sh` does not build the binary in production
- `docker_build` packages the existing binary with `Dockerfile`

Default names:

- image: `dynip-image`
- container: `dynip-container`
