-- Path of Building
--
-- Module: Config Auto Detection
-- Automatically detects and sets configuration options based on character's
-- passive skills, equipment, and active skill gems.
--

local pairs = pairs
local ipairs = ipairs

local ConfigAutoDetect = { }

-- Helper to index common patterns from any mod line
local function indexModPatterns(modLine, targetTable, source)
	if modLine:match("Gain") and modLine:match("Rage") then
		targetTable["Rage"] = source
	end
	
	if modLine:match("[Ii]ntimidate [Ee]nemies") then
		targetTable["Intimidate"] = source
	end
	
	if modLine:match("Maim on Hit") or modLine:match("[Mm]aim [Ee]nemies") then
		targetTable["Maim"] = source
	end
	
	if modLine:match("[Cc]hance to [Cc]rush") or modLine:match("[Cc]rush [Ee]nemies") then
		targetTable["Crush"] = source
	end
	
	if modLine:match("Enemies you Curse are Unnerved") or modLine:match("[Uu]nnerve [Ee]nemies") then
		targetTable["Unnerve"] = source
	end
	
    if (modLine:match("Fortify") and modLine:match("Melee Hits")) or modLine == "You have your maximum Fortification" then
        targetTable["Fortify"] = source
    end

    if (modLine:match("[Gg]ain") or modLine:match("[Gg]rant")) and not modLine:match("on [Kk]ill") then
		if modLine:match("Power") then
        	targetTable["Power Charge"] = source
		end
		if modLine:match("Frenzy") then
			targetTable["Frenzy Charge"] = source
		end
		if modLine:match("Endurance") then
			targetTable["Endurance Charge"] = source
		end
		if modLine:match("Arcane Surge") then
			targetTable["Arcane Surge"] = source
		end
		if modLine:match("Onslaught") then
			targetTable["Onslaught"] = source
		end
		if modLine:match("Unholy Might") then
			targetTable["Unholy Might"] = source
			targetTable["Wither"] = source
		end
    end

	if modLine =="Onslaught" then
		targetTable["Onslaught"] = source
	end

    if modLine:match("inflict [Ww]ithered") then
        targetTable["Wither"] = source
    end

    if modLine:match("Enemies Poisoned by you") then
        targetTable["Poisoned"] = source
    end

	if (modLine:match("[Gg]ain") or modLine:match("[Rr]ecover") ) and (modLine:match("when you [Bb]lock") or modLine:match("when you [Ss]uppress")) then
		targetTable["Disable Gain on Block"] = source
	end
	if modLine =="Life Leech effects are not removed when Unreserved Life is Filled" then
		targetTable["Full Life"] = source
	end
	if modLine =="Energy Shield Leech effects are not removed when Energy Shield is Filled" then
		targetTable["Full ES"] = source
	end

	if (modLine:match("Consecrated Ground") and modLine:match("Create")) or modLine:match("You have Consecrated Ground") then
   		targetTable["Consecrated Ground"] = source
	end

	if modLine:match("Taunt on Hit") or modLine:match("Totems Taunt") then
		targetTable["Taunt"] = source
	end

	if modLine:match("Aspect of the Spider") then
		targetTable["Aspect of the Spider"] = source
	end
	if modLine:match("Blind Enemies on Hit") then
		targetTable["Blind"] = source
	end
	if modLine:match("Minion Skill Recently") then
		targetTable["Minion Skill used Recently"] = source
	end

	if modLine:match("Cover") then
		if modLine:match("Ash") then
			targetTable["Covered in Ash"] = source
		end
		if modLine:match("Frost") then
			targetTable["Covered in Frost"] = source
		end
	end
	

end

local function collectmods(item, data)
	if not item then return end
	
	local itemName = item.title or item.name or item.baseName or "Unknown Item"
	
	if item.title then
		data.items[item.title] = true
	end
	if item.baseName then
		data.items[item.baseName] = true
	end
	if item.name then
		data.items[item.name] = true
	end
	
	if item.implicitModLines then
		for _, mod in ipairs(item.implicitModLines) do
			if mod.line then
				indexModPatterns(mod.line, data.mods, "Item: " .. itemName)
			end
		end
	end
	
	if item.explicitModLines then
		for _, mod in ipairs(item.explicitModLines) do
			if mod.line then
				indexModPatterns(mod.line, data.mods, "Item: " .. itemName)
			end
		end
	end
