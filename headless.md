# Running Path of Building in Headless Mode on Linux

This guide explains how to set up and run Path of Building (PoB) in headless mode using `HeadlessWrapper.lua` on a Linux system. This is useful for automated testing, CI, or command-line build processing.

---

## 1. Prerequisites

- **LuaJIT** (recommended) or **Lua 5.1**
- **LuaRocks** (for installing Lua modules)
- Access to the Path of Building source code

---

## 2. Install Dependencies

### Install LuaJIT and LuaRocks

```bash
sudo apt-get update
sudo apt-get install luajit luarocks
```

### Install Required Lua Modules

- **zlib** (for Deflate/Inflate support)
- **luautf8** (for UTF-8 string handling)

```bash
sudo luarocks install lua-zlib
sudo luarocks install luautf8
```

---

## 3. Prepare the Lua Runtime Environment

Path of Building's Lua code expects certain modules (like `xml`, `dkjson`, `base64`, and the `sha1` directory) to be available. These are found in the `runtime/lua/` directory of the repo.

### Symlink the Runtime Lua Directory

From the `src` directory of your PoB checkout:

```bash
cd /path/to/PathOfBuilding/src
ln -s ../runtime/lua lua
```

This makes all the required Lua modules available as `src/lua/`.

---

## 4. Set the LUA_PATH Environment Variable

To ensure Lua can find all modules, set the `LUA_PATH`:

```bash
export LUA_PATH="./?.lua;./?/init.lua;./lua/?.lua;./lua/?/init.lua;;"
```

You can add this line to your shell profile (e.g., `.bashrc`) for convenience.

---

## 5. Run HeadlessWrapper.lua

From the `src` directory, run:

```bash
luajit HeadlessWrapper.lua
```

---

## 6. Troubleshooting

- **Module not found errors:**  
  Ensure you have symlinked the `lua` directory and set `LUA_PATH` as above.
- **Missing Lua modules:**  
  Install them with `luarocks install <modulename>`.
- **`luajit: ... module 'lua-utf8' not found:`**  
  Install with `sudo luarocks install luautf8` (note: no dash in the rock name).

---

## Summary of Steps

1. Install LuaJIT and LuaRocks.
2. Install Lua modules: `lua-zlib` and `luautf8`.
3. Symlink the `runtime/lua` directory into `src` as `lua`.
4. Set `LUA_PATH` to include the `lua` directory.
5. Run `luajit HeadlessWrapper.lua` from the `src` directory.

---

## Example Setup Script

Here's a script that automates the setup (run from the project root):

```bash
sudo apt-get update
sudo apt-get install luajit luarocks
sudo luarocks install lua-zlib
sudo luarocks install luautf8
cd src
ln -s ../runtime/lua lua
export LUA_PATH="./?.lua;./?/init.lua;./lua/?.lua;./lua/?/init.lua;;"
luajit CharacterImportServer.lua
```

---

Let us know if you encounter any issues or need further automation!
