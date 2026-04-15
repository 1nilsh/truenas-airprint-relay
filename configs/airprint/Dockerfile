# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────
# Stage 1 – Build AirSane from source
# ─────────────────────────────────────────────
FROM debian:bullseye AS builder

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    cmake \
    g++ \
    make \
    pkg-config \
    libusb-1.0-0-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libsane-dev \
    libavahi-client-dev \
    && rm -rf /var/lib/apt/lists/*

ARG AIRSANE_REPO=https://github.com/SimulPiscator/AirSane.git
ARG AIRSANE_REF=v0.4.9

RUN git clone --depth=1 --branch "${AIRSANE_REF}" "${AIRSANE_REPO}" /airsane-src

WORKDIR /airsane-src
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build

# ─────────────────────────────────────────────
# Stage 2 – Runtime image
# ─────────────────────────────────────────────
FROM debian:bullseye-slim

# brscan4 .deb URL – must be supplied as a build-arg; no default to avoid stale bakes
ARG BRSCAN4_URL

RUN test -n "${BRSCAN4_URL}" || { echo "ERROR: BRSCAN4_URL build-arg is required"; exit 1; }

# Brother brscan4 is distributed as amd64 .deb only.
RUN [ "$(dpkg --print-architecture)" = "amd64" ] || { echo "ERROR: this image requires amd64 (x86_64)"; exit 1; }

# Runtime dependencies
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    # CUPS and printer driver
    cups \
    cups-filters \
    printer-driver-brlaser \
    # SANE runtime
    libsane1 \
    sane-utils \
    # Avahi client (no daemon – connects to host Avahi via mounted D-Bus socket)
    libavahi-client3 \
    # AirSane runtime deps
    libusb-1.0-0 \
    libjpeg62-turbo \
    libpng16-16 \
    libtiff5 \
    # Utilities
    ca-certificates \
    dbus \
    curl \
    wget \
    passwd \
    && rm -rf /var/lib/apt/lists/*

# Install brscan4 – apt-get install on a local path fetches missing deps automatically
RUN apt-get update \
    && wget -qO /tmp/brscan4.deb "${BRSCAN4_URL}" \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/brscan4.deb \
    && rm -f /tmp/brscan4.deb \
    && rm -rf /var/lib/apt/lists/*

# Copy AirSane binary (web assets are embedded in the binary)
COPY --from=builder /usr/local/bin/airsaned       /usr/local/bin/airsaned

# Only load the Brother brscan4 backend — the default dll.conf enables 70+
# backends, at least one of which segfaults during sane_get_devices() init.
RUN echo "brother4" > /etc/sane.d/dll.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 631 8090

ENTRYPOINT ["/entrypoint.sh"]
