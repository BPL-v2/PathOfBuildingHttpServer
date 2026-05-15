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
        responders.sendError(client, "400 Bad Request", "Invalid PoB code.")
    end

    local build = context.build
    build:Shutdown()
    build:Init(false, "Imported build", xmlText)

    local urlsafe = Shared.applyConfigAndExport(build, nil)
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

    character = normalizeCharacterData(character)
    print("processing character " .. tostring(character.name))

    local build = context.build
    build.importTab.lastLeague = character.league
    build.importTab:ImportItemsAndSkills(character)
    build.importTab:ImportPassiveTreeAndJewels(character)

    local urlsafe = Shared.applyConfigAndExport(build, nil)
    print(string.format("Request processed in %.3f seconds", GetTime() - startTime))
    responders.sendResponse(client, "200 OK", "text/plain", urlsafe)
end

return Runtime