end

local function collectModsFromGem(gem, data)
	if not gem then return end
	
	local gemName = gem.nameSpec or gem.skillId
	local gemLevel = gem.level or 1
	local gemQuality = gem.quality or 0
	local source = "Gem: " .. gemName
	data.mods[gemName] = source

	if gemName =="Charged Traps" or 
		gemName == "Charged Mines" then
		data.mods["Frenzy Charge"] = source
		data.mods["Power Charge"] = source
	end
	if gemName:match("Power Siphon") or 
		gemName =="Flicker Strike of Power" or 
		gemName =="Cold Snap of Power " or
		gemName =="Power Charge On Critical" then
		data.mods["Power Charge"] = source
	end
	if gemName == "Assassin's Mark" and gemQuality >=4 then
		data.mods["Power Charge"] = source
	end	
	
	if gemName =="Frenzy" or
		gemName =="Frenzy of Onslaught" or
		gemName =="Flicker Strike" then
		data.mods["Frenzy Charge"] = source
	end

	if gemName == "Enduring Cry" or 
		gemName =="Endurance Charge on Melee Stun Support" then
		data.mods["Endurance Charge"] = source
	end

	if gemName =="Warlord's Mark" then
		data.mods["Rage"] = source
	end

	if gemName == "Frenzy of Onslaught" then
		data.mods["Onslaught"] = source
	end
	-- Drop intimidating cry for now since its not reliable
	if gemName == "Awakened Melee Physical Damage Support" and gemLevel >=5 then -- or gemName =="Intimidating Cry" 
		data.mods["Intimidate"] = source
	end
	if gemName == "Awakened Brutality Support" and gemLevel >=5 then
		data.mods["Crush"] = source
	end
	if gemName == "Awakened Controlled Destruction Support" and gemLevel >=5 then
		data.mods["Unnerve"] = source	
	end
	if gemName == "Wither" or gemName =="Toxic Rain of Withering" or gemName =="Withering Step" or gemName =="Withering Touch Support" then
		data.mods["Wither"] = source
	end
	if gemName:match("Poisonous Concoction") and gemQuality > 0 then
		data.mods["Wither"] = source
	end
	if gemName == "Arcane Surge" then
		data.mods["Arcane Surge"] = source
	end
	if gemName == "Vigilant Strike" or gemName == "Fortify" then
		data.mods["Fortify"] = source
	end

	if gemName:match("Cry") or gemName =="Decoy Totem" or gemName:match("Stone Golem") then
		data.mods["Taunt"] = source
	end

	if gemName =="Maim" then
		data.mods["Maim"] = source
	end

	if gemName =="Intensify" then
		data.mods["Intensify"] = source
	end
	
	if gemName:match("Brand") then
		data.mods["Brand"] = source
	end

	-- Track specific gems for config detection
	if gemName == "Close Combat" or gemName:match("Flicker Strike") then
		data.mods["Close Combat"] = source
	end

end

