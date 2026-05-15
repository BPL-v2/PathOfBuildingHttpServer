local lfs = require("lfs")

local function getScriptDir()
    local source = debug.getinfo(1, "S").source:sub(2)
    local scriptDir = source:match("(.*/)")
    if not scriptDir then
        return lfs.currentdir()
    end
    if not scriptDir:match("^/") then
        scriptDir = lfs.currentdir() .. "/" .. scriptDir
    end
    return (scriptDir:gsub("/%./", "/"):gsub("/+$", ""))
end

local repositoryRoot = getScriptDir()
local runServer = assert(loadfile(repositoryRoot .. "/pob_server/CharacterImportServer.lua"))()

runServer({
    repositoryRoot = repositoryRoot,
})
