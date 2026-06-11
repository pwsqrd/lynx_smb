FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    python3 \
    python3-pip \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Build cc65 from source (latest HEAD) — the Debian 2.19 package has a PCX
# reader bug that skips row-padding bytes and rejects Pillow's extended palette.
RUN git clone --depth 1 https://github.com/cc65/cc65.git /tmp/cc65 \
    && make -C /tmp/cc65 -j$(nproc) \
    && make -C /tmp/cc65 install PREFIX=/usr/local \
    && rm -rf /tmp/cc65

ENV CC65_HOME=/usr/local/share/cc65

RUN pip3 install --no-cache-dir --break-system-packages Pillow>=9.0

WORKDIR /build
COPY . .

CMD ["make"]
