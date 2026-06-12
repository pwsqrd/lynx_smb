FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    python3 \
    python3-pip \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*


# Fix for potential build issues with different versions of cc65
# This commit is the exact toolchain the port is developed and tested against.
ARG CC65_COMMIT=c720c3c4854cf36befbb7d1b19fdb207f7549882
RUN git clone https://github.com/cc65/cc65.git /tmp/cc65 \
    && git -C /tmp/cc65 checkout "$CC65_COMMIT" \
    && make -C /tmp/cc65 -j$(nproc) \
    && make -C /tmp/cc65 install PREFIX=/usr/local \
    && rm -rf /tmp/cc65

ENV CC65_HOME=/usr/local/share/cc65

RUN pip3 install --no-cache-dir --break-system-packages Pillow>=9.0

WORKDIR /build
COPY . .

CMD ["make"]
