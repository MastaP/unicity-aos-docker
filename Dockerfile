# Unicity AOS Community Edition — containerised runtime.
#
# Why this image exists: the official signed `astrid` release binaries are
# linked against glibc >= 2.39, so they do not run on older hosts (e.g. Ubuntu
# 22.04 / glibc 2.35), which otherwise forces a from-source build of the whole
# 29-crate kernel workspace. A modern base image sidesteps that entirely and
# lets us consume the *signed, checksum-verified* release artifact instead.
#
# Stage 1 compiles the Community Edition capsules to WASM; stage 2 is a slim
# runtime carrying only the kernel binaries, the distro manifest and the
# packaged `.capsule` assets.

# ─── Stage 1: build the CE capsule set ──────────────────────────────────────
FROM rust:1.95-trixie AS capsules

ARG ASTRID_VERSION=0.10.4
ARG ASTRID_SHA=a7c955ff5901d98059e8e6fba6f6b6e2033224e39c06db93e48a2ebe2a4f4725

RUN rustup target add wasm32-unknown-unknown

# `astrid-build` (from the release bundle) compiles and packages each capsule.
WORKDIR /tmp/rt
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL -o rt.tar.gz \
      "https://github.com/astrid-runtime/astrid/releases/download/v${ASTRID_VERSION}/astrid-${ASTRID_VERSION}-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${ASTRID_SHA}  rt.tar.gz" | sha256sum -c -; \
    tar xzf rt.tar.gz --strip-components=1; \
    install -m0755 astrid astrid-daemon astrid-build astrid-emit /usr/local/bin/; \
    rm -rf /tmp/rt

# Both sources are cloned rather than copied from the build context, so this
# repository is self-contained: a fresh clone builds without needing aos-ce
# checked out alongside it. Pin the refs for a reproducible image.
ARG AOS_CE_REPO=https://github.com/unicity-aos/aos-ce.git
ARG AOS_CE_REF=main

WORKDIR /src
RUN set -eux; \
    git clone --depth 1 --branch "${AOS_CE_REF}" "${AOS_CE_REPO}" /src/aos-ce; \
    git -C /src/aos-ce rev-parse HEAD > /tmp/aos-ce-commit.txt

# Build every capsule named in the CE release allowlist.
RUN set -eux; \
    cd /src/aos-ce; \
    mkdir -p /out/capsules; \
    for d in $(grep -v '^#' release/community-capsules.txt | grep -v '^[[:space:]]*$'); do \
      astrid-build "./capsules/$d" --output /out/capsules; \
    done; \
    cp distros/community/unicity-ce/Distro.toml /out/Distro.toml; \
    cp /tmp/aos-ce-commit.txt /out/aos-ce-commit.txt; \
    ls -la /out/capsules

# The Telegram uplink lives in its own repository and is not part of the CE
# distro, so it is built from upstream rather than from the aos-ce tree. Doing
# it here — where the Rust toolchain and astrid-build already exist — keeps the
# runtime stage slim: it receives a finished `.capsule` and never needs git or
# cargo. Pin TELEGRAM_REF to a tag or commit for a reproducible image.
ARG TELEGRAM_REPO=https://github.com/unicity-aos/capsule-telegram.git
ARG TELEGRAM_REF=main
RUN set -eux; \
    git clone --depth 1 --branch "${TELEGRAM_REF}" "${TELEGRAM_REPO}" /src/capsule-telegram; \
    git -C /src/capsule-telegram rev-parse HEAD > /out/telegram-commit.txt; \
    astrid-build /src/capsule-telegram --output /out/capsules; \
    test -f /out/capsules/astrid-capsule-telegram.capsule

# ─── Stage 2: runtime ───────────────────────────────────────────────────────
FROM debian:trixie-slim

ARG ASTRID_VERSION=0.10.4
ARG ASTRID_SHA=a7c955ff5901d98059e8e6fba6f6b6e2033224e39c06db93e48a2ebe2a4f4725

# bubblewrap backs the OS process sandbox used by host_process capsules
# (aos-shell). ca-certificates is required for outbound TLS to LLM providers
# and the Telegram Bot API.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl bubblewrap; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    cd /tmp; \
    curl --proto '=https' --tlsv1.2 -fsSL -o rt.tar.gz \
      "https://github.com/astrid-runtime/astrid/releases/download/v${ASTRID_VERSION}/astrid-${ASTRID_VERSION}-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${ASTRID_SHA}  rt.tar.gz" | sha256sum -c -; \
    tar xzf rt.tar.gz; \
    install -m0755 "astrid-${ASTRID_VERSION}-x86_64-unknown-linux-gnu"/astrid* /usr/local/bin/; \
    rm -rf /tmp/*

# Run as a non-root user: the kernel writes its state under $HOME and normalises
# private directories to owner-only access.
RUN useradd --create-home --uid 1000 aos
COPY --from=capsules --chown=aos:aos /out /opt/aos-distro
COPY --chown=aos:aos entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# The state directory must exist *in the image*, owned by `aos`, before it is
# declared as a volume: Docker seeds a fresh named volume from the image path,
# so if the directory is absent the volume is created root-owned and the
# unprivileged user cannot write its runtime state.
RUN install -d -o aos -g aos -m 0700 /home/aos/.astrid

USER aos
WORKDIR /home/aos
ENV ASTRID_HOME=/home/aos/.astrid
VOLUME ["/home/aos/.astrid"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["daemon"]
