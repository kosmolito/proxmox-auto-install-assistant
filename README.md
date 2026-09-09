# proxmox-auto-install-assistant

Serves Proxmox VE installers an answer file over HTTPS, picked per machine by
MAC address.

Two hosts are involved:

- **The answer server** — a VM or box with Docker. Runs this repo.
- **The Proxmox host** — builds the ISO that points at the answer server.

The installer POSTs its hardware info to `/answer`. The server returns
`public/answers/<mac>.toml` for a matching NIC, or `public/default.toml` if
none matches.

`public/` holds answer files, `private/` the TLS key and auth token. Both are
gitignored — answer files carry root password hashes and SSH keys.

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
Validate with `proxmox-auto-install-assistant validate-answer <file>`.

### 2. Run

On first start the container generates a self-signed certificate, an auth token
and a `default.toml`. It needs the addresses the installer will use, since the
certificate's SAN entries are validated:

```bash
export PVE_ANSWER_HOSTNAMES=10.100.9.50,pve-answer.example.com
docker compose up -d
docker compose logs
```

The log carries the two values the ISO needs:

```text
entrypoint: generated a new auth token. Prepare ISOs with:
entrypoint:   --answer-auth-token 'provisioning:8f3a...'
entrypoint: certificate SHA-256 fingerprint (pass to prepare-iso --cert-fingerprint):
entrypoint:   AB:CD:EF:...
```

Existing files are never overwritten, so `PVE_ANSWER_HOSTNAMES` is only needed
the first time. Without a certificate and without that variable, the container
refuses to start.

To supply your own instead, drop them in before the first start:

```bash
./gen-cert.sh 10.100.9.50 pve-answer.example.com   # writes private/tls/
printf 'provisioning:%s' "$(openssl rand -hex 32)" > private/token
chmod 600 private/token
```

Print the fingerprint again later:

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

`server.py` lives in the image: `docker compose pull && docker compose up -d`
for a new published build, or `compose.dev.yaml` with `--build` for local
edits. `public/` and `private/` are mounted and need no rebuild.

The server runs as whoever owns `private/`, so generated files need no `sudo`.
A root-owned `private/` falls back to UID 10001 and warns.

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

Both values come from step 2. Without the fingerprint the installer rejects the
certificate; without the token it gets `401`.

**The token sits in plain text inside the ISO**, so it identifies the ISO, not
a machine. If one leaks, regenerate `private/token`, restart, rebuild the ISOs.

---

## Reference

### Endpoints

| Method | Path | Response |
| --- | --- | --- |
| `POST` | `/answer` | the answer file, or `401` without a valid token |
| `GET` | `/health` | `ok` |
| `GET` | `/answer` | `405` — a POST is expected |
| `GET` | `/` | status page in debug mode, otherwise `404` |

`POST /answer` sets `X-Answer-Match` to the answer file that matched, or `none`
when it fell back to `public/default.toml`. A no-match also logs a `WARNING`
naming the MACs.

### Debug mode

`GET /` shows whether TLS and auth are on and which MACs have answer files —
never file contents. **Off by default**, since that list reveals which machines
you are provisioning. Uncomment `PVE_ANSWER_DEBUG=1` in
[`compose.yaml`](compose.yaml).

### Flags

`compose.yaml` sets these through environment variables; `server.py` also takes
them directly.

| Flag | Env | Default |
| --- | --- | --- |
| `--host` | — | `0.0.0.0` |
| `--port` | — | `8443` |
| `--cert` / `--key` | — | none, serves plain HTTP |
| `--answers-dir` | — | `public/answers` |
| `--default-answer` | — | `public/default.toml` |
| `--auth-token-file` | `PVE_ANSWER_TOKEN_FILE`, `PVE_ANSWER_TOKEN` | none, endpoint open |
| `--debug` | `PVE_ANSWER_DEBUG` | off |

Without a certificate or token the server still starts, warning that it serves
plain HTTP or an open endpoint.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on push and PR to
`main`, weekly, and on demand. It tests, builds `amd64` and `arm64`, smoke
tests each, then publishes a multi-platform manifest to
`ghcr.io/<owner>/<repo>` as `latest` and `sha-<short>` — pointing at the exact
images that passed, never a rebuild. PRs do not publish.

```bash
pip install -r requirements_ci.txt
pytest

docker build -t pve-answer:smoke .
tests/smoke.sh pve-answer:smoke
```
