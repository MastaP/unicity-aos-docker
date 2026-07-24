# unicity-aos-docker

Run [Unicity AOS Community Edition](https://github.com/unicity-aos/aos-ce) in a
container: the Astrid runtime, the 19 CE capsules, and — optionally — the
[Telegram uplink](https://github.com/unicity-aos/capsule-telegram).

Self-contained. Both capsule sources are cloned during the image build, so a
fresh clone of *this* repository is all you need.

## Quick start

```bash
git clone https://github.com/MastaP/unicity-aos-docker.git
cd unicity-aos-docker

cp .env.example .env          # fill in your provider key
mkdir -p data && chmod 700 data

docker compose up -d --build
docker compose exec aos astrid -p "hello"
```

Then:

```bash
docker compose exec aos astrid status
docker compose logs -f
```

## Secrets

**All credentials live in `.env`, which is gitignored and never baked into the
image.** Nothing secret belongs in the Dockerfile, the compose file, or the
image itself — they are passed to the container at runtime as environment
variables.

`.env.example` is the template; copy it to `.env` and fill it in. Keep `.env`
mode 600.

## Why a container

The official signed `astrid` binaries link against glibc ≥ 2.39, so they will
not run on older hosts — Ubuntu 22.04 ships 2.35. Natively that forces a
from-source build of the whole 29-crate kernel workspace. This image is built on
Debian Trixie and consumes the **signed, checksum-verified** release artifact
instead, so on an older host the container is the *easier* path, not the harder
one.

## Where your data lives

**`./data/` — a plain directory on the host.** Everything the runtime owns is
there: runtime keys, secrets, KV, sessions, the audit chain, installed capsules,
and anything an agent builds with Forge.

This is a **bind mount**, deliberately not a named Docker volume. A named volume
is invisible in the filesystem, has no natural backup story, and is destroyed by
`docker compose down -v` — an easy command to reach for, which takes every
agent-authored capsule with it. A host directory survives that, is inspectable
without a container, and backs up with ordinary tools:

```bash
tar czf aos-backup-$(date +%F).tar.gz data
```

Because it is an ordinary directory rather than a Docker-managed volume,
`docker compose down -v` does not touch it: the container and its network are
removed, `./data/` is left as-is, and `up -d` resumes from the same state.

Point it elsewhere with `AOS_DATA_DIR`:

```
AOS_DATA_DIR=/srv/aos-state
```

> **`data/` also holds live secrets** once running — the provider key and bot
> token are persisted under `secrets/` and `home/default/.config/env/`. It is
> gitignored. Do not commit it or put it in a shared archive.

The container runs as uid/gid **1000**. The host directory must be owned by that
uid, or the daemon cannot write its state; `chown 1000:1000 data` if your user
differs.

## Configuration

Environment-only. See `.env.example`.

| Variable | Purpose |
|---|---|
| `OPENAI_API_KEY` | provider key |
| `OPENAI_BASE_URL` | provider base URL — **must not** include `/v1`, the capsule appends it |
| `OPENAI_MODEL` | model id |
| `TELEGRAM_BOT_TOKEN` | from [@BotFather](https://t.me/BotFather); **empty disables the uplink** |
| `TELEGRAM_ALLOWED_USER_IDS` | comma-separated allowlist; **empty means anyone can drive your agent** |
| `AOS_DATA_DIR` | host path for state (default `./data`) |
| `AOS_CE_REF` | git ref of `unicity-aos/aos-ce` to build (default `main`) |
| `TELEGRAM_REF` | git ref of `unicity-aos/capsule-telegram` (default `main`) |
| `AOS_IMAGE_TARGET` | `runtime` (slim, default) or `devtools` (adds the Rust toolchain) — see [Building capsules](#building-capsules) |

Any OpenAI-compatible provider works. The base URL must omit `/v1` — the
provider capsule appends `/v1/models` and `/v1/chat/completions` itself:

```
OPENAI_BASE_URL=https://api.openai.com
OPENAI_BASE_URL=https://api.moonshot.ai
OPENAI_BASE_URL=http://host.docker.internal:11434   # ollama
```

Re-running `up -d` re-applies the Telegram configuration, so a rotated token
takes effect without touching the state directory.

## Reproducible builds

`AOS_CE_REF` and `TELEGRAM_REF` default to `main`. Pin them to tags or commits
for a build you can reproduce:

```
AOS_CE_REF=v2026.1.3
TELEGRAM_REF=2a99687ce1abe4d5031d15ecabb810505b3f5bfb
```

The refs are resolved with `git fetch`, so all three of a branch name, a tag,
and a full commit SHA work. The resolved commits of both sources are recorded in
the image (`/opt/aos-distro/aos-ce-commit.txt` and `telegram-commit.txt`), and
the Telegram one is echoed at startup, so a running container can always tell
you what it shipped. (With a moving ref like `main`, Docker caches the clone
layer — pass `--no-cache` or pin a tag/SHA when you want a guaranteed re-fetch.)

## Building capsules

The default `runtime` image has no compiler, so it cannot build a capsule. To
build one *inside the container*, use the `devtools` target, which adds the Rust
toolchain (`AOS_IMAGE_TARGET=devtools` in `.env`, then `up -d --build`):

```bash
docker compose exec aos astrid capsule build /path/to/capsule --output ./dist
docker compose exec aos astrid capsule install ./dist/<name>.capsule
docker compose exec aos astrid capsule list
```

This is the **operator** path: it runs in the container's normal namespace and
needs no extra privileges.

**What does not work: the agent building a capsule on its own.** An agent can
scaffold a capsule with Forge, but it cannot then build it from inside the
container. Two reasons, both by design:

- `aos-shell` (the agent's shell) is blocked in a default container: its
  bubblewrap sandbox needs nested unprivileged user namespaces that Docker's
  default seccomp/AppArmor profiles forbid. Relaxing that removes most of the
  container's isolation and is left off on purpose.
- Even with the shell enabled, `aos-shell` runs **each** command in a fresh,
  ephemeral sandbox with no filesystem shared between calls — so a multi-step
  build (write sources, then compile, then read the artifact) cannot carry state
  across steps.

So: build with the operator commands above, then let the agent use the installed
capsule. Full agent-autonomous builds would require changes in AOS itself (a
persistent build workspace bound into the shell sandbox, or a dedicated build
capsule), not in this image.

The `devtools` image is ~3.4 GB versus ~330 MB for `runtime`; keep the default
`runtime` unless you are building capsules.

## How the image is built

**Stage 1** (`rust:1.95-trixie`) downloads the signed Astrid release, verifies
its SHA-256, then fetches `aos-ce` and builds every capsule named in
`release/community-capsules.txt`. It then fetches `capsule-telegram` and builds
that separately — the Telegram uplink is not part of the CE distro, so it comes
from its own repository.

**Stage 2 — `runtime`** (`debian:trixie-slim`) carries only the kernel binaries,
the distro manifest, and the packaged `.capsule` files. No Rust, no git. This is
the production default.

**Stage 3 — `devtools`** layers the Rust toolchain (copied from stage 1, no
second download) onto `runtime`, selected by `AOS_IMAGE_TARGET=devtools`.

## Operating

```bash
docker compose exec aos astrid status     # daemon, version, loaded capsules
docker compose exec aos astrid ps         # capsule lifecycle state
docker compose exec aos astrid capsule list
docker compose logs -f

# install any capsule from its own repository
docker compose exec aos astrid capsule install @unicity-aos/capsule-telegram
```

`aos-shell` sandboxes host processes with bubblewrap, which needs unprivileged
user namespaces. If shell tool calls fail with a sandbox error, uncomment
`security_opt` in `docker-compose.yml` and confirm the host permits them
(`sysctl kernel.unprivileged_userns_clone=1`).

## Telegram

Leave `TELEGRAM_BOT_TOKEN` empty and the uplink is not installed at all.

With a token set, the capsule is installed and starts polling. Set
`TELEGRAM_ALLOWED_USER_IDS` to your numeric Telegram id (ask
[@userinfobot](https://t.me/userinfobot)) — **an empty allowlist lets any
Telegram user drive your agent**, and the container refuses to install the uplink unless you also set
`TELEGRAM_ALLOW_ANY_USER=1`.

All Telegram users share one AOS principal: the runtime derives a message's
principal from the inbound connection, and an HTTP-polling uplink has none. The
allowlist is therefore the only isolation boundary.

## License

MIT
