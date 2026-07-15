# Stage 1: Build the Go front-end server
FROM golang:1.24-bookworm AS gobuilder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /pob-server .

# Stage 2: Build Lua modules and app
FROM debian:bookworm-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        unzip \
        wget \
        luarocks \
        luajit \
        libluajit-5.1-dev \
        zlib1g-dev \
        ca-certificates

RUN luarocks install lua-zlib && \
    luarocks install luautf8 && \
    luarocks install luafilesystem

WORKDIR /workdir
COPY . /workdir

# Symlink runtime/lua into src as 'lua' and sha1/init.lua as sha1.lua for
# module compatibility, for whichever runtimes are present in the context.
RUN set -eux; \
    for root in PathOfBuilding PathOfBuilding-PoE2; do \
        if [ -d "/workdir/$root/src" ]; then \
            ln -sf "/workdir/$root/runtime/lua" "/workdir/$root/src/lua"; \
            ln -sf "/workdir/$root/src/lua/sha1/init.lua" "/workdir/$root/src/lua/sha1.lua"; \
        fi; \
    done

# Stage 3: Minimal runtime image
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        luajit \
        luarocks \
        zlib1g-dev \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy Lua modules and app from builder
COPY --from=builder /usr/local /usr/local
COPY --from=builder /workdir /workdir
COPY --from=gobuilder /pob-server /usr/local/bin/pob-server

# Clean up docs, man, locale, and cache
RUN rm -rf /usr/share/doc /usr/share/man /usr/share/locale /var/cache/apt/*

EXPOSE 8080
WORKDIR /workdir

CMD ["pob-server"]