-- Collect all relevant data in a single pass
local function collectCharacterData(build)
	local data = {
		nodes = {},
		ascendancy = nil,
		items = {},
		mods = {},
		gems = {}
	}
	
	-- Collect ascendancy info
	if build.spec.curAscendClassName then
		data.ascendancy = build.spec.curAscendClassName
		data.ascendancyBase = build.spec.curAscendClassBaseName
	end
	
	-- Collect allocated nodes (single pass)
	for nodeId, node in pairs(build.spec.allocNodes) do
		local nodeName = node.dn or node.name
		if nodeName then
			data.nodes[nodeName] = true
		end
		-- Collect node mods from sd (stat description) array
		if node.sd then
			for _, modLine in ipairs(node.sd) do
				if modLine and type(modLine) == "string" then
					indexModPatterns(modLine, data.mods, "Node: " .. (nodeName or "Unknown"))
				end
			end
		end
		-- Collect mastery effect mods
		if node.type == "Mastery" and build.spec.masterySelections[nodeId] then
			local effectId = build.spec.masterySelections[nodeId]
			local effect = build.spec.tree.masteryEffects[effectId]
			if effect and effect.sd then
				for _, modLine in ipairs(effect.sd) do
					if modLine and type(modLine) == "string" then
						indexModPatterns(modLine, data.mods, "Mastery: " .. (nodeName or "Unknown"))
					end
				end
			end
		end
	end
	
	-- Collect equipped items (single pass)
	for _, slot in pairs(build.itemsTab.orderedSlots) do
		if not slot.inactive and slot.selItemId ~= 0 then
			local item = build.itemsTab.items[slot.selItemId]
			collectmods(item, data)
		end
	end
	
	-- Also check item sets
	for _, itemSet in pairs(build.itemsTab.itemSets) do
		for slotName, slotData in pairs(itemSet) do
			if type(slotData) == "table" and slotData.selItemId and slotData.selItemId ~= 0 then
				local item = build.itemsTab.items[slotData.selItemId]
				collectmods(item, data)
			end
		end
	end
	
	-- Collect skill gems (single pass)
	for _, socketGroup in ipairs(build.skillsTab.socketGroupList) do
		if socketGroup.enabled then
			for _, gem in ipairs(socketGroup.gemList) do
				collectModsFromGem(gem, data)
			end
		end
	end
	
	return data
end

-- Helper functions to check collected data (all O(1) lookups)
local function hasNode(data, nodeName)
	return data.nodes[nodeName] == true
end

local function hasAscendancy(data, ascendancyName)
	return data.ascendancy == ascendancyName or data.ascendancyBase == ascendancyName
end

local function hasItem(data, itemName)
	return data.items[itemName] == true
end


local function buildActiveSkillMap(env)
	local map = {}
	for _, activeSkill in ipairs(env.player.activeSkillList or {}) do
		local srcInstance = activeSkill.activeEffect and activeSkill.activeEffect.srcInstance
		if srcInstance then
			map[srcInstance] = activeSkill
		end
	end
	return map
end

local function findActiveSkillByName(env, skillName)
	for _, activeSkill in ipairs(env.player.activeSkillList or {}) do
		local grantedEffect = activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
		if grantedEffect and grantedEffect.name == skillName then
			return activeSkill
		end
	end
	return nil
end

local function getFinalCooldownSeconds(calcs, env, activeSkill)
	if not calcs or not env or not activeSkill then
		return nil
	end
	local previousMainSkill = env.player.mainSkill
	env.player.mainSkill = activeSkill
	calcs.perform(env, true)
	local cooldown = env.player.output and env.player.output.Cooldown or nil
	env.player.mainSkill = previousMainSkill
	return cooldown
end

local function getMaximumValour(build)
	local calcsTab = build.calcsTab
	if not calcsTab then
		return nil
	end
	if not calcsTab.mainEnv or not calcsTab.mainOutput then
		calcsTab:BuildOutput()
	end
	local env = calcsTab.mainEnv
	if not env or not env.modDB then
		return nil
	end
	return env.modDB:Sum("BASE", nil, "MaximumValour")
end

