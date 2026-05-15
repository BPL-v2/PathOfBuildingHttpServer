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

    local configAutoDetect = loadSharedModule(repositoryRoot, "Modules", "ConfigAutoDetect.lua")()
    mainObject.continuousIntegrationMode = os.getenv("CI")
    runCallback("OnInit")
    runCallback("OnFrame")
    if mainObject.promptMsg then
        error(mainObject.promptMsg)
    end

    return mainObject.main.modes["BUILD"], configAutoDetect
end

local function loadHttpServer(repositoryRoot)
    return loadSharedModule(repositoryRoot, "HttpServer.lua")()
end

local function normalizeBandit(value)
    local validBandits = {
        None = true,
        Oak = true,
        Kraityn = true,
        Alira = true,
    }
    if type(value) == "string" and validBandits[value] then
        return value
    end
    return "None"
end

local pantheonNameToKey = {
    ["The Brine King"] = "TheBrineKing",
    ["Lunaris"] = "Lunaris",
    ["Solaris"] = "Solaris",
    ["Arakaali"] = "Arakaali",
    ["Gruthkul"] = "Gruthkul",
    ["Yugul"] = "Yugul",
    ["Abberath"] = "Abberath",
    ["Tukohama"] = "Tukohama",
    ["Garukhan"] = "Garukhan",
    ["Ralakesh"] = "Ralakesh",
    ["Ryslatha"] = "Ryslatha",
    ["Shakari"] = "Shakari",
}

local function normalizePantheon(value)
    if type(value) ~= "string" then
        return "None"
    end
    if value == "None" then
        return "None"
    end
    if data and data.pantheons and data.pantheons[value] then
        return value
    end
    local mappedValue = pantheonNameToKey[value]
    if mappedValue and data and data.pantheons and data.pantheons[mappedValue] then
        return mappedValue
    end
    return "None"
end

local function selectHighestFullDpsSocketGroup(build)
    if not build or not build.skillsTab or not build.skillsTab.socketGroupList then
        return
    end

    local socketGroupList = build.skillsTab.socketGroupList
    if #socketGroupList == 0 then
        return
    end

    if not build.calcsTab.mainOutput or not build.calcsTab.mainEnv then
        build.calcsTab:BuildOutput()
    end

    local skillDpsList = build.calcsTab.mainOutput and build.calcsTab.mainOutput.SkillDPS
    local activeSkillList = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player and build.calcsTab.mainEnv.player.activeSkillList
    if not skillDpsList or not activeSkillList then
        return
    end

    local function countSupportGems(socketGroup)
        local count = 0
        if socketGroup and socketGroup.gemList then
            for _, gem in ipairs(socketGroup.gemList) do
                if gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support then
                    count = count + 1
                end
            end
        end
        return count
    end

    local bestSocketGroup
    local bestIndex
    local bestDps = -1

    for _, skillData in ipairs(skillDpsList) do
        local skillDps = (skillData.dps or 0) * (skillData.count or 1)
        local matchedSocketGroup
        local matchedSupportCount = -1
        local source = skillData.source
        if source == nil or source == "" then
            source = skillData.name
        end

        for _, activeSkill in ipairs(activeSkillList) do
            if activeSkill.socketGroup
                and activeSkill.activeEffect
                and activeSkill.activeEffect.grantedEffect
                and activeSkill.activeEffect.grantedEffect.name == source then
                local supportCount = countSupportGems(activeSkill.socketGroup)
                if supportCount > matchedSupportCount then
                    matchedSupportCount = supportCount
                    matchedSocketGroup = activeSkill.socketGroup
                end
            end
        end

        if matchedSocketGroup and skillDps > bestDps then
            bestDps = skillDps
            bestSocketGroup = matchedSocketGroup
        end
    end

    for index, socketGroup in ipairs(socketGroupList) do
        local isBest = socketGroup == bestSocketGroup
        socketGroup.includeInFullDPS = isBest
        if isBest then
            bestIndex = index
        end
    end

    if bestIndex then
        build.mainSocketGroup = bestIndex
    end
    build.calcsTab:BuildOutput()
end

