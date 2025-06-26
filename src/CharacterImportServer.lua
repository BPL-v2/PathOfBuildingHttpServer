-- Path of Building: Concurrent Headless Import HTTP Server
-- Usage: luajit CharacterImportServer.lua

-- === Shim Functions (from HeadlessWrapper) ===
local callbackTable = { }
local mainObject
function runCallback(name, ...)
    if callbackTable[name] then
        return callbackTable[name](...)
    elseif mainObject and mainObject[name] then
        return mainObject[name](mainObject, ...)
    end
end
function SetCallback(name, func) callbackTable[name] = func end
function GetCallback(name) return callbackTable[name] end
function SetMainObject(obj) mainObject = obj end

-- Image handle and rendering stubs (minimal for headless)
local imageHandleClass = { }
imageHandleClass.__index = imageHandleClass
function NewImageHandle() return setmetatable({}, imageHandleClass) end
function imageHandleClass:Load() self.valid = true end
function imageHandleClass:Unload() self.valid = false end
function imageHandleClass:IsValid() return self.valid end
function imageHandleClass:SetLoadingPriority() end
function imageHandleClass:ImageSize() return 1, 1 end
function RenderInit() end
function GetScreenSize() return 1920, 1080 end
function SetClearColor() end
function SetDrawLayer() end
function SetViewport() end
function SetDrawColor() end
function DrawImage() end
function DrawImageQuad() end
function DrawString() end
function DrawStringWidth() return 1 end
function DrawStringCursorIndex() return 0 end
function StripEscapes(text) return text:gsub("%^%d",""):gsub("%^x%x%x%x%x%x%x","") end
function GetAsyncCount() return 0 end
function NewFileSearch() end
function SetWindowTitle() end
function GetCursorPos() return 0, 0 end
function SetCursorPos() end
function ShowCursor() end
function IsKeyDown() end
function Copy() end
function Paste() end
local zlib = require("zlib")
function Deflate(data)
    local deflater = zlib.deflate()
    return deflater(data, "finish")
end
function Inflate(data)
    local inflater = zlib.inflate()
    return inflater(data, "finish")
end
function GetTime()
    return os.clock()
end
function GetScriptPath() return "" end
function GetRuntimePath() return "" end
function GetUserPath() return "" end
function MakeDir() end
function RemoveDir() end
function SetWorkDir() end
function GetWorkDir() return "" end
function LaunchSubScript() end
function AbortSubScript() end
function IsSubScriptRunning() end
function LoadModule(fileName, ...)
    if not fileName:match("%.lua") then fileName = fileName .. ".lua" end
    local func, err = loadfile(fileName)
    if func then return func(...) else error("LoadModule() error loading '"..fileName.."': "..err) end
end
function PLoadModule(fileName, ...)
    if not fileName:match("%.lua") then fileName = fileName .. ".lua" end
    local func, err = loadfile(fileName)
    if func then return PCall(func, ...) else error("PLoadModule() error loading '"..fileName.."': "..err) end
end
function PCall(func, ...)
    local ret = { pcall(func, ...) }
    if ret[1] then table.remove(ret, 1); return nil, unpack(ret) else return ret[2] end
end
function ConPrintf(fmt, ...) print(string.format(fmt, ...)) end
function ConPrintTable(tbl, noRecurse) end
function ConExecute(cmd) end
function ConClear() end
function SpawnProcess(cmdName, args) end
function OpenURL(url) end
function SetProfiling(isEnabled) end
function Restart() end
function Exit() end

-- Patch require to avoid lcurl
local l_require = require
function require(name)
    if name == "lcurl.safe" then return end
    return l_require(name)
end

-- === PoB Initialization ===
dofile("Launch.lua")
mainObject.continuousIntegrationMode = os.getenv("CI")
runCallback("OnInit")
runCallback("OnFrame")
if mainObject.promptMsg then
    print(mainObject.promptMsg)
    os.exit(1)
end
local build = mainObject.main.modes["BUILD"]

local posix = require("posix")
local socket = require("socket")
local json = require("lua.dkjson") 

