FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Copied before the source so the install layer is only rebuilt when the
# dependencies change, not on every edit to server.py.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py /app/server.py
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Fallback identity. The entrypoint normally runs the server as whoever owns
# the mounted private directory, so generated files are usable on the host
# without sudo; this user is only used when that cannot be determined, or when
# the directory is owned by root. The container starts as root just long enough
# to create missing certificates, tokens and directories.
RUN useradd --system --uid 10001 --no-create-home pve-answer \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--host", "0.0.0.0", \
     "--port", "8443", \
     "--cert", "/app/private/tls/server.crt", \
     "--key", "/app/private/tls/server.key", \
     "--answers-dir", "/app/public/answers", \
     "--default-answer", "/app/public/default.toml"]
