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
# `git clone --branch` accepts only branch and tag names, so pinning
# TELEGRAM_REF to a commit SHA — which this image documents as supported —
# would fail. Fetching the ref explicitly handles branches, tags AND SHAs.
#
# Note that with a moving ref like `main`, Docker caches this layer on the ARG
# value, so a rebuild will happily reuse a stale clone. Pin TELEGRAM_REF to a
# tag or commit for a reproducible image, or pass --no-cache to re-resolve.
RUN set -eux; \
    mkdir -p /src/capsule-telegram; \
    cd /src/capsule-telegram; \
    git init -q .; \
    git remote add origin "${TELEGRAM_REPO}"; \
    git fetch -q --depth 1 origin "${TELEGRAM_REF}"; \
    git checkout -q FETCH_HEAD; \
    git rev-parse HEAD > /out/telegram-commit.txt; \
    astrid-build /src/capsule-telegram --output /out/capsules; \
    test -f /out/capsules/astrid-capsule-telegram.capsule

# ─── Stage 2: runtime (slim, production default) ─────────────────────────────
FROM debian:trixie-slim AS runtime

ARG ASTRID_VERSION=0.10.4
ARG ASTRID_SHA=a7c955ff5901d98059e8e6fba6f6b6e2033224e39c06db93e48a2ebe2a4f4725

# bubblewrap backs the OS process sandbox used by host_process capsules
# (aos-shell). ca-certificates is required for outbound TLS to LLM providers
# and the Telegram Bot API.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates bubblewrap; \
    rm -rf /var/lib/apt/lists/*

# Take the binaries from stage 1, which already downloaded and SHA-256 verified
# them. Re-fetching here would download the same 48MB a second time and, worse,
# would require `curl` in the final image — a ready-made fetch/exfil tool in a
# container whose whole purpose is executing agent-authored capsules and
# sandboxed host processes.

# Run as a non-root user: the kernel writes its state under $HOME and normalises
# private directories to owner-only access.
RUN useradd --create-home --uid 1000 aos
COPY --from=capsules /usr/local/bin/astrid /usr/local/bin/astrid-daemon /usr/local/bin/astrid-build /usr/local/bin/astrid-emit /usr/local/bin/
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

# ─── Stage 3: devtools (runtime + Rust toolchain) ────────────────────────────
# The slim `runtime` above cannot build a capsule: it has `astrid-build` but no
# compiler, which is why an agent that scaffolds a capsule with Forge cannot
# then build and install it from inside the container. This target adds the
# toolchain so `astrid capsule build` works in-container:
#
#   docker compose exec aos astrid capsule build <path> --output <dir>
#   docker compose exec aos astrid capsule install <dir>/<name>.capsule
#
# It is NOT the default. A compiler in a container that also executes
# agent-authored capsule code is extra attack surface, so production keeps the
# slim `runtime` target and opt into this one deliberately:
#   AOS_IMAGE_TARGET=devtools docker compose up -d --build
#
# The toolchain is copied from the stage-1 builder (rust:1.95-trixie), which
# already has rustup, cargo, and the wasm32-unknown-unknown target — no second
# download. `gcc` is genuinely required even for a wasm-only build: proc-macro
# crates (serde_derive, …) are compiled for the HOST and need a host linker.
FROM runtime AS devtools

USER root
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gcc libc6-dev; \
    rm -rf /var/lib/apt/lists/*

COPY --from=capsules /usr/local/rustup /usr/local/rustup
COPY --from=capsules /usr/local/cargo /usr/local/cargo

# World-readable so uid 1000 can use the shared toolchain; CARGO_HOME stays
# writable for the per-build registry/target cache.
RUN set -eux; \
    chmod -R a+rX /usr/local/rustup; \
    chmod -R a+rwX /usr/local/cargo; \
    rustc --version; \
    cargo --version; \
    rustup target list --installed | grep -q wasm32-unknown-unknown

# aos-shell runs the agent's commands inside a bwrap sandbox that STRIPS the
# environment — no RUSTUP_HOME, CARGO_HOME, or HOME — so the rustup proxy
# binaries in /usr/local/cargo/bin cannot locate a toolchain ("no default set")
# and would even fetch one over the network on first use. Symlink the *real*
# toolchain binaries onto /usr/local/bin (which is on the sandbox PATH): the
# real cargo finds rustc via its own resolved location, needing no environment
# at all. `env -i` below reproduces the sandbox's empty environment exactly, so
# a green build proves the agent can compile capsules through aos-shell.
# The binaries in /usr/local/cargo/bin are rustup PROXIES (symlinks to `rustup`)
# that resolve a toolchain via RUSTUP_HOME. In the normal container that env is
# set, so they work; inside the bwrap sandbox it is stripped, so they fail. That
# directory is also ahead of /usr/local/bin on the resolved PATH, so it is the
# one that actually runs. Overwrite the proxies (in BOTH bin dirs) with the real
# toolchain binaries, which locate rustc/std from their own resolved path and
# need no environment. `rustup` itself is left intact for interactive use.
#
# One consequence: bypassing the proxies also bypasses per-project
# rust-toolchain.toml selection — every build uses this pinned toolchain. That
# is fine for capsules pinning <= this version; a capsule pinning a newer
# toolchain would need it installed and the pin bumped here.
ARG RUST_TOOLCHAIN_DIR=/usr/local/rustup/toolchains/1.95.0-x86_64-unknown-linux-gnu/bin
RUN set -eux; \
    for b in cargo rustc rustdoc rustfmt cargo-clippy clippy-driver cargo-fmt; do \
      ln -sf "${RUST_TOOLCHAIN_DIR}/${b}" "/usr/local/bin/${b}"; \
      ln -sf "${RUST_TOOLCHAIN_DIR}/${b}" "/usr/local/cargo/bin/${b}"; \
    done; \
    # Reproduce the bwrap sandbox: empty environment, only a PATH. If a proxy
    # still shadowed the real binary, this would fail the build rather than
    # surface at runtime.
    env -i PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin cargo --version; \
    env -i PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin rustc --version; \
    env -i PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin \
      rustc --print target-list | grep -qx wasm32-unknown-unknown

USER aos