local function applyConfigAndExport(build, configAutoDetect)
    for _, socketGroup in ipairs(build.skillsTab.socketGroupList) do
        socketGroup.includeInFullDPS = true
        for _, gem in ipairs(socketGroup.gemList) do
            if gem.nameSpec and gem.nameSpec:match("^Vaal ") then
                gem.enableGlobal1 = false
                gem.enableGlobal2 = true
            else
                gem.enableGlobal1 = true
                gem.enableGlobal2 = false
            end
        end
    end

    local configStartTime = GetTime()
    configAutoDetect:Apply(build)
    local configEndTime = GetTime()
    ConPrintf("ConfigAutoDetect took %.3f seconds", configEndTime - configStartTime)

    build.configTab.input.conditionCritRecently = true
    build.itemsTab.build.buildFlag = true
    build.itemsTab.modFlag = true
    build.configTab:BuildModList()
    build.buildFlag = true
    runCallback("OnFrame")

    selectHighestFullDpsSocketGroup(build)

    local xml = build:SaveDB("code")
    local compressed = Deflate(xml)
    local base64 = common.base64.encode(compressed)
    return base64:gsub("+", "-"):gsub("/", "_")
end

local configKeysToReset = {
    "useFrenzyCharges", "usePowerCharges", "useEnduranceCharges",
    "useChallengerCharges", "useBlitzCharges", "inspirationCharges",
    "conditionFullLife", "conditionLowLife", "conditionFullEnergyShield",
    "conditionLeeching", "conditionLeechingLife", "conditionLeechingEnergyShield",
    "conditionHaveTotem", "conditionKilledRecently", "conditionOnConsecratedGround",
    "conditionAtCloseRange", "conditionCritRecently", "conditionConsumedCorpseRecently",
    "conditionSpawnedCorpseRecently",
    "buffOnslaught", "buffInfusion", "buffFortify", "buffFortification", "buffTailwind",
    "buffUnholyMight", "arcaneSurgeCheck", "arcaneCloakUsedRecentlyCheck",
    "feedingFrenzyFeedingFrenzyActive",
    "rageAmount", "multiplierRage", "intensifyStacks", "intensifyIntensity",
    "multiplierWitherStack", "multiplierWitheredStackCount", "skillStage",
    "sigilOfPowerStages", "frostShieldStages", "configResonanceCount",
    "multiplierCorpseConsumedRecently", "multiplierNearbyCorpse",
    "conditionEnemyTaunted", "conditionEnemyIntimidated", "conditionEnemyMaimed",
    "conditionEnemyPoisoned", "conditionEnemyBlinded", "conditionEnemyCrushed",
    "conditionEnemyUnnerved", "conditionEnemyChilled", "conditionEnemyFrozen",
    "conditionEnemyShocked", "conditionEnemyIgnited", "conditionEnemyBleeding",
    "conditionEnemyCoveredInAsh", "conditionEnemyCoveredInFrost",
    "conditionEnemyDebilitated", "conditionEnemyLowLife",
    "aspectOfTheSpider", "aspectOfTheSpiderWebStacks", "prideEffect",
    "brandAttachedToEnemy", "iceNovaCastOnFrostbolt",
    "conditionManastormBuffActive", "recentManaSpent", "projectileDistance",
    "DisableEHPGainOnBlock",
}

local function buildClassIndex(build)
    local classToId = { }
    local ascendancyToClass = { }
    local ascendancyToId = { }
    local treeClasses = build and build.spec and build.spec.tree and build.spec.tree.classes
    if not treeClasses then
        error("PoB runtime did not expose passive tree classes.")
    end

    for classId, class in pairs(treeClasses) do
        if type(classId) == "number" and type(class) == "table" and type(class.name) == "string" then
            classToId[class.name] = classId
            if class.classes then
                for ascendancyId, ascendancy in pairs(class.classes) do
                    if type(ascendancyId) == "number"
                        and ascendancyId ~= 0
                        and type(ascendancy) == "table"
                        and type(ascendancy.name) == "string" then
                        ascendancyToClass[ascendancy.name] = class.name
                        ascendancyToId[ascendancy.name] = ascendancyId
                    end
                end
            end
        end
    end

    return {
        classToId = classToId,
        ascendancyToClass = ascendancyToClass,
        ascendancyToId = ascendancyToId,
    }
end

local function resolveCharacterClass(characterClassName, classIndex)
    if type(characterClassName) ~= "string" or characterClassName == "" then
        return nil, nil, "Character is missing class information."
    end

    local baseClassName = classIndex.ascendancyToClass[characterClassName]
    if baseClassName then
        return classIndex.classToId[baseClassName], classIndex.ascendancyToId[characterClassName]
    end

    local classId = classIndex.classToId[characterClassName]
    if classId ~= nil then
        return classId, 0
    end

    return nil, nil, "Unsupported character class '" .. characterClassName .. "' for this PoB runtime."
