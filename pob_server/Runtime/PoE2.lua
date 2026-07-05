local Shared = ...

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
    character.skills = normalizeTable(character.skills)
    character.passives = normalizeTable(character.passives)
    character.passives.hashes = normalizeTable(character.passives.hashes)
    character.passives.specialisations = normalizeTable(character.passives.specialisations)
    character.passives.skill_overrides = normalizeTable(character.passives.skill_overrides)
    character.passives.mastery_effects = normalizeTable(character.passives.mastery_effects)
    character.passives.quest_stats = normalizeTable(character.passives.quest_stats)
    character.passives.jewel_data = normalizeTable(character.passives.jewel_data)
    return character
end

local Runtime = {
    name = "poe2",
}

function Runtime.initialize(build)
    return {
        build = build,
        configAutoDetect = nil,
    }
end

function Runtime.handleUpdateConfig(context, client, body, responders)
    local startTime = GetTime()
    local xmlText = Shared.decodePobCode(body)
    if not xmlText then
        print("update-config failed: invalid PoB code")
        responders.sendError(client, "400 Bad Request", "Invalid PoB code.")
        return
    end

    local ok, result = pcall(function()
        local build = context.build
        build:Shutdown()
        build:Init(false, "Imported build", xmlText)

        return Shared.applyConfigAndExport(build, nil)
    end)

    if not ok then
        print("update-config failed: " .. tostring(result))
        responders.sendError(client, "400 Bad Request", tostring(result))
        return
    end

    ConPrintf("PoB auto config processed in %.3f seconds", GetTime() - startTime)
    responders.sendResponse(client, "200 OK", "text/plain", result)
end

function Runtime.handleImportCharacter(context, client, body, responders)
    local json = Shared.loadJsonModule()
    local startTime = GetTime()
    local ok, character = pcall(json.decode, body)
    if not ok or not character then
        print("import failed: invalid JSON body")
        responders.sendError(client, "400 Bad Request", "Invalid JSON. Expecting PoB character JSON.")
        return
    end

    character = normalizeCharacterData(character)
    local characterName = tostring(character.name)
    print("processing character " .. characterName)

    local success, result = pcall(function()
        local build = context.build
        build.importTab.lastLeague = character.league
        build.importTab:ImportItemsAndSkills(character)
        build.importTab:ImportPassiveTreeAndJewels(character)

        return Shared.applyConfigAndExport(build, nil)
    end)

    if not success then
        print("error processing character " .. characterName .. ": " .. tostring(result))
        responders.sendError(client, "400 Bad Request", tostring(result))
        return
    end

    print(string.format("character %s processed in %.3f seconds", characterName, GetTime() - startTime))
    responders.sendResponse(client, "200 OK", "text/plain", result)
end

return Runtime
