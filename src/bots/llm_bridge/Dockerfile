# Build context MUST be the repository's src/ directory, because the bridge
# depends on sibling packages by path:
#   docker build -f src/bots/llm_bridge/Dockerfile -t llm-bridge src
# Base images come through mirror.gcr.io (Google's Docker Hub mirror): the
# GitHub runner repeatedly timed out on auth.docker.io (run 37993841440).
FROM mirror.gcr.io/library/dart:stable AS build
WORKDIR /src
# Every path dependency of llm_bridge, dev_dependencies included (`dart pub
# get` resolves them too): calltype_core depends on calltype_protocol.
COPY client/calltype_protocol client/calltype_protocol
COPY client/calltype_core client/calltype_core
COPY bots/calltype_bot bots/calltype_bot
COPY bots/llm_bridge bots/llm_bridge

# The drift schema's *.g.dart is not committed, generate it first.
RUN cd client/calltype_core \
 && dart pub get \
 && dart run build_runner build --delete-conflicting-outputs

# `dart build cli` (not `dart compile exe`): package:sqlite3 ships its native
# library through a build hook, which only `dart build` runs. The bundle is
# bin/llm_bridge + lib/libsqlite3.so.
RUN cd bots/llm_bridge \
 && dart pub get \
 && dart build cli -o /out

# glibc base: the AOT binary and the bundled libsqlite3 are dynamically linked.
FROM mirror.gcr.io/library/debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home bot \
 && mkdir /data && chown bot /data
COPY --from=build /out/bundle /app
USER bot
# Identity store, SQLite and the encrypted chat history live here. Mount a
# volume, or every restart registers a brand-new bot identity.
# The image serves the API providers (anthropic, openai). The CLI providers
# need the owner's signed-in `claude` / `codex` on the host, so they run
# from the native bundle, not from this image.
VOLUME /data
ENV BOT_STORE_PATH=/data/bot.store
ENTRYPOINT ["/app/bin/llm_bridge"]