end

local function handleUpdateConfig(client, body, build, configAutoDetect, httpServer)
    local startTime = GetTime()

    if not body or body == "" then
        httpServer.sendError(client, "400 Bad Request", "Empty request body. Send PoB code as plain text.")
    end

    local pobCode = body:gsub("^%s+", ""):gsub("%s+$", "")
    local xmlText = Inflate(common.base64.decode(pobCode:gsub("-", "+"):gsub("_", "/")))
    if not xmlText then
        httpServer.sendError(client, "400 Bad Request", "Invalid PoB code.")
    end

    build:Shutdown()
    build:Init(false, "Imported build", xmlText)

    for _, key in ipairs(configKeysToReset) do
        build.configTab.input[key] = nil
    end

    local urlsafe = applyConfigAndExport(build, configAutoDetect)
    ConPrintf("PoB auto config processed in %.3f seconds", GetTime() - startTime)
    httpServer.sendResponse(client, "200 OK", "text/plain", urlsafe)
end

local function handleImportCharacter(client, body, build, configAutoDetect, classIndex, httpServer)
    local json = require("lua.dkjson")
    local startTime = GetTime()
    local ok, character = pcall(json.decode, body)
    if not ok or not character then
        httpServer.sendError(client, "400 Bad Request", "Invalid JSON. Expecting PoB character JSON.")
    end

    local characterClass, ascendancy, classError = resolveCharacterClass(character.class, classIndex)
    if classError then
        httpServer.sendError(client, "400 Bad Request", classError)
    end

    print("processing character " .. tostring(character.name))

    local itemsJson = json.encode({
        items = character.equipment or {},
        jewels = character.jewels or {},
        character = {
            name = character.name,
            realm = character.realm,
            class = character.class,
            league = character.league,
            level = character.level,
        },
    })

    local passives = character.passives or {}
    local treeJson = json.encode({
        character = characterClass,
        ascendancy = ascendancy,
        alternate_ascendancy = passives.alternate_ascendancy or 0,
        hashes = passives.hashes or {},
        hashes_ex = passives.hashes_ex or {},
        mastery_effects = passives.mastery_effects or {},
        skill_overrides = passives.skill_overrides or {},
        items = character.jewels or {},
        jewel_data = passives.jewel_data or {},
    })

    build.importTab.lastLeague = character.league
    local charDataObj = build.importTab:ImportItemsAndSkills(itemsJson)
    build.importTab:ImportPassiveTreeAndJewels(treeJson, charDataObj)

    build.configTab.input.bandit = normalizeBandit(passives.bandit_choice)
    build.configTab.input.pantheonMajorGod = normalizePantheon(passives.pantheon_major)
    build.configTab.input.pantheonMinorGod = normalizePantheon(passives.pantheon_minor)

    local urlsafe = applyConfigAndExport(build, configAutoDetect)
    print(string.format("Request processed in %.3f seconds", GetTime() - startTime))
    httpServer.sendResponse(client, "200 OK", "text/plain", urlsafe)
end

local function serve(options)
    local cliOptions = parseArgs(arg or {})
    local repositoryRoot = trimTrailingSlash(assert(options.repositoryRoot, "Missing repositoryRoot"))
    local pobRoot = discoverPobRoot(repositoryRoot, options.defaultPobRoot or cliOptions.pobRoot)
    local host = cliOptions.host or options.host or os.getenv("POB_SERVER_HOST") or "*"
    local port = cliOptions.port or options.port or tonumber(os.getenv("POB_SERVER_PORT")) or 8080

    local build, configAutoDetect = initializePob(repositoryRoot, pobRoot)
    local classIndex = buildClassIndex(build)
    local httpServer = loadHttpServer(repositoryRoot)

    httpServer.serve({
        host = host,
        port = port,
        handleRequest = function(client, request, responders)
            if request.method ~= "POST" then
                responders.sendError(client, "405 Method Not Allowed", "Only POST supported.")
            end

            if request.path == "/update-config" then
                handleUpdateConfig(client, request.body, build, configAutoDetect, responders)
            else
                handleImportCharacter(client, request.body, build, configAutoDetect, classIndex, responders)
            end
        end,
    })
end

return serve
