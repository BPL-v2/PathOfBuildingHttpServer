# Stage 1: Build Lua modules and app
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

RUN luarocks install luaposix && \
    luarocks install luasocket && \
    luarocks install lua-zlib && \
    luarocks install luautf8 && \
    luarocks install luafilesystem

WORKDIR /workdir
COPY . /workdir

# Symlink runtime/lua into src as 'lua' for module compatibility
RUN ln -sf /workdir/PathOfBuilding/runtime/lua /workdir/PathOfBuilding/src/lua
# Symlink sha1/init.lua to sha1.lua for require('sha1') compatibility
RUN ln -sf /workdir/PathOfBuilding/src/lua/sha1/init.lua /workdir/PathOfBuilding/src/lua/sha1.lua
# Symlink /Data to Data for compatibility if needed
RUN ln -sf /workdir/PathOfBuilding/src/Data /workdir/PathOfBuilding/src/Data

# Stage 2: Minimal runtime image
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

# Clean up docs, man, locale, and cache
RUN rm -rf /usr/share/doc /usr/share/man /usr/share/locale /var/cache/apt/*

ENV LUA_PATH="/workdir/PathOfBuilding/src/lua/?.lua;/workdir/PathOfBuilding/src/?.lua;;"
EXPOSE 8080
WORKDIR /workdir

CMD ["luajit", "CharacterImportServer.lua"]
