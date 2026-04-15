# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────
# Stage 1 – Build AirSane from source
# ─────────────────────────────────────────────
FROM debian:bookworm AS builder

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
ARG AIRSANE_REF=master

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
FROM debian:bookworm-slim

# brscan4 .deb URL – must be supplied as a build-arg; no default to avoid stale bakes
ARG BRSCAN4_URL

RUN test -n "${BRSCAN4_URL}" || { echo "ERROR: BRSCAN4_URL build-arg is required"; exit 1; }

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
    libtiff6 \
    # Utilities
    dbus \
    curl \
    wget \
    passwd \
    && rm -rf /var/lib/apt/lists/*

# Install brscan4 (resolving any missing deps with apt-get -f install)
RUN wget -qO /tmp/brscan4.deb "${BRSCAN4_URL}" \
    && dpkg -i /tmp/brscan4.deb || apt-get install -fy --no-install-recommends \
    && rm -f /tmp/brscan4.deb \
    && rm -rf /var/lib/apt/lists/*

# Copy AirSane binary (web assets are embedded in the binary)
COPY --from=builder /usr/local/bin/airsaned       /usr/local/bin/airsaned

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 631 8090

ENTRYPOINT ["/entrypoint.sh"]
