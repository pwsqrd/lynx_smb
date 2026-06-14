FROM alpine:latest

# Fix for potential build issues with different versions of cc65
# This commit is the exact toolchain the port is developed and tested against.
ARG CC65_COMMIT=c720c3c4854cf36befbb7d1b19fdb207f7549882

RUN apk add --no-cache \
    git \
    musl-dev gcc make bash \
    python3 py3-pip \
    && git clone https://github.com/cc65/cc65.git /tmp/cc65 \
    && git -C /tmp/cc65 checkout "$CC65_COMMIT" \
    && make -C /tmp/cc65 -j$(nproc) \
    && make -C /tmp/cc65 install PREFIX=/usr/local \
    && rm -rf /tmp/cc65 \
    && pip3 install --no-cache --break-system-packages Pillow>=9.0 \
    && apk del musl-dev gcc py3-pip

ENV CC65_HOME=/usr/local/share/cc65

RUN ln -sf python3 /usr/bin/python

WORKDIR /build