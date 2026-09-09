FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py /app/server.py
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Fallback identity; the entrypoint normally runs as the owner of private/.
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
