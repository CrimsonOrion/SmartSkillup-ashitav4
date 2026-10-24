--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: Player data now comes from Ashita's memory manager. Windower's 'gain buff', 'lose buff', 'status change',
'job change', 'level up', 'zone change' and 'add/remove item' events don't exist in Ashita, so poll_state() diffs memory
every frame and fires the same handlers.]]

-- This is me data; a gutted player var packed with skillup related flags. Arrrr, me mateys.

local bit = require('bit')

-------------------------------------------------------------------------------------------------------------------
-- Me and it's associated external variables
-------------------------------------------------------------------------------------------------------------------
me = {}
known_spells = {} -- keep these separate to avoid bloating me data (keyed by spell id)
buffactive = {} -- keyed by buff id

local mm = AshitaCore:GetMemoryManager()



-------------------------------------------------------------------------------------------------------------------
-- Small entity helpers (Windower's get_mob_by_target replacements)
-------------------------------------------------------------------------------------------------------------------
function is_trust(entity)
	-- SpawnFlags: 0x02 NPC, 0x04 in-party. A party NPC is a trust. (Windower spawn_type 14)
	return entity ~= nil and bit.band(entity.SpawnFlags, 0x02) ~= 0 and bit.band(entity.SpawnFlags, 0x04) ~= 0
end

function is_mob(entity)
	-- SpawnFlags 0x10: monster (Windower spawn_type 16)
	return entity ~= nil and bit.band(entity.SpawnFlags, 0x10) ~= 0
end

function get_pet()
	local player = GetPlayerEntity()
	if player == nil or player.PetTargetIndex == 0 then return nil end
	return GetEntity(player.PetTargetIndex)
end

function get_party_member_entity(i)
	local party = mm:GetParty()
	if party:GetMemberIsActive(i) == 0 then return nil end
	local index = party:GetMemberTargetIndex(i)
	if index == 0 then return nil end
	return GetEntity(index)
end

function distance(entity)
	return math.sqrt(entity.Distance)
end

-- CREDIT: Ashita's lin/ffxi.lua (also used by imrecast, wheel, and xitools)
local event_system = ashita.memory.find('FFXiMain.dll', 0, 'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 0, 0)
function is_event_happening() -- returns nil if the signature wasn't found
	if event_system == 0 then return nil end
	local ptr = ashita.memory.read_uint32(event_system + 1)
	if ptr == 0 then return false end
	return ashita.memory.read_uint8(ptr) == 1
end



-------------------------------------------------------------------------------------------------------------------
-- Builds the me table from memory and adds in additional flags
-------------------------------------------------------------------------------------------------------------------
function build_me_table()
	local player, party = mm:GetPlayer(), mm:GetParty()
	local entity = GetPlayerEntity()
	me = {
		id             = party:GetMemberServerId(0),
		main_job_id    = player:GetMainJob(),
		main_job_level = player:GetMainJobLevel(),
		sub_job_id     = player:GetSubJob(),
		sub_job_level  = player:GetSubJobLevel(),
		status_id      = entity and entity.Status or 0,
		zone_id        = party:GetMemberZone(0),
		JA_locked      = false,
	}
	me.main_job, me.sub_job = res.job_abbr(me.main_job_id), res.job_abbr(me.sub_job_id)
	update_me_vitals()

	-- MOVE BUFFS TO BUFFACTIVE
	buffactive = {}
	for _, id in ipairs(current_buff_ids()) do
		buffactive[id] = true
		util.schedule(2, process_buff_change, id, true) -- allow modules to initialize
	end

	-- DETECT PAUSE EVENT VIA STATUS (newStatus, oldStatus, newStatusId, oldStatusId)
	me.status = res.status_name(me.status_id)
	process_status_events(me.status, nil, me.status_id)

	-- ADD/MANIPULATE VARIOUS DATA
	me.zone = res.zone_name(me.zone_id)
	me.in_town = util.contains(statics.cities, me.zone) and me.zone or false

	-- ADD DATA VIA HELPER FUNCTIONS
	update_me_party()
	update_me_food_locations(true)
	update_best_cures()
	update_me_blu_spells()
	me.food_signature = food_signature()
end



-------------------------------------------------------------------------------------------------------------------
-- Reads the player's current buff ids from memory
-------------------------------------------------------------------------------------------------------------------
function current_buff_ids()
	local ids = {}
	for _, id in pairs(mm:GetPlayer():GetBuffs()) do
		if id ~= nil and id >= 0 and id ~= 255 then ids[#ids+1] = id end
	end
	return ids
end



-------------------------------------------------------------------------------------------------------------------
-- Rebuilds me's party table and sets the me.can_summon_trusts and me.has_trust_target flags
-------------------------------------------------------------------------------------------------------------------
function update_me_party()
	local party = mm:GetParty()
	me.party = {}
	me.has_trust_target = false
	local in_alliance, count = false, 0
	for i = 6, 17 do
		if party:GetMemberIsActive(i) ~= 0 then in_alliance = true end
	end
	for i = 0, 5 do
		if party:GetMemberIsActive(i) ~= 0 then
			-- RECORD MEMBER
			count = count + 1
			local name = party:GetMemberName(i)
			me.party[#me.party+1] = name

			-- SET TRUST TARGET FLAG
			local entity = get_party_member_entity(i)
			if not me.has_trust_target and is_trust(entity) and not util.contains(statics.untargetable_trusts, name) then
				me.has_trust_target = true
			end
		end
	end
	local is_leader = bit.band(party:GetMemberFlagMask(0), 4) == 4
	me.can_summon_trusts = not in_alliance and (count == 1 or is_leader)
end



-------------------------------------------------------------------------------------------------------------------
-- Rebuilds me's food_locations immediately on item use and delayed on item moves
-- Frontloaded to do the processing on the rare event (item move/use) and no processing on the common event (make_decision)
-------------------------------------------------------------------------------------------------------------------
local function food_tier_by_id(id)
	for tier, food in ipairs(statics.skillup_foods) do
		if food.id == id then return tier, food end
	end
	return nil
end

-- A cheap fingerprint of skillup food counts, polled to detect item moves/uses (no 'add/remove item' event in Ashita)
function food_signature()
	local inv, sig = mm:GetInventory(), {}
	for _, bag in ipairs(statics.bags_ordered) do
		for slot = 1, inv:GetContainerCountMax(bag.id) do
			local item = inv:GetContainerItem(bag.id, slot)
			if item ~= nil and item.Id ~= 0 and food_tier_by_id(item.Id) then
				sig[#sig+1] = bag.id .. ':' .. slot .. ':' .. item.Id .. 'x' .. item.Count
			end
		end
	end
	return table.concat(sig, ',')
end

function update_me_food_locations(immediate, item_used)
	-- ITEM ADD/REMOVE/USE: IGNORE NON-SKILLUP-FOOD ITEM USES
	if item_used and not food_tier_by_id(item_used.id) then
		return logger(chat_colors.purple, '[MISC ITEM MOVED] Ignoring non-skillup food item "' .. item_used.en .. '".', true)

	-- ITEM ADD/REMOVE/USE: RESCHEDULE TO IGNORE ITEM ADD/REMOVE/USE SPAM
	elseif not immediate then
		util.cancel(threads.update_me_food_locations) -- only process last event in spam scenario
		threads.update_me_food_locations = util.schedule(3, update_me_food_locations, true, item_used)
		return logger(chat_colors.purple, '[SKILLUP FOOD MOVED] Rebuilding food locations in 3 secs...', true)
	end

	-- BUILD FOOD LOCATIONS & HAS_SKILLUP_FOOD FLAG
	logger(chat_colors.purple, '[FOOD LOCATION UPDATE] Rebuilding food locations' .. (item_used and ' due to "' .. item_used.en .. '" usage' or '') .. '...', true)
	local inv = mm:GetInventory()
	local food_locations = {} -- [food_tier][bag_tier] = {slots}
	for food_tier in ipairs(statics.skillup_foods) do
		food_locations[food_tier] = {}
		for bag_tier in ipairs(statics.bags_ordered) do food_locations[food_tier][bag_tier] = {} end
	end
	me.has_skillup_food = false
	me.inventory_full = inv:GetContainerCount(0) >= inv:GetContainerCountMax(0) -- cache to reduce use_module's processing
	-- LOOP THROUGH ENABLED ITEM BAGS
	for bag_tier, bag in ipairs(statics.bags_ordered) do
		for slot = 1, inv:GetContainerCountMax(bag.id) do -- a max of 0 means the bag is not enabled
			local item = inv:GetContainerItem(bag.id, slot)
			local food_tier = item ~= nil and item.Id ~= 0 and food_tier_by_id(item.Id)
			if food_tier then
				table.insert(food_locations[food_tier][bag_tier], slot)
				me.has_skillup_food = true
			end
		end
	end

	-- BUILD BEST/AVAILABLE FOOD FLAGS
	me.best_overall_food = nil
	me.best_inventory_food = nil
	for food_tier, food_tier_data in ipairs(food_locations) do
		for bag_tier, slots in ipairs(food_tier_data) do
			if #slots > 0 then
				local food = statics.skillup_foods[food_tier]
				-- RECORD BEST OVERALL FOOD
				if not me.best_overall_food then
					me.best_overall_food = {id = food.id, en = food.en, bag = statics.bags_ordered[bag_tier], slot = slots[1]}
				end

				-- RECORD BEST INVENTORY FOOD
				if statics.bags_ordered[bag_tier].en == 'Inventory' and not me.best_inventory_food then
					me.best_inventory_food = {id = food.id, en = food.en}
				end
			end
		end
	end

	-- DROP FOOD MODULE IF APPLICABLE
	if not me.has_skillup_food and modules and modules.food.active then
		modules.food.active = false
		logger(chat_colors.red, '[FOOD MODULE DEACTIVATED] No more skillup food in available bags.')
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Updates me's assigned BLU spells (versus known BLU spells) CREDIT: Ashita's blusets addon for the memory layout
-------------------------------------------------------------------------------------------------------------------
local blu_offset
function update_me_blu_spells()
	me.blu_spells = {}
	local is_main, is_sub = me.main_job_id == 16, me.sub_job_id == 16
	if not is_main and not is_sub then return end

	if blu_offset == nil then
		local ffi = require('ffi')
		local addr = ashita.memory.find(0, 0, 'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0)
		if addr == 0 then
			return logger(chat_colors.red, '[BLU] Unable to locate set BLU spells; Blue Magic spells will not be filtered.')
		end
		blu_offset = ffi.cast('uint32_t*', addr)[0]
	end

	local ptr = ashita.memory.read_uint32(AshitaCore:GetPointerManager():Get('inventory'))
	if ptr == 0 then return end
	ptr = ashita.memory.read_uint32(ptr)
	if ptr == 0 then return end
	local ids = ashita.memory.read_array(ptr + blu_offset + (is_main and 0x04 or 0xA0), 0x14)
	for _, id in ipairs(ids) do
		local spell = id ~= 0 and res.spell(id + 512)
		if spell then me.blu_spells[#me.blu_spells+1] = spell.en end
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Updates me's vitals
-------------------------------------------------------------------------------------------------------------------
function update_me_vitals()
	local party = mm:GetParty()
	me.hp  = party:GetMemberHP(0)
	me.mp  = party:GetMemberMP(0)
	me.hpp = party:GetMemberHPPercent(0)
	me.mpp = party:GetMemberMPPercent(0)
end



-------------------------------------------------------------------------------------------------------------------
-- Updates me's zone
-------------------------------------------------------------------------------------------------------------------
function update_me_zone(new_id)
	me.zone_id = new_id
	me.zone = res.zone_name(new_id)
	me.in_town = util.contains(statics.cities, me.zone) and me.zone or false
	me.zoning = true
	util.schedule(2, function() me.zoning = nil end)
end



------------------------------------------------------------------------------------------------------------------
-- Updates to various me's coords
-------------------------------------------------------------------------------------------------------------------
function update_me_coords(coords)
	local old_coords = me.coords
	local was_moving = me.moving
	me.coords = coords
	me.moving = old_coords ~= nil and (coords.x ~= old_coords.x or coords.y ~= old_coords.y or coords.z ~= old_coords.z)

	-- RETURN: FIRST OCCURRENCE
	if old_coords == nil then
		me.moving = false --needs to be initialized
		return logger(chat_colors.purple, '[COORDS] Exited on first occurrence.', true)

	-- BEGAN MOVING
	elseif me.moving and was_moving == false then
		pause_event('Moving')

	-- FINISHED MOVING
	elseif was_moving and me.moving == false then
		unpause_event('Moving', 1)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Updates me's job data on job change
-------------------------------------------------------------------------------------------------------------------
function update_me_job(main_job_id, main_job_level, sub_job_id, sub_job_level)
	me.main_job, me.main_job_id, me.main_job_level = res.job_abbr(main_job_id), main_job_id, main_job_level
	me.sub_job, me.sub_job_id, me.sub_job_level = res.job_abbr(sub_job_id), sub_job_id, sub_job_level
	logger(chat_colors.purple, '[JOB CHANGE] Job changed  to ' .. me.main_job .. main_job_level .. '/' .. me.sub_job .. sub_job_level .. ', re-initializing...', true)
	me.awaiting_initialize = true -- used to ignore false-flag cap events on job change
	util.cancel(threads.initialize)
	threads.initialize = util.schedule(0.5, initialize_sms) -- delay for memory to update (ex: for buffs to clear)
end



-------------------------------------------------------------------------------------------------------------------
-- Updates me's job levels on level up/down
-------------------------------------------------------------------------------------------------------------------
function update_me_level(main_job_level, sub_job_level)
	me.main_job_level, me.sub_job_level = main_job_level, sub_job_level
	get_valid_spells()
end



-------------------------------------------------------------------------------------------------------------------
-- Polls memory each frame and fires the handlers that Windower's events used to fire
-------------------------------------------------------------------------------------------------------------------
local next_food_poll = 0
local next_spell_poll = 0

-- A cheap fingerprint of the known-spell list (count + id sum), polled to detect newly learned spells
function known_spells_signature()
	local player, count, sum = mm:GetPlayer(), 0, 0
	for id in pairs(res.spells()) do
		if player:HasSpell(id) then count, sum = count + 1, sum + id end
	end
	return count .. ':' .. sum
end
local npc_clear_at -- when the NPC pause failsafe will fire
function poll_state()
	local player, party = mm:GetPlayer(), mm:GetParty()
	local entity = GetPlayerEntity()
	if entity == nil or party:GetMemberIsActive(0) == 0 or party:GetMemberServerId(0) == 0 then return end
	if player:GetMainJob() == 0 or player:GetIsZoning() ~= 0 then return end

	-- FIRST LOGIN/LOAD: INITIALIZE
	if not sms_initialized then
		sms_initialized = true
		return initialize_sms()
	end

	-- JOB CHANGE / LEVEL CHANGE
	local mj, ml, sj, sl = player:GetMainJob(), player:GetMainJobLevel(), player:GetSubJob(), player:GetSubJobLevel()
	if mj ~= me.main_job_id or sj ~= me.sub_job_id then
		update_me_job(mj, ml, sj, sl)
	elseif ml ~= me.main_job_level or sl ~= me.sub_job_level then
		update_me_level(ml, sl)
	end

	-- ZONE CHANGE
	local zone_id = party:GetMemberZone(0)
	if zone_id ~= 0 and zone_id ~= me.zone_id then
		update_me_zone(zone_id)
	end

	-- STATUS CHANGE
	if entity.Status ~= me.status_id then
		local old = me.status_id
		me.status_id = entity.Status
		process_status_change(entity.Status, old)
	end

	-- VITALS (& END OF RESTING SESSION) CREDIT: SMD111
	local old_mpp = me.mpp
	update_me_vitals()
	if active and me.status == 'Resting' and me.mpp == 100 and old_mpp ~= 100 and auto_resting then
		logger(chat_colors.purple, '[HEALING FINISHED] Sending the "go" command to continue.', true)
		handle_command({'go'})
	end

	-- BUFF GAINS/LOSSES (skipped while zoning, as buffs are re-sent on zone-in)
	if not event_pauses.Zoning then
		local current = {}
		for _, id in ipairs(current_buff_ids()) do current[id] = true end
		for id in pairs(current) do
			if not buffactive[id] then process_buff_change(id, true) end
		end
		for id in pairs(buffactive) do
			if not current[id] then process_buff_change(id, nil) end
		end
	end

	local now = util.now()

	-- NPC PAUSE FAILSAFE: some NPC menus (ex: Moogle job change) never send the expected unlock packet,
	-- so clear the NPC pause once no event has been running for 2 secs
	local event_happening = is_event_happening()
	if event_pauses.NPC and event_happening == false then
		npc_clear_at = npc_clear_at or now + 2
		if now >= npc_clear_at then
			npc_clear_at = nil
			logger(chat_colors.purple, '[NPC FAILSAFE] No event running; clearing the NPC pause.', true)
			unpause_event('NPC', 0)
		end
	else
		npc_clear_at = nil
	end

	-- NEWLY LEARNED SPELLS (polled every 5 secs; the "spell learned" message alone proved unreliable)
	if now >= next_spell_poll then
		next_spell_poll = now + 5
		local sig = known_spells_signature()
		if me.known_spells_signature and sig ~= me.known_spells_signature then
			get_valid_spells()
			update_best_cures()
			logger(chat_colors.purple, '[SPELL LEARNED] Known spells changed; rebuilt valid spells.', true)
		end
		me.known_spells_signature = sig
	end

	-- SKILLUP FOOD MOVED/USED (polled every 2 secs)
	if now >= next_food_poll then
		next_food_poll = now + 2
		local sig = food_signature()
		if sig ~= me.food_signature then
			me.food_signature = sig
			update_me_food_locations(true)
		end
	end
end