local server = assert(socket.bind("*", 8080))
local ok, err = pcall(function()
    local ancendancyToClass = {
        Ascendant = 'Scion', Juggernaut = 'Marauder', Berserker = 'Marauder', Chieftain = 'Marauder',
        Warden = 'Ranger', Deadeye = 'Ranger', Pathfinder = 'Ranger',
        Occultist = 'Witch', Elementalist = 'Witch', Necromancer = 'Witch',
        Slayer = 'Duelist', Gladiator = 'Duelist', Champion = 'Duelist',
        Inquisitor = 'Templar', Hierophant = 'Templar', Guardian = 'Templar',
        Assassin = 'Shadow', Trickster = 'Shadow', Saboteur = 'Shadow'
    }
    local ascendancyToId = {
        Ascendant = 1, Juggernaut = 1, Berserker = 2, Chieftain = 3,
        Warden = 1, Deadeye = 2, Pathfinder = 3,
        Occultist = 1, Elementalist = 2, Necromancer = 3,
        Slayer = 1, Gladiator = 2, Champion = 3,
        Inquisitor = 1, Hierophant = 2, Guardian = 3,
        Assassin = 1, Trickster = 2, Saboteur = 3
    }
    local classToId = {
        Scion = 0, Marauder = 1, Ranger = 2, Witch = 3,
        Duelist = 4, Templar = 5, Shadow = 6
    }

    while true do       
        local client = server:accept()
        local pid = posix.fork()
        if pid == 0 then
            local startTime = GetTime()
            -- Child process: handle the request
            client:settimeout(2)
            local request = {}
            while true do
                local line, err = client:receive()
                if not line or line == "" then break end
                table.insert(request, line)
            end

            -- Parse Content-Length and read body
            local content_length = 0
            for _, line in ipairs(request) do
                local len = line:match("Content%-Length:%s*(%d+)")
                if len then content_length = tonumber(len) end
            end
            local body = ""
            if content_length > 0 then
                body = client:receive(content_length)
            end

            if not request[1] or not request[1]:match("POST ") then
                local response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\n\r\nOnly POST supported."
                client:send(response)
                client:close()
                os.exit(0)
            end

            local ok, character = pcall(json.decode, body)
            if not ok or not character then
                local response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nInvalid JSON. Expecting PoB character JSON."
                client:send(response)
                client:close()
                os.exit(0)
            end
            print("processing character " .. character.name)
            local clazz = 0
            local ascendancy = 0
            if ancendancyToClass[character.class] ~= nil then
                clazz = classToId[ancendancyToClass[character.class]]
                ascendancy = ascendancyToId[character.class]
            else  
                clazz = classToId[character.class]
            end
            -- Extract items and tree from charData
            local items_json = json.encode({
                items = (character.equipment or {}),
                jewels = (character.jewels or {}),
                character = {
                    name = character.name,
                    realm = character.realm,
                    class = character.class,
                    league = character.league,
                    level = character.level
                }
            })
            local tree_json = json.encode({
                character = clazz, -- or extract from charData if available
                ascendancy = ascendancy, -- or extract from charData if available
                alternate_ascendancy = 0, -- or extract from charData if available
                hashes = character.passives and character.passives.hashes or {},
                hashes_ex = character.passives and character.passives.hashes_ex or {},
                mastery_effects = character.passives and character.passives.mastery_effects or {},
                skill_overrides = character.passives and character.passives.skill_overrides or {},
                items = character.jewels or {},
                jewel_data = character.passives and character.passives.jewel_data or {},
            })

            local charDataObj = build.importTab:ImportItemsAndSkills(items_json)
            build.importTab:ImportPassiveTreeAndJewels(tree_json, charDataObj)
            -- set bandit, pantheon major, pantheon minor
            if character.passives.bandit_choice then
                build.configTab.input.bandit = character.passives.bandit_choice
            end
            if character.passives.pantheon_major then
                build.configTab.input.pantheonMajorGod = character.passives.pantheon_major
            end
            if character.passives.pantheon_minor then
                build.configTab.input.pantheonMinorGod = character.passives.pantheon_minor
            end
            build.calcsTab:BuildOutput()
            for _, socketGroup in ipairs(build.skillsTab.socketGroupList) do
                if socketGroup.mainActiveSkill == 1 then
                    socketGroup.includeInFullDPS = true
                end
            end
            -- activate flasks
            for _, set in pairs(build.itemsTab.itemSets) do
                for k, slot in pairs(set) do
                    if k:find("Flask") then
                        slot.active = true
                    end
                end
            end
            -- set charges if character has max charge investment
            if  build.calcsTab.calcsOutput.FrenzyChargesMax > 3 then
                build.configTab.input.useFrenzyCharges = true
            end
            if  build.calcsTab.calcsOutput.EnduranceChargesMax > 3 then
                build.configTab.input.useEnduranceCharges = true
            end
            if  build.calcsTab.calcsOutput.PowerChargesMax > 3 then
                build.configTab.input.usePowerCharges = true
            end
            -- some misc settings that shouldnt inflate anyones damage realistically
            build.configTab.input.configResonanceCount ="50"
            build.configTab.input.conditionEnemyChilled = true
            build.configTab.input.conditionCritRecently = true
            build.configTab.input.brandAttachedToEnemy = true
            build.configTab.input.conditionEnemyIgnited = true
            build.configTab.input.conditionEnemyShocked = true

            local xml = build:SaveDB("code")
            print(xml)
            local compressed = Deflate(xml)
            local base64 = common.base64.encode(compressed)
            local urlsafe = base64:gsub("+", "-"):gsub("/", "_")
            local response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n" .. urlsafe
            client:send(response)
            client:close()
            local endTime = GetTime()
            ConPrintf("Request processed in %.3f seconds", endTime - startTime)
            os.exit(0)
        else
            client:close()
            posix.wait(-1, posix.WNOHANG)
        end
    end
end)
if not ok then
    print("SERVER CRASHED: " .. tostring(err))
end
print("SERVER EXITING")