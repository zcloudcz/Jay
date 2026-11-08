# Build context MUST be the repository's src/ directory, because the
# archiver depends on sibling packages by path:
#   docker build -f src/bots/jay_archiver/Dockerfile -t jay-archiver src
#
# Generic on purpose: no Azure specifics, no assumption of running next to
# the database. Same image serves all three hosting variants (operator's own
# server, dedicated cloud container, customer-hosted) — only config differs.
FROM dart:stable AS build
WORKDIR /src
# calltype_core depends on calltype_protocol (crypto + wire format) by path.
COPY client/calltype_protocol client/calltype_protocol
COPY client/calltype_core client/calltype_core
COPY bots/calltype_bot bots/calltype_bot
COPY bots/jay_archiver bots/jay_archiver

# The drift schema's *.g.dart is not committed — generate it first.
RUN cd client/calltype_core \
 && dart pub get \
 && dart run build_runner build --delete-conflicting-outputs

# `dart build cli` (not `dart compile exe`): package:sqlite3 ships its native
# library through a build hook, which only `dart build` runs. The bundle is
# bin/jay_archiver + lib/libsqlite3.so (see hermes_bridge's Dockerfile, which
# hit the same requirement first).
RUN cd bots/jay_archiver \
 && dart pub get \
 && dart build cli -o /out

# glibc base: the AOT binary and the bundled libsqlite3 are dynamically linked.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home bot \
 && mkdir /data && chown bot /data
COPY --from=build /out/bundle /app
USER bot
# Keys + SQLite live here — mount a volume, or every restart starts from an
# empty store (no device, or a device the org's auditor setting no longer
# matches). No secrets are baked into the image; BOT_STORE_KEY is supplied
# at runtime by the operator's compose/orchestrator, never committed.
VOLUME /data
ENTRYPOINT ["/app/bin/jay_archiver"]
# No default CMD: the compose file supplies "run --state /data/archiver"
# (JAY_API_URL / JAY_ORG_ID / BOT_STORE_KEY come from the environment, see
# lib/src/cli_options.dart) so it's explicit in one place. `docker run` with
# no command prints the usage text and exits 64, which is what a first-time
# operator should see rather than a silent wrong default.
