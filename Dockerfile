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
        libluajit-5.1-dev \
        zlib1g-dev \
        ca-certificates

# Debian's luajit binary is 2.1.0~beta3 (2022) and cannot parse the compound
# assignment operators (+=, -=) PoB's src now uses. Build a current LuaJIT into
# /usr/local (which is copied into the runtime stage). The libluajit-5.1-dev
# headers above are only used to compile the C rocks below (stable Lua 5.1 ABI).
ARG LUAJIT_REF=v2.1
RUN git clone --depth 1 --branch "$LUAJIT_REF" https://github.com/LuaJIT/LuaJIT.git /tmp/luajit && \
    make -C /tmp/luajit -j"$(nproc)" PREFIX=/usr/local && \
    make -C /tmp/luajit install PREFIX=/usr/local && \
    ldconfig && \
    rm -rf /tmp/luajit

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
        luarocks \
        zlib1g-dev \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy Lua modules and app from builder (LuaJIT is built into /usr/local there)
COPY --from=builder /usr/local /usr/local
COPY --from=builder /workdir /workdir
COPY --from=gobuilder /pob-server /usr/local/bin/pob-server
RUN ldconfig

# Clean up docs, man, locale, and cache
RUN rm -rf /usr/share/doc /usr/share/man /usr/share/locale /var/cache/apt/*

EXPOSE 8080
WORKDIR /workdir

CMD ["pob-server"]
