FROM docker.io/library/debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.15.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && ln -sf /opt/zig/zig /usr/local/bin/zig \
    && rm -f /tmp/zig.tar.xz

WORKDIR /src
COPY . .

# Builds server, repl, bench, and sim into zig-out/bin.
RUN zig build -Doptimize=ReleaseFast

FROM docker.io/library/debian:bookworm-slim

ARG INCLUDE_OPTIONAL_TOOLS=true

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 tau

WORKDIR /app

COPY --from=builder /src/zig-out/bin /usr/local/bin/

RUN if [ "${INCLUDE_OPTIONAL_TOOLS}" != "true" ]; then \
      rm -f /usr/local/bin/repl /usr/local/bin/bench /usr/local/bin/sim; \
    fi

USER tau
EXPOSE 7701 7702
ENTRYPOINT ["/usr/local/bin/server"]
