local Shared = { }

function Shared.loadJsonModule()
    local ok, json = pcall(require, "dkjson")
    if ok then
        return json
    end

    ok, json = pcall(require, "lua.dkjson")
    if ok then
        return json
    end

    error(json)
end

local function selectHighestFullDpsSocketGroup(build)
    if not build or not build.skillsTab or not build.skillsTab.socketGroupList then
        return
    end

    local socketGroupList = build.skillsTab.socketGroupList
    if #socketGroupList == 0 then
        return
    end

    for _, socketGroup in ipairs(socketGroupList) do
        socketGroup.includeInFullDPS = true
    end
    build.calcsTab:BuildOutput()

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

function Shared.applyConfigAndExport(build, configAutoDetect)
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

    if configAutoDetect then
        local configStartTime = GetTime()
        configAutoDetect:Apply(build)
        local configEndTime = GetTime()
        ConPrintf("ConfigAutoDetect took %.3f seconds", configEndTime - configStartTime)
    end

    if build.configTab and build.configTab.input and build.configTab.input.conditionCritRecently ~= nil then
        build.configTab.input.conditionCritRecently = true
    end
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

function Shared.decodePobCode(body)
    if not body or body == "" then
        return nil
    end

    local pobCode = body:gsub("^%s+", ""):gsub("%s+$", "")
    local ok, xmlText = pcall(function()
        return Inflate(common.base64.decode(pobCode:gsub("-", "+"):gsub("_", "/")))
    end)
    if not ok then
        return nil
    end
    return xmlText
end

return Shared
