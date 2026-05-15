local function trimTrailingSlash(path)
    return (path:gsub("/+$", ""))
end

local function joinPath(base, ...)
    local path = trimTrailingSlash(base)
    for index = 1, select("#", ...) do
        local part = select(index, ...)
        if part and part ~= "" then
            path = path .. "/" .. tostring(part):gsub("^/+", "")
        end
    end
    return path
end

local function pathExists(path)
    local lfs = require("lfs")
    return lfs.attributes(path) ~= nil
end

local function directoryExists(path)
    local lfs = require("lfs")
    local attr = lfs.attributes(path)
    return attr and attr.mode == "directory"
end

local function normalizePath(base, path)
    if not path or path == "" then
        return nil
    end
    if path:match("^/") then
        return trimTrailingSlash(path)
    end
    return trimTrailingSlash(joinPath(base, path))
end

local function prependLuaPath(pobSrc, pobRoot)
    local runtimeLua = joinPath(pobRoot, "runtime", "lua")
    local pathEntries = {
        joinPath(pobSrc, "?.lua"),
        joinPath(pobSrc, "?/init.lua"),
        joinPath(pobSrc, "lua/?.lua"),
        joinPath(pobSrc, "lua/?/init.lua"),
        joinPath(runtimeLua, "?.lua"),
        joinPath(runtimeLua, "?/init.lua"),
    }
    package.path = table.concat(pathEntries, ";") .. ";" .. package.path
end

local function parseArgs(cliArgs)
    local options = { }
    local index = 1
    while cliArgs and index <= #cliArgs do
        local value = cliArgs[index]
        if value == "--pob-root" then
            index = index + 1
            options.pobRoot = cliArgs[index]
        elseif value == "--port" then
            index = index + 1
            options.port = tonumber(cliArgs[index])
        elseif value == "--host" then
            index = index + 1
            options.host = cliArgs[index]
        elseif value == "--help" or value == "-h" then
            io.stderr:write("Usage: luajit CharacterImportServer.lua [--pob-root PATH] [--host HOST] [--port PORT]\n")
            os.exit(0)
        else
            error("Unknown argument: " .. tostring(value))
        end
        index = index + 1
    end
    return options
end

local function discoverPobRoot(repositoryRoot, configuredRoot)
    local requestedRoot = configuredRoot or os.getenv("POB_ROOT")
    if requestedRoot then
        local resolvedRoot = normalizePath(repositoryRoot, requestedRoot)
        local srcPath = joinPath(resolvedRoot, "src")
        if not pathExists(joinPath(srcPath, "Launch.lua")) then
            error("PoB root does not contain src/Launch.lua: " .. resolvedRoot)
        end
        return resolvedRoot
    end

    local preferredRoot = joinPath(repositoryRoot, "PathOfBuilding")
    if pathExists(joinPath(preferredRoot, "src/Launch.lua")) then
        return preferredRoot
    end

    local lfs = require("lfs")
    local candidates = { }
    for entry in lfs.dir(repositoryRoot) do
        if entry ~= "." and entry ~= ".." then
            local candidate = joinPath(repositoryRoot, entry)
            if directoryExists(candidate) and pathExists(joinPath(candidate, "src/Launch.lua")) then
                table.insert(candidates, candidate)
            end
        end
    end

    if #candidates == 1 then
        return candidates[1]
    end
    if #candidates == 0 then
        error("Could not find a PoB checkout under " .. repositoryRoot)
    end
    error("Multiple PoB checkouts found. Set POB_ROOT or pass --pob-root.")
end

local function loadSharedModule(repositoryRoot, ...)
    return assert(loadfile(joinPath(repositoryRoot, "pob_server", ...)))
end

local function initializePob(repositoryRoot, pobRoot)
    local lfs = require("lfs")
    local pobSrc = joinPath(pobRoot, "src")
    local scriptPath = pobSrc .. "/"

    prependLuaPath(pobSrc, pobRoot)
    assert(lfs.chdir(pobSrc))

    local installHeadlessShims = loadSharedModule(repositoryRoot, "HeadlessShims.lua")()
    installHeadlessShims({ scriptPath = scriptPath })

    dofile("Launch.lua")
    mainObject.continuousIntegrationMode = os.getenv("CI")
    runCallback("OnInit")
    runCallback("OnFrame")
    if mainObject.promptMsg then
        error(mainObject.promptMsg)
    end

    return mainObject.main.modes["BUILD"]
end

local function loadHttpServer(repositoryRoot)
    return loadSharedModule(repositoryRoot, "HttpServer.lua")()
end

local function detectRuntimeFlavor(build, pobRoot)
    local classNameMap = build and build.spec and build.spec.tree and build.spec.tree.classNameMap
    if (pobRoot and pobRoot:match("PoE2"))
        or (classNameMap and (
            classNameMap.Warrior
            or classNameMap.Monk
            or classNameMap.Mercenary
            or classNameMap.Sorceress
            or classNameMap.Huntress
            or classNameMap.Druid
        )) then
        return "poe2"
    end
    return "poe1"
end

local function loadRuntimeHandler(repositoryRoot, runtimeFlavor)
    local shared = loadSharedModule(repositoryRoot, "Runtime", "Shared.lua")()
    local moduleName = runtimeFlavor == "poe2" and "PoE2.lua" or "PoE1.lua"
    return loadSharedModule(repositoryRoot, "Runtime", moduleName)(shared)
end

local function serve(options)
    local cliOptions = parseArgs(arg or {})
    local repositoryRoot = trimTrailingSlash(assert(options.repositoryRoot, "Missing repositoryRoot"))
    local pobRoot = discoverPobRoot(repositoryRoot, options.defaultPobRoot or cliOptions.pobRoot)
    local host = cliOptions.host or options.host or os.getenv("POB_SERVER_HOST") or "*"
    local port = cliOptions.port or options.port or tonumber(os.getenv("POB_SERVER_PORT")) or 8080

    local build = initializePob(repositoryRoot, pobRoot)
    local runtimeFlavor = detectRuntimeFlavor(build, pobRoot)
    local runtimeHandler = loadRuntimeHandler(repositoryRoot, runtimeFlavor)
    local runtimeContext = runtimeHandler.initialize(build, repositoryRoot, loadSharedModule)
    local httpServer = loadHttpServer(repositoryRoot)

    httpServer.serve({
        host = host,
        port = port,
        handleRequest = function(client, request, responders)
            if request.method ~= "POST" then
                responders.sendError(client, "405 Method Not Allowed", "Only POST supported.")
            end

            if request.path and request.path:match("/update%-config$") then
                runtimeHandler.handleUpdateConfig(runtimeContext, client, request.body, responders)
            else
                runtimeHandler.handleImportCharacter(runtimeContext, client, request.body, responders)
            end
        end,
    })
end

return serve
