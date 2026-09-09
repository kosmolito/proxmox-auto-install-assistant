# proxmox-auto-install-assistant

Serves Proxmox VE installers an answer file over HTTPS, picked per machine by
MAC address.

Everything runs on **one machine, the answer server** — it serves the answer
files and prepares the ISO. No Proxmox host is involved until you boot it.

The installer POSTs its hardware info to `/answer`. The server returns
`public/answers/<mac>.toml` for a matching NIC, or `public/default.toml` if
none matches.

Two directories on the answer server, the same either way you set it up:

| Path | |
| --- | --- |
| `/opt/pve-answer` | `compose.yaml`, `public/` answer files, `private/` key and token |
| `/opt/iso-builder` | the source ISO and the prepared one |

---

## Quickstart: Ansible

```bash
git clone https://github.com/kosmolito/proxmox-auto-install-assistant.git
cd proxmox-auto-install-assistant/ansible

cp hosts.example hosts
$EDITOR hosts                        # the answer server's address and user
$EDITOR group_vars/answer_server.yml # ISO URL, ports, paths

ansible-playbook site.yaml
```

That installs Docker and the assistant, starts the answer server, downloads the
ISO and prepares it. Re-running changes nothing.

The answer server needs your per-MAC files in `/opt/pve-answer/public/answers/`
— Ansible creates the directory but never writes into it.

---

## Quickstart: manual

Same result, by hand. Everything below happens on the answer server.

### 1. Install Docker and the assistant

Docker from [its own repository](https://docs.docker.com/engine/install/), then
the assistant. It is published for Debian suites only, so on Ubuntu install the
`.deb` directly:

```bash
V=9.2.8
curl -fsSLO "http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/proxmox-auto-install-assistant_${V}_amd64.deb"
apt install ./proxmox-auto-install-assistant_${V}_amd64.deb
```

On Debian, add the `pve-no-subscription` repository and `apt install proxmox-auto-install-assistant` as well, but the `.deb` is simpler and works on Ubuntu too.

### 2. Start the answer server

```bash
git clone https://github.com/kosmolito/proxmox-auto-install-assistant.git
cd proxmox-auto-install-assistant

mkdir -p /opt/pve-answer /opt/iso-builder
cp compose.yaml /opt/pve-answer/

cd /opt/pve-answer
mkdir -p public/answers private
chown 10001:10001 private          # the container runs as this uid

export PVE_ANSWER_HOSTNAMES=10.100.9.150,pve-answer.example.com
docker compose up -d
docker compose logs
```

`PVE_ANSWER_HOSTNAMES` is every address the installer may use to reach this
server; they become the certificate's SAN entries, which the installer
validates. The first start generates a certificate, an auth token and a
`default.toml`, and the log prints the two values the ISO needs:

```text
entrypoint: generated a new auth token. Prepare ISOs with:
entrypoint:   --answer-auth-token 'provisioning:8f3a...'
entrypoint: certificate SHA-256 fingerprint (pass to prepare-iso --cert-fingerprint):
entrypoint:   AB:CD:EF:...
```

Nothing is overwritten, so `PVE_ANSWER_HOSTNAMES` is only needed the first
time. With no certificate and no such variable, the container refuses to start.

Check it:

```bash
curl --cacert /opt/pve-answer/private/tls/server.crt https://10.100.9.150/health
# should print "ok"

curl --cacert /opt/pve-answer/private/tls/server.crt -X POST https://10.100.9.150/answer \
    -H "Authorization: Bearer $(cat /opt/pve-answer/private/token)" \
    -d '{"network_interfaces":[{"mac":"bc:24:11:7b:51:aa"}]}'
```

### 3. Prepare the ISO

```bash
cd /opt/iso-builder
wget https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso

CERT_FINGERPRINT="$(cat /opt/pve-answer/private/tls/server.crt | openssl x509 -fingerprint -sha256 -noout | cut -d= -f2)"
AUTH_TOKEN="$(cat /opt/pve-answer/private/token)"
proxmox-auto-install-assistant prepare-iso proxmox-ve_9.2-1.iso \
    --fetch-from http \
    --url "https://10.100.9.150/answer" \
    --cert-fingerprint "${CERT_FINGERPRINT}" \
    --answer-auth-token "${AUTH_TOKEN}"
```

Both values come from step 2. Without the fingerprint the installer rejects the
certificate; without the token it gets `401`.

Boot a machine from the resulting `*-auto-from-http.iso`.

**The token sits in plain text inside the ISO**, so it identifies the ISO, not
a machine. If one leaks, regenerate `private/token`, restart, rebuild the ISOs.

---

## Answer files

One file per machine in `/opt/pve-answer/public/answers/`, named after the MAC
it installs from. Separators don't matter: `bc-24-11-7b-51-aa.toml`,
`bc:24:11:7b:51:aa.toml` and `BC24117B51AA.toml` all match the same NIC.

```toml
# /opt/pve-answer/public/answers/bc-24-11-7b-51-aa.toml
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

`public/default.toml` is served when no MAC matches. It ships with no install
settings, so an unregistered machine is not installed.

Field reference: [Answer File Format](https://pve.proxmox.com/wiki/Automated_Installation#Answer_File_Format).
Validate with `proxmox-auto-install-assistant validate-answer <file>`.

---

## Reference

### Notes

- `server.py` lives in the image: `docker compose pull && docker compose up -d`
  for a published build, `compose.dev.yaml` with `--build` for local edits.
  `public/` and `private/` are mounted and need no rebuild.
- The server runs as whoever owns `private/`, so generated files need no `sudo`.
- Pulling needs the GHCR package public, or `docker login ghcr.io` on the host.

### Endpoints

| Method | Path | Response |
| --- | --- | --- |
| `POST` | `/answer` | the answer file, or `401` without a valid token |
| `GET` | `/health` | `ok` |
| `GET` | `/answer` | `405` — a POST is expected |
| `GET` | `/` | status page in debug mode, otherwise `404` |

`POST /answer` sets `X-Answer-Match` to the file that matched, or `none` on
fallback, and a no-match logs a `WARNING` naming the MACs.

### Debug mode

`GET /` shows whether TLS and auth are on and which MACs have answer files,
never file contents. **Off by default** — uncomment `PVE_ANSWER_DEBUG=1` in
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
tests each, then publishes a multi-platform manifest as `latest` and
`sha-<short>` pointing at the exact images that passed. PRs do not publish.

```bash
pip install -r requirements_ci.txt
pytest

docker build -t pve-answer:smoke .
tests/smoke.sh pve-answer:smoke
```
