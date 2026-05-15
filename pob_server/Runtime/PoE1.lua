local Shared = ...

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

local Runtime = {
    name = "poe1",
}

function Runtime.initialize(build, repositoryRoot, loadSharedModule)
    return {
        build = build,
        classIndex = buildClassIndex(build),
        configAutoDetect = loadSharedModule(repositoryRoot, "Modules", "ConfigAutoDetect.lua")(),
    }
end

function Runtime.handleUpdateConfig(context, client, body, responders)
    local startTime = GetTime()
    local xmlText = Shared.decodePobCode(body)
    if not xmlText then
        responders.sendError(client, "400 Bad Request", "Invalid PoB code.")
    end

    local build = context.build
    build:Shutdown()
    build:Init(false, "Imported build", xmlText)

    for _, key in ipairs(configKeysToReset) do
        build.configTab.input[key] = nil
    end

    local urlsafe = Shared.applyConfigAndExport(build, context.configAutoDetect)
    ConPrintf("PoB auto config processed in %.3f seconds", GetTime() - startTime)
    responders.sendResponse(client, "200 OK", "text/plain", urlsafe)
end

function Runtime.handleImportCharacter(context, client, body, responders)
    local json = Shared.loadJsonModule()
    local startTime = GetTime()
    local ok, character = pcall(json.decode, body)
    if not ok or not character then
        responders.sendError(client, "400 Bad Request", "Invalid JSON. Expecting PoB character JSON.")
    end

    print("processing character " .. tostring(character.name))

    local characterClass, ascendancy, classError = resolveCharacterClass(character.class, context.classIndex)
    if classError then
        responders.sendError(client, "400 Bad Request", classError)
    end

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

    local build = context.build
    build.importTab.lastLeague = character.league
    local charDataObj = build.importTab:ImportItemsAndSkills(itemsJson)
    build.importTab:ImportPassiveTreeAndJewels(treeJson, charDataObj)

    build.configTab.input.bandit = normalizeBandit(passives.bandit_choice)
    build.configTab.input.pantheonMajorGod = normalizePantheon(passives.pantheon_major)
    build.configTab.input.pantheonMinorGod = normalizePantheon(passives.pantheon_minor)

    local urlsafe = Shared.applyConfigAndExport(build, context.configAutoDetect)
    print(string.format("Request processed in %.3f seconds", GetTime() - startTime))
    responders.sendResponse(client, "200 OK", "text/plain", urlsafe)
end

return Runtime