local function getNumberOfWarcriesPerSecond(build)
	local results = {}
	local totalWarcryRate = 0
	local calcsTab = build.calcsTab
	if not calcsTab then
		return results
	end
	if not calcsTab.mainEnv or not calcsTab.mainOutput then
		calcsTab:BuildOutput()
	end
	local env = calcsTab.mainEnv
	local calcs = calcsTab.calcs
	if not env or not calcs then
		return results
	end
	local missingCooldowns = {}
	local skillByGem = buildActiveSkillMap(env)
	for groupIndex, socketGroup in ipairs(build.skillsTab.socketGroupList) do
		if socketGroup.enabled ~= false then
			local hasAutoexertion = false
			for _, gem in ipairs(socketGroup.gemList) do
				if gem.skillId == "Autoexertion" then
					hasAutoexertion = true
					break
				end
			end
			if hasAutoexertion then
				for _, gem in ipairs(socketGroup.gemList) do
					if gem.gemData.tags.warcry and gem.skillId ~= "Autoexertion" then
						local activeSkill = skillByGem[gem.nameSpec]
						if activeSkill then
							local grantedEffect = activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
							if not grantedEffect or grantedEffect.name ~= gem.nameSpec then
								activeSkill = nil
							end
						end
						if not activeSkill then
							activeSkill = findActiveSkillByName(env, gem.nameSpec)
						end
						local cooldown = getFinalCooldownSeconds(calcs, env, activeSkill)
						if cooldown and cooldown > 0 then
							totalWarcryRate = totalWarcryRate + (1 / cooldown)
						end
					end
				end
			end
		end
	end
	return totalWarcryRate
end

