# proxmox-auto-install-assistant

Serves Proxmox VE installers an answer file over HTTPS, picked per machine by
MAC address.

Two hosts are involved:

- **The answer server** — a VM or box with Docker. Runs this repo.
- **The Proxmox host** — builds the ISO that points at the answer server.

The installer POSTs its hardware info to `/answer`. The server returns
`public/answers/<mac>.toml` for a matching NIC, or `public/default.toml` if
none matches.

Files split by sensitivity: `public/` holds answer files, `private/` holds the
TLS key and auth token. Both are gitignored — answer files carry root password
hashes and SSH keys, so they stay on the answer server rather than in the repo.

---

## On the answer server

### 1. Answer files

One file per machine, named after the MAC it installs from. Separators don't
matter: `bc-24-11-7b-51-aa.toml`, `bc:24:11:7b:51:aa.toml` and
`BC24117B51AA.toml` all match the same NIC.

```toml
# public/answers/bc-24-11-7b-51-aa.toml
[global]
keyboard = "se"
country = "sv"
fqdn = "test-pve.example.com"
mailto = "admin@example.com"
timezone = "Europe/Stockholm"
root-password-hashed = "$y$j9T$..."

[network]
source = "from-answer"
cidr = "10.100.9.71/24"
dns = "10.100.9.10"
gateway = "10.100.9.1"
filter.ID_NET_NAME_MAC = "*bc24117b51aa"

[disk-setup]
filesystem = "ext4"
lvm.swapsize = 8
disk-list = ['sda']
```

`public/default.toml` is served when no MAC matches.

Field reference: [Answer File Format](https://pve.proxmox.com/wiki/Automated_Installation#Answer_File_Format).
Validate a file on the Proxmox host with `proxmox-auto-install-assistant validate-answer <file>`.

### 2. Run

The container generates whatever is missing on first start — a self-signed
certificate, an auth token, and an informational `default.toml`. It needs to be
told the addresses the installer will use to reach it, because the certificate's
SAN entries are validated and it cannot guess them:

```bash
export PVE_ANSWER_HOSTNAMES=10.100.9.50,pve-answer.example.com docker compose up -d --build
docker compose logs
```

The log prints the two values you need for the ISO, and the fingerprint on
every start:

```text
entrypoint: generated a new auth token. Prepare ISOs with:
entrypoint:   --answer-auth-token 'provisioning:8f3a...'
entrypoint: certificate SHA-256 fingerprint (pass to prepare-iso --cert-fingerprint):
entrypoint:   AB:CD:EF:...
```

Nothing is ever overwritten, so restarts keep the same certificate and token,
and `PVE_ANSWER_HOSTNAMES` is only needed the first time. If no certificate
exists and the variable is unset, the container refuses to start and says so
rather than generating a certificate the installer would reject.

To provide your own instead, drop the files in before the first start:

```bash
./gen-cert.sh 10.100.9.50 pve-answer.example.com   # writes private/tls/
printf 'provisioning:%s' "$(openssl rand -hex 32)" > private/token
chmod 600 private/token
```

To print the fingerprint again later:

```bash
openssl x509 -in private/tls/server.crt -noout -fingerprint -sha256 | cut -d '=' -f 2
```

### 3. Check it

```bash
curl --cacert private/tls/server.crt https://10.100.9.50/health

curl --cacert private/tls/server.crt -X POST https://10.100.9.50/answer \
    -H "Authorization: Bearer $(cat private/token)" \
    -d '{"network_interfaces":[{"mac":"bc:24:11:7b:51:aa"}]}'
```

> `server.py` is copied into the image, not mounted. To pick up a new
> published build run `docker compose pull && docker compose up -d`; to run
> local edits use `compose.dev.yaml` with `--build`. Everything under `public/`
> and `private/` is mounted and needs no rebuild.

The server runs as whoever owns `private/` on the host, so anything the
entrypoint generates there belongs to you and needs no `sudo` to read or
remove. If `private/` is owned by root, it falls back to UID 10001 rather than
running as root, warns in the log, and those files then do need `sudo`.

---

## On the Proxmox host

```bash
mkdir -p /opt/iso-builder && cd /opt/iso-builder
wget https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso

apt update
apt install -y proxmox-auto-install-assistant

proxmox-auto-install-assistant prepare-iso proxmox-ve_9.2-1.iso \
    --fetch-from http \
    --url "https://10.100.9.50/answer" \
    --cert-fingerprint "AB:CD:EF:..." \
    --answer-auth-token "provisioning:8f3a..."
```

`--cert-fingerprint` and `--answer-auth-token` are the values from steps 2 and
3 above. Omit the fingerprint and the installer rejects the self-signed
certificate; omit the token and it gets `401`.

Boot a machine from the resulting ISO — it calls the answer server and installs
itself.

**The token sits in plain text inside the ISO.** It proves a request came from
an ISO you built, not from a particular machine. Treat the ISO as a secret; if
one leaks, regenerate `private/token`, restart, and rebuild your ISOs.

---

## Reference

### Endpoints

| Method | Path | Response |
| --- | --- | --- |
| `POST` | `/answer` | the answer file, or `401` without a valid token |
| `GET` | `/health` | `ok` |
| `GET` | `/answer` | `405` — a POST is expected |
| `GET` | `/` | status page in debug mode, otherwise `404` |

Every `POST /answer` response carries an `X-Answer-Match` header naming the
answer file that matched, or `none` when it fell back to
`public/default.toml`. A no-match also logs a `WARNING` naming the MACs and
the peer, so an unregistered machine is visible in `docker compose logs`.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on pushes and pull
requests to `main`, weekly on Mondays at 04:00 UTC, and on demand from the
Actions tab.

It runs `pytest`, then builds `linux/amd64` and `linux/arm64` images and smoke
tests each one — arm64 under QEMU emulation on the amd64 runner — before
pushing a single multi-architecture tag to `ghcr.io/<owner>/<repo>` as `latest`
and `sha-<short>`. Publishing is skipped for pull requests. The weekly run
exists to pick up `python:3.13-slim` security updates without a code change.

Run the same checks locally:

```bash
pip install -r requirements_ci.txt
pytest

docker build -t pve-answer:smoke .
tests/smoke.sh pve-answer:smoke

# Or check the other architecture, which runs under emulation:
docker build --platform linux/arm64 -t pve-answer:arm64 .
tests/smoke.sh pve-answer:arm64
```

### Debug mode

`GET /` shows whether TLS and auth are on, whether `public/default.toml` parses, and
which MACs have answer files. **Off by default** — that list tells anyone who
can reach the server which machines you are provisioning. Uncomment
`PVE_ANSWER_DEBUG=1` in [`compose.yaml`](compose.yaml) and
`docker compose up -d`.
It never serves answer file contents.

### Flags

`compose.yaml` sets these through environment variables, but `server.py` also
takes them directly:

| Flag | Env | Default |
| --- | --- | --- |
| `--host` | — | `0.0.0.0` |
| `--port` | — | `8443` |
| `--cert` / `--key` | — | none, serves plain HTTP |
| `--answers-dir` | — | `public/answers` |
| `--default-answer` | — | `public/default.toml` |
| `--auth-token-file` | `PVE_ANSWER_TOKEN_FILE`, `PVE_ANSWER_TOKEN` | none, endpoint open |
| `--debug` | `PVE_ANSWER_DEBUG` | off |

Without a certificate or a token the server still starts, and warns at startup
that it is serving plain HTTP or an open endpoint.
