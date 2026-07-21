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

local function normalizeTable(value)
    if type(value) == "table" then
        return value
    end
    return { }
end

local function normalizeCharacterData(character)
    character = character or { }
    character.equipment = normalizeTable(character.equipment)
    character.jewels = normalizeTable(character.jewels)
    character.passives = normalizeTable(character.passives)
    character.passives.hashes = normalizeTable(character.passives.hashes)
    character.passives.hashes_ex = normalizeTable(character.passives.hashes_ex)
    character.passives.mastery_effects = normalizeTable(character.passives.mastery_effects)
    character.passives.skill_overrides = normalizeTable(character.passives.skill_overrides)
    character.passives.jewel_data = normalizeTable(character.passives.jewel_data)
    return character
end

local function buildClassIndex(build)
    local classToId = { }
    local ascendancyToClass = { }
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
                    end
                end
            end
        end
    end

    return {
        classToId = classToId,
        ascendancyToClass = ascendancyToClass,
    }
end

-- Validates that the character's class/ascendancy is known to this PoB runtime.
-- ImportTab.lua resolves the actual class/ascendancy ids from the name itself,
-- this is just here to produce a friendlier error than whatever it would fall
-- back to internally when the name doesn't match anything.
local function validateCharacterClass(characterClassName, classIndex)
    if type(characterClassName) ~= "string" or characterClassName == "" then
        return "Character is missing class information."
    end

    if classIndex.ascendancyToClass[characterClassName] or classIndex.classToId[characterClassName] then
        return nil
    end

    return "Unsupported character class '" .. characterClassName .. "' for this PoB runtime."
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

function Runtime.handleUpdateConfig(context, body)
    local startTime = GetTime()
    local xmlText = Shared.decodePobCode(body)
    if not xmlText then
        print("update-config failed: invalid PoB code")
        return 400, "Invalid PoB code."
    end

    local ok, result = pcall(function()
        local build = context.build
        build:Shutdown()
        build:Init(false, "Imported build", xmlText)

        for _, key in ipairs(configKeysToReset) do
            build.configTab.input[key] = nil
        end

        return Shared.applyConfigAndExport(build, context.configAutoDetect)
    end)

    if not ok then
        print("update-config failed: " .. tostring(result))
        return 400, tostring(result)
    end

    print(string.format("PoB auto config processed in %.3f seconds", GetTime() - startTime))
    return 200, result
end

function Runtime.handleImportCharacter(context, body)
    local json = Shared.loadJsonModule()
    local startTime = GetTime()
    local ok, character = pcall(json.decode, body)
    if not ok or not character then
        print("import failed: invalid JSON body")
        return 400, "Invalid JSON. Expecting PoB character JSON."
    end

    character = normalizeCharacterData(character)
    local characterName = tostring(character.name)
    print("processing character " .. characterName)

    local success, result = pcall(function()
        local classError = validateCharacterClass(character.class, context.classIndex)
        if classError then
            error(classError, 0)
        end

        local build = context.build
        -- Workers are reused across many requests, so start every import from
        -- the same blank-build state a brand new process would have (this is
        -- the same reset primitive handleUpdateConfig already relies on).
        build:Shutdown()
        build:Init(false, "Imported build")
        build.importTab.lastLeague = character.league
        build.importTab:ImportItemsAndSkills(character, true, true, false)
        build.importTab:ImportPassiveTreeAndJewels(character, true)

        return Shared.applyConfigAndExport(build, context.configAutoDetect)
    end)

    if not success then
        print("error processing character " .. characterName .. ": " .. tostring(result))
        return 400, tostring(result)
    end

    print(string.format("character %s processed in %.3f seconds", characterName, GetTime() - startTime))
    return 200, result
end

return Runtime