-- Main function to auto-detect and apply configuration
function ConfigAutoDetect:Apply(build)
	-- Collect all data in single passes
	local data = collectCharacterData(build)
	local config = build.configTab.input
    local customConfig = ""

	if hasNode(data, "Admonisher") then
		local warcryRate = getNumberOfWarcriesPerSecond(build)
		config.multiplierWarcryUsedRecently = math.floor(4 * warcryRate)
	end

	if data.mods["Frenzy Charge"] then
		config.useFrenzyCharges = true
	end
	
	if data.mods["Power Charge"] then
		config.usePowerCharges = true
	end
	
	if data.mods["Endurance Charge"] then
		config.useEnduranceCharges = true
	end

	if data.mods["Full Life"] then
		config.conditionFullLife = true
	end
	
	if data.mods["Full ES"] then
		config.conditionFullEnergyShield = true
	end
	
	if data.mods["Onslaught"] then
		config.buffOnslaught = true
	end
	
	if data.mods["Fortify"] then
		config.buffFortification = true
	end
	
	if data.mods["Rage"] then
		local maxRage = (build.calcsTab.calcsOutput and build.calcsTab.calcsOutput.MaximumRage) or 50
		config.multiplierRage = maxRage
	end
	if hasNode(data, "Worthy Causes") then
		config.bannerValour = getMaximumValour(build)
		config.bannerPlanted = true
	end
		
	--  Disable writhing jar for now since 
	-- if hasItem(data, "The Writhing Jar") then
	-- 	config.conditionKilledRecently = true
	-- end
	
	if data.mods["Consecrated Ground"] then
		config.conditionOnConsecratedGround = true
	end
	
	if data.mods["Taunt"] then
		config.conditionEnemyTaunted = true
	end
	
	if data.mods["Intimidate"] then
		config.conditionEnemyIntimidated = true
	end
	
	if data.mods["Crush"] then
		config.conditionEnemyCrushed = true
	end
	
	if data.mods["Unnerve"] then
		config.conditionEnemyUnnerved = true
	end
	
	if data.mods["Maim"] then
		config.conditionEnemyMaimed = true
	end
	
	if data.mods["Aspect of the Spider"] then
		config.aspectOfTheSpiderWebStacks = 4
	end

	if data.mods["Blind"] then
		config.conditionEnemyBlinded = true
	end
	
	if data.mods["Poisoned"] then
		config.conditionEnemyPoisoned = true
	end
	
	if hasItem(data, "Heatshiver") then
		config.conditionEnemyFrozen = true
	end
	
	config.conditionEnemyChilled = true
	config.conditionEnemyShocked = true
	config.conditionEnemyIgnited = true
	config.conditionEnemyBleeding = true
	
	if data.mods["Covered in Ash"] then
		config.conditionEnemyCoveredInAsh = true
	end

	if data.mods["Covered in Frost"] then
		config.conditionEnemyCoveredInFrost = true
	end

	if data.mods["Intensify"] then
		config.intensifyIntensity = 4
	end
	if data.mods["Brand"] then
		config.brandAttachedToEnemy = true
	end
	
	if data.mods["Wither"] then
		config.multiplierWitheredStackCount = 15
	end

	if data.mods["Unholy Might"] then
		config.buffUnholyMight = true
	end
	
	if data.mods["Winter Orb"] then
		config.skillStage = 10
	end
	
	if data.mods["Ice Nova of Frostbolts"] then
		config.iceNovaCastOnFrostbolt = true
	end
	
	if data.mods["Sigil of Power"] then
		config.sigilOfPowerStages = 4
	end
	
	if data.mods["Frost Shield"] then
		config.frostShieldStages = 4
	end
	
	if data.mods["Pride"] then
		config.prideEffect = "MAX"
	end

    if data.mods["Arcane Cloak"] then
        config.arcaneCloakUsedRecentlyCheck = true
    end
	
    if data.mods["Arcane Surge"] then
        config.arcaneSurgeCheck = true
    end
	
    if data.mods["Close Combat"] then
        config.conditionAtCloseRange = true
    end
	if data.mods["Minion Skill used Recently"] then
		config.conditionUsedMinionSkillRecently = true
	end

	if data.mods["Blood and Sand"] then
		config.bloodSandStance = "BLOOD"
	end
	
	if data.mods["Flesh and Stone"] then
		config.bloodSandStance = "SAND"
	end
	
	if hasItem(data, "Manastorm") then
		config.conditionManastormBuffActive = true
	end
	
	if hasItem(data, "Indigon") then
		config.recentManaSpent = 8000
	end
	
	if hasNode(data, "Far Shot") then
		config.projectileDistance = 50
	elseif hasNode(data, "Point Blank") then
		config.projectileDistance = 10
	end

	if data.mods["Trinity"] then
		config.configResonanceCount = 50
	end

	if data.mods["Feeding Frenzy"] then
		config.feedingFrenzyFeedingFrenzyActive = true
	end
	
	if data.mods["Plague Bearer"] then
		config.plagueBearerState = "INF"
	end

	-- =====================
	-- Necromancer Nodes
	-- =====================
	if hasNode(data, "Plaguebringer") then
		config.conditionConsumedCorpseRecently = true
		config.multiplierNearbyCorpse = 1
	end
	if hasNode(data, "Corpse Pact") then
		config.multiplierCorpseConsumedRecently = 50
		config.conditionSpawnedCorpseRecently = true
	end
	if hasNode(data, "Essence Glutton") then
		config.conditionConsumedCorpseRecently = true
		config.multiplierNearbyCorpse = 10
	end
	if hasNode(data, "Unnatural Strength") then
		config.multiplierWitheredStackCount = 15
	end
	if hasNode(data, "Bone Barrier") then
		config.multiplierSummonedMinion = 10
	end
	

    -- =====================
    -- PUNISHMENT
    -- =====================
    if data.mods["Punishment"] then
        config.conditionEnemyDebilitated = true
        config.conditionEnemyLowLife = true
        customConfig = customConfig .. "- Punishment low life compensation:\nPunishment has 50% less curse effect\n"
    end
	
    -- =====================
    -- EHP Calculation Mode
    -- =====================
    -- Disable gain on block/suppress/hit
	if data.mods["Disable Gain on Block"] then
    	config.DisableEHPGainOnBlock = true
	end
	-- =====================
	-- FLASKS
	-- =====================
	-- Enable all flasks
	for _, slot in pairs(build.itemsTab.orderedSlots) do
		if slot.slotName and slot.slotName:match("^Flask") then
			slot.active = true
		end
	end
	local flaskBasetypes = {}
	for _, itemSet in pairs(build.itemsTab.itemSets) do
		for slotName, slotData in pairs(itemSet) do
			if type(slotName) == "string" and slotName:match("Flask") and type(slotData) == "table" then
				slotData.active = true
				local item = build.itemsTab.items[slotData.selItemId]
				if item and item.baseName then
					flaskBasetypes[item.baseName] = true
				end
			end
		end
	end
	
	-- =====================
	-- SKILL PARTS
	-- =====================
	-- Set calculation defaults for some gems
	for _, socketGroup in ipairs(build.skillsTab.socketGroupList) do
		for _, gem in ipairs(socketGroup.gemList) do
			if gem.nameSpec == "Penance Brand of Dissipation" or 
			   (gem.skillId and gem.skillId == "PenanceBrandAltX") then
				gem.skillPart = 2
			end
			if gem.nameSpec == 'Explosive Arrow' then
				gem.skillPart = 2
			end
			if gem.nameSpec == 'Rage Vortex' or gem.nameSpec == 'Rage Vortex of Berserking' then
				gem.skillPart = 2
			end
			if gem.nameSpec == 'Summon Raging Spirit' then
				gem.count = 20
			end
			if gem.nameSpec == 'Raise Spectre' then
				gem.count = 2
			end
			if gem.nameSpec == 'Raise Zombie' then
				gem.count = 6
			end
			if gem.nameSpec == 'Summon Skeletons' then
				gem.count = 7
			end
			if gem.nameSpec == 'Absolution' then
				gem.count = 3
			end
			if gem.nameSpec:match('Animate Weapon') then
				gem.count = 14
			end
			if gem.nameSpec:match("Poisonous Concoction") then
				gem.skillPart = 2
			end
			if gem.nameSpec:match("Explosive Concoction") then
				local sapphire = flaskBasetypes["Sapphire Flask"] == true
				local ruby = flaskBasetypes["Ruby Flask"] == true
				local topaz = flaskBasetypes["Topaz Flask"] == true
				if sapphire and ruby and topaz then
					gem.skillPart = 8
				elseif (topaz and ruby) then
				    gem.skillPart = 7
				elseif (sapphire and ruby) then
					gem.skillPart = 6
				elseif (sapphire and topaz) then
					gem.skillPart = 5
				elseif ruby then
					gem.skillPart = 4
				elseif topaz then
					gem.skillPart = 3
				elseif sapphire then
					gem.skillPart = 2
				else
					gem.skillPart = 1
				end
			end
			if gem.nameSpec:match("Concoction") then
				local itemsTab = build.itemsTab
				if itemsTab and itemsTab.slots then
					if itemsTab.slots["Weapon 1"] then
						itemsTab.slots["Weapon 1"]:SetSelItemId(0)
					end
					if itemsTab.slots["Weapon 1 Swap"] then
						itemsTab.slots["Weapon 1 Swap"]:SetSelItemId(0)
					end
					itemsTab:PopulateSlots()
					build.buildFlag = true
				end	
			end
			local tags = (gem.gemData and gem.gemData.tags) or {}
			if (tags.guard == true and gem.nameSpec ~= "Arcane Cloak") then
				gem.enabled = false
			end

		end
	end
    if customConfig ~= "" then
        config.customMods = customConfig
    end
	
	-- Disable notes for now to save space

	-- -- Build config sources text
	-- local sourcesText = "\n\n=== Config Auto-Detection Sources ===\n"
	-- for modKey, source in pairs(data.mods) do
	-- 	if type(source) == "string" then
	-- 		sourcesText = sourcesText .. modKey .. ": " .. source .. "\n"
	-- 	end
	-- end
	-- sourcesText = sourcesText .. "====================================="
	
	-- -- Append to notes
	-- if build.notesTab and build.notesTab.controls and build.notesTab.controls.edit then
	-- 	local currentNotes = build.notesTab.controls.edit.buf or ""
	-- 	-- Remove old auto-detection section if it exists
	-- 	currentNotes = currentNotes:gsub("\n*=== Config Auto%-Detection Sources ===.-=====================================", "")
	-- 	-- Append new section
	-- 	build.notesTab.controls.edit.buf = currentNotes .. sourcesText
	-- 	build.notesTab.lastContent = build.notesTab.controls.edit.buf
	-- end
	
	return config
end

return ConfigAutoDetect
