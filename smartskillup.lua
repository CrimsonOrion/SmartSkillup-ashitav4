--[[Copyright © 2022, RolandJ
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of SmartSkillup nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL RolandJ BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.]]

-- Ashita v4 port of the Windower SmartSkillup addon.

addon.name    = 'smartskillup'
addon.author  = 'CrimsonOrion(Ashita v4 port) (Based on RolandJ Windower addon)'
addon.version = '0.0.3-ashitaV4'
addon.desc    = 'Automatically skills up magic using your known, castable, weighted spells.'
addon.link    = 'https://github.com/CrimsonOrion/SmartSkillup-ashitav4'

require('common')



-------------------------------------------------------------------------------------------------------------------
-- Libraries used throughout the addon
-------------------------------------------------------------------------------------------------------------------
util = require('lib.util')
res = require('lib.res')
statics = require('lib.statics')
packets = require('lib.packets')
ui = require('lib.ui')
local settings_lib = require('settings')
local targets_ok, targets = pcall(require, 'ffxi.targets')
if not targets_ok then -- the lib errors if its memory signatures fail; keep <t> working without <bt>
	targets = {
		get_t = function()
			local target = AshitaCore:GetMemoryManager():GetTarget()
			return GetEntity(target:GetTargetIndex(target:GetIsSubTargetActive() == 0 and 0 or 1))
		end,
		get_bt = function() return nil end,
	}
end
require('lib.helpers')
require('lib.me')

logger = util.logger
chat_colors = util.colors
debugModes = util.debug_modes

defaults = T{
	user_ui_scalar = 1,
	top_left = T{
		x = 100,
		y = 100,
	},
	ui_hidden = false,
}
settings = settings_lib.load(defaults)

function save_settings()
	settings_lib.save()
end

settings_lib.register('settings', 'settings_update', function(s)
	if s ~= nil then settings = s end
	ui.force_pos = true
end)



-------------------------------------------------------------------------------------------------------------------
-- Variables used for generating main job skills/spells and weighting said spells
-------------------------------------------------------------------------------------------------------------------
skill_to_skillup = false -- the current skill to skillup, toggles between the skills_to_skillup if multiple are defined
skills_to_skillup = {} -- the list of skills to skillup for the current session
valid_spells = {} -- the player's main job's current list of valid spells (based on known spells & main job's level)
valid_spells_sorted = {} -- the same as above, but sorted by weight (see below for details)
ignored_spells = {} -- a bonus record of spell handling, to provide curious users better visibility ingame to how their list was compiled
main_skills = nil -- the player's current list of skill statuses. structure: {['Healing Magic'] = {level= 360, capped= true, en= 'Healing Magic', id= 33}, etc}



-------------------------------------------------------------------------------------------------------------------
-- Variables used for handling/tracking/preserving the skillup loop
-------------------------------------------------------------------------------------------------------------------
active = false -- the main on/off switch for skilling up
paused = false -- toggles true when the player pauses the session
loop = {issues=0} -- misc flags about the loop
going = false -- flags if the loop is going, used to prevent duplicate loops
auto_shutdown = false -- tracks if the auto shutdown feature is engaged
sms_initialized = false -- tracks if the addon has initialized against a logged-in character
sms_ready = false -- tracks if initialization finished (the UI waits on this)
threads = {} -- holds the handles returned by util.schedule, used for cancelling them when needed
decision = {} -- holds information about the most recent decision
auto_resting = false -- used to track when the SMS decided to /heal, to avoid interrupting full-MP player /heals
mp_limit = nil -- the MP limit module's current limit
last_cast_at = {} -- spell id -> time last cast by the loop, used to rotate equal-weight spells



-------------------------------------------------------------------------------------------------------------------
-- Modules variables: misc logic that can be added to the session
-------------------------------------------------------------------------------------------------------------------
modules_default = {
	mp_limit = {label = 'MP Limit', available = true , hidden = false}, -- first three are always available
	t_target = {label = 'T.Target', available = true , hidden = false},
	food     = {label = 'Food'    , available = true , hidden = false},
	moogle   = {label = 'Moogle'  , available = false, hidden = false, res = res.spell_by_name('Moogle')}, -- use dynamic lookups to protect against ID shifts
	refresh  = {label = 'Refresh' , available = false, hidden = false, --[[res varies]]},
	haste    = {label = 'Haste'   , available = false, hidden = false, --[[res varies]]},
	georef   = {label = 'Geo-Ref.', available = false, hidden = false, res = res.spell_by_name('Geo-Refresh')},
	sublim   = {label = 'Sublim.' , available = false, hidden = false, res = res.ability_by_name('Sublimation')},
	convert  = {label = 'Convert' , available = false, hidden = false, res = res.ability_by_name('Convert')},
	compo    = {label = 'Compos.' , available = false, hidden = true , res = res.ability_by_name('Composure')},
	radial   = {label = 'Radial.A', available = false, hidden = true , res = res.ability_by_name('Radial Arcana')},
}



-------------------------------------------------------------------------------------------------------------------
-- Functions to keep the loop/timeout mechanism functioning in a uniform/legible/debuggable manner
-------------------------------------------------------------------------------------------------------------------
function start_timeout(delay, source)
	util.cancel(threads.timeout)
	threads.timeout = util.schedule(delay or 1, process_event, {timeout=true, source=source})
	logger(chat_colors.purple, '[TIMEOUT START] Timeout started in ' .. (delay or 1) .. ' secs' .. (source and ' by ' .. source or '') .. '.', false, true)
end

function end_timeout(source)
	util.cancel(threads.timeout)
	logger(chat_colors.purple, '[TIMEOUT END] Timeout ended' .. (source and ' by ' .. source or '') .. '.', false, true)
end

function schedule_decision(delay, source, ...)
	util.cancel(threads.make_decision)
	threads.make_decision = util.schedule(delay, make_decision, source)
	if select(2, ...) then logger(...) end
end

function end_decision()
	util.cancel(threads.make_decision)
end

function end_timeout_and_decision(source, ...)
	end_timeout(source or 'end_timeout_and_decision')
	end_decision()
	if select(2, ...) then logger(...) end
end



-------------------------------------------------------------------------------------------------------------------
-- The main brains of the skillup loop/timeout CREDIT: This was only  made possible by Rubenator's extensive consultation.
-- ISSUE: If the player heals in the 0.3 secs between sending a cast command and midcasting, the cast can go through
-------------------------------------------------------------------------------------------------------------------
function process_event(event)
	if not active or paused then
		return logger(chat_colors.purple, '[EVENT CANCEL] SMS inactive or paused. (timeout: ' .. tostring(event.timeout) .. (event.stage and ', stage: ' .. event.stage .. ' ' .. event.name or '') .. ')', true)
	elseif next(event_pauses) ~= nil then
		return logger(chat_colors.purple, '[EVENT CANCEL] Event pauses active: ' .. table.concat(util.keys(event_pauses, true), ', ') .. ' (timeout: ' .. tostring(event.timeout) .. (event.stage and ', stage: ' .. event.stage .. ' ' .. event.name or '') .. ')', true)
	end

	-- TIMEOUT: AN ANTICIPATED EVENT DID NOT OCCUR
	if event.timeout then
		logger(chat_colors.purple, '[TIMEOUT] Making a new decision.', true)
		make_decision(event.source)

	-- EVENT: AN ACTUAL EVENT IS OCCURRING
	else
		local reason = event.stage:upper() .. ' EVENT' .. statics.larr .. (event.res and event.res.en or event.name):upper()
		-- PRECAST: NO SUCH EVENT
		-- MIDCAST: AN ACTION STARTED
		if event.stage == 'midcast' then
			decision.stage = 'midcast'
			local cast_time = event.res and event.res.cast_time or 0
			local aftercast_delay = cast_time * (buffactive[statics.buffs.addle] and 1.2 or 1) + 2.5
			end_timeout_and_decision(reason)
			logger(chat_colors.purple, '[' .. reason .. '] Scheduled a timeout in ' .. aftercast_delay .. ' secs.', true)
			start_timeout(aftercast_delay, reason)

		-- AFTERCAST: AN ACTION ENDED
		elseif event.stage == 'aftercast' and not me.moving then
			-- HANDLE LOOP
			decision.stage = 'aftercast'
			increment_casts(event)
			end_timeout_and_decision(reason) --E.PAUSE schedules a decision, we need to end it too on interrupts (workflow skips midcast in that case, accelerating this step)
			local delay = 3 -- the game refuses new casts for ~3 secs after a spell completes (2 secs gave "Unable to cast spells at this time")
			schedule_decision(delay, reason, chat_colors.purple, '[' .. reason .. '] Scheduled a decision in ' .. delay .. ' secs.', true)

			-- TRACK CAST COMPLETION (used to rotate equal-weight spells; failed attempts don't count)
			if event.name == 'Casting Completed' and event.res and event.res.id then
				last_cast_at[event.res.id] = util.now()
			end

			-- TRACK SUMMON COMPLETION (used to delay the avatar release)
			if event.name == 'Casting Completed' and event.res and res.skills[event.res.skill] == 'Summoning Magic' then
				me.last_summon_at = util.now()
			end

			-- TRACK ACTIVE INDICOLURE
			if (event.name == 'Casting Completed' or event.name == 'Already Active') and event.res and util.startswith(event.res.en, 'Indi-') then
				me.indicolure = event.res.en
				logger(chat_colors.purple, '[INDICOLURE] "' .. event.res.en .. '" is active...', true)
			end
		end
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Help make_decision decide if a module needs to be used right now (return true to halt the decision in favor of the module usage)
-------------------------------------------------------------------------------------------------------------------
local function cast(prefix, name, target)
	util.input(prefix .. ' "' .. name .. '"' .. (target and ' ' .. target or ''))
end

function use_module()
	local party_has = function(name) return util.contains(me.party or {}, name) end

	-- MOOGLE/TRUST-TARGET MODULES IN-TOWN NOTICE
	if me.in_town and me.can_summon_trusts then
		if modules.t_target.active and not me.has_trust_target then
			logger(chat_colors.yellow, '[TRUST TARGET MODULE] Please move out of a city in order to summon a trust to target...')
		elseif modules.moogle.active and not party_has(modules.moogle.res.en) then
			logger(chat_colors.yellow, '[MOOGLE MODULE] Please move out of a city in order to summon Moogle...')
		end
	end

	-- TRUST TARGET SUMMON MODULE
	if modules.t_target.active and me.can_summon_trusts and not me.has_trust_target and not me.in_town then
		for id, spell in pairs(res.spells()) do
			if res.is_trust_spell(spell) and known_spells[id] and spell_recast(id) == 0
			and not util.contains(statics.untargetable_trusts, spell.en) then
				logger(chat_colors.grey, '[TRUST TARGET MODULE] Summoning "' .. spell.en .. '" as a trust target...')
				if me.main_job_level < 99 then
					logger(chat_colors.yellow, '[NOTICE] You are not ilvl, so your mileage with this module may vary.')
				end
				cast(spell.prefix, spell.en, '<me>')
				return true
			end
		end

	-- MOOGLE MODULE (actual)
	elseif modules.moogle.active and me.can_summon_trusts and not party_has(modules.moogle.res.en) and not me.in_town then
		cast(modules.moogle.res.prefix, modules.moogle.res.en, '<me>')
		return true

	-- CONVERT MODULE
	elseif modules.convert.active and not me.JA_locked and me.mpp < 25 and me.mp > 0 and modules.convert.ready then
		logger(chat_colors.grey, '[CONVERT MODULE] Using "' .. modules.convert.res.en .. '"...')
		cast(modules.convert.res.prefix, modules.convert.res.en, '<me>')
		schedule_module_readiness(modules.convert)
		modules.convert.recovering = true
		return true

	-- CONVERT HP RECOVERY MODULE
	elseif modules.convert.recovering then
		local cure = me.best_cures[me.best_cure_index]
		if me.hpp > 80 or me.mp < cure.mp_cost then
			modules.convert.recovering = nil
			if me.hpp > 80 then return false end
			logger(chat_colors.yellow, '[CONVERT RECOVERY ISSUE] Not enough MP to recover.')
		elseif me.mp >= cure.mp_cost then
			me.best_cure_index = (me.best_cure_index == 1 and me.best_cures[2]) and 2 or 1
			cast(cure.prefix, cure.en, '<me>')
			return true
		end

	-- RADIAL ARCANA MODULE
	elseif modules.radial.available and not me.JA_locked and me.mpp < 60 and modules.radial.ready and get_pet() then
		logger(chat_colors.grey, '[AUTO MODULE] Using "' .. modules.radial.res.en .. '"...')
		cast(modules.radial.res.prefix, modules.radial.res.en, '<me>')
		schedule_module_readiness(modules.radial)
		return true

	-- COMPOSURE ON MODULE (before refresh/haste)
	elseif modules.compo.active and not me.JA_locked and not modules.compo.buffactive and modules.compo.ready then
		logger(chat_colors.grey, '[AUTO MODULE] Temporarily applying "Composure"...')
		if modules.refresh.active then packets.cancel_buff(statics.buffs.refresh) end
		if modules.haste.active then packets.cancel_buff(statics.buffs.haste) end
		cast(modules.compo.res.prefix, modules.compo.res.en, '<me>') --this will trigger a decision in 1.5
		schedule_module_readiness(modules.compo)
		return true

	-- REFRESH MODULE
	elseif modules.refresh.active and not buffactive[modules.refresh.res.status] and me.mp >= modules.refresh.res.mp_cost then
		logger(chat_colors.grey, '[REFRESH MODULE] Buffing self with "' .. modules.refresh.res.en .. '"...')
		cast(modules.refresh.res.prefix, modules.refresh.res.en, '<me>')
		return true

	-- HASTE MODULE
	elseif modules.haste.active and not buffactive[modules.haste.res.status] and me.mp >= modules.haste.res.mp_cost then
		logger(chat_colors.grey, '[HASTE MODULE] Buffing self with "' .. modules.haste.res.en .. '"...')
		cast(modules.haste.res.prefix, modules.haste.res.en, '<me>')
		return true

	-- COMPOSURE OFF MODULE (after refresh/haste)
	elseif buffactive[statics.buffs.composure] then
		logger(chat_colors.grey, '[AUTO MODULE] Removing "Composure"...')
		packets.cancel_buff(statics.buffs.composure) -- won't occur for 1~2 seconds
		buffactive[statics.buffs.composure] = nil -- accelerate the flag
		return use_module() -- restart module processing from the top

	-- GEO-REFRESH MODULE
	elseif modules.georef.active and not modules.georef.buffactive and not me.in_town then
		local pet = get_pet()
		-- NO LUOPAN YET
		if not pet then
			logger(chat_colors.grey, '[GEO-REFRESH MODULE] Buffing self with "' .. modules.georef.res.en .. '"...')
			cast(modules.georef.res.prefix, modules.georef.res.en, '<me>')
			modules.georef.buffactive = true -- speed up this flag
			modules.georef.warned = nil
		-- RELEASE LUOPAN
		else
			local dist = distance(pet) > 50 and '50+' or string.format("%.1f", distance(pet))
			logger(chat_colors.yellow, '[GEO-REFRESH MODULE] Luopan is out of range, releasing to recast... (' .. dist .. ' yalms)')
			util.input('/ja "Full Circle" <me>')
		end
		return true

	-- SUBLIMATION MODULE
	elseif modules.sublim.active and me.status ~= 'Resting' then
		local activated, complete = buffactive[statics.buffs.sublimation_activated], buffactive[statics.buffs.sublimation_complete]
		-- NOT ACTIVATED NOR COMPLETED & NOT HEALING SOON
		if (not activated and not complete and me.mpp > 25 and modules.sublim.ready)
		-- INCOMPLETE BUT PLAYER NEEDS TO HEAL (don't check ready, just lock the loop here till sublimation is deactivated)
		or (activated and me.mpp < 10)
		-- COMPLETE AND PLAYER NEEDS MP
		or (complete and me.mpp < 50 and modules.sublim.ready) then
			cast(modules.sublim.res.prefix, modules.sublim.res.en, '<me>')
			schedule_module_readiness(modules.sublim)
			return true
		end

	-- SKILL UP FOOD MODULE
	elseif modules.food.active and not buffactive[statics.buffs.food] and me.has_skillup_food then
		-- MAKE BEST FOOD AVAILABLE IF INVENTORY IS NOT FULL
		if not me.inventory_full and me.best_overall_food and me.best_overall_food.en ~= (me.best_inventory_food or {}).en then
			local food = me.best_overall_food
			logger(chat_colors.yellow, '[FOOD MODULE] Moving your ' .. food.bag.en .. '\'s "' .. food.en .. '" to your inventory...')
			packets.move_item(food.bag.id, food.slot, 1)
			me.best_inventory_food = {id = food.id, en = food.en}
			-- the Windower version slept 0.5s here; schedule the use instead so the move can land first
			util.schedule(1, util.input, '/item "' .. food.en .. '" <me>')
			return true
		end
		-- NOTIFY IF BEST FOOD UNAVAILABLE
		if me.best_inventory_food == nil then return false end
		if me.best_overall_food.en ~= me.best_inventory_food.en then
			logger(chat_colors.yellow, '[FOOD MODULE] Cannot access your ' .. me.best_overall_food.bag.en .. '\'s "' .. me.best_overall_food.en .. '". (' .. (me.best_overall_food.id-5888)*20 .. '% boost)')
		end
		logger(chat_colors.grey, '[FOOD MODULE] Using magic skill up food "' .. me.best_inventory_food.en .. '. (' .. (me.best_inventory_food.id-5888)*20 .. '% boost)')
		util.input('/item "' .. me.best_inventory_food.en .. '" <me>')
		return true
	end

	return false
end



-------------------------------------------------------------------------------------------------------------------
-- THE function that wears the pants and makes the decisions around here ;)
-------------------------------------------------------------------------------------------------------------------
local force_stop_cast = false -- a temp testing measure
function make_decision(source) --must be global to both A) be called from above and B) schedule itself internally
	logger(chat_colors.purple, '[MAKE DECISION] Source: ' .. tostring(source), false, true)
	-- PROCESS EXIT SCENARIOS
	if not active or paused then -- not in a skillup session
		end_timeout()
		return logger(chat_colors.purple, '[DECISION STOP] SmartSkillup ' .. (paused and 'paused' or 'not active') ..', exiting make_decision.', true)
	elseif skill_to_skillup == nil then -- skillup session with nothing to skillup
		end_timeout('no skills remaining')
		return logger(chat_colors.purple, '[DECISION STOP] CAUSE: No skill to skillup.', true)
	elseif force_stop_cast then -- a temp testing measure
		end_timeout('force stop cast')
		force_stop_cast = false
		return logger(chat_colors.purple, '[DECISION STOP] Force stopped make_decision and reset force_stop_cast var.', true)
	elseif use_module() then
		start_timeout(2.5, 'module use')
		return logger(chat_colors.purple, '[DECISION STOP] CAUSE: Module being used.', true)
	elseif skill_to_skillup == 'Summoning Magic' and get_pet() then
		-- WAIT: pet commands are refused for a moment after a summon completes
		local release_wait = 3 - (util.now() - (me.last_summon_at or 0))
		if release_wait > 0 then
			start_timeout(release_wait, 'release wait')
			return logger(chat_colors.purple, '[DECISION STOP] Waiting ' .. string.format('%.1f', release_wait) .. ' secs to release the player\'s avatar...', true)
		end
		start_timeout(1, 'release')
		util.input('/pet "Release" <me>')
		return logger(chat_colors.purple, '[DECISION STOP] Releasing the player\'s avatar...', true)
	end

	-- ROTATE EQUAL-WEIGHT SPELLS (ex: Barstone > Barwater > Baraero...) by preferring the least recently cast
	local spells = {}
	for i, spell in ipairs(valid_spells_sorted[skill_to_skillup] or {}) do spells[i] = spell end
	table.sort(spells, function(a, b)
		if a.weight ~= b.weight then return a.weight < b.weight end
		local a_last, b_last = last_cast_at[a.id] or 0, last_cast_at[b.id] or 0
		if a_last ~= b_last then return a_last < b_last end
		return a.id < b.id
	end)

	-- PROCESS MP LIMIT ISSUE
	local spells_below_limit = mp_limit and util.count(spells, function(s) return s.mp_cost <= mp_limit end)
	if mp_limit and spells_below_limit == 0 then
		handle_command({'mplimit', 'toggle', 'silent'})
		logger(chat_colors.yellow, '[MP LIMIT ISSUE] No "' .. skill_to_skillup .. '" spells available cheaper than ' .. mp_limit .. '; increasing limit')
	end

	-- DETERMINE & CAST NEXT SPELL
	decision = {min_recast = 0}
	for _, spell in ipairs(spells) do
		local recast = spell_recast(spell.id)
		-- CONTINUE: INDOCOLURE ALREADY ACTIVE
		if spell.en == me.indicolure then -- can't recast active indicolure
			logger(chat_colors.purple, 'SKIP: Skipping ' .. spell.en .. ', indicolure already active...', true)
			if mp_limit and spells_below_limit == 1 then
				handle_command({'mplimit', 'toggle', 'silent'})
				logger(chat_colors.yellow, '[MP LIMIT ISSUE] Increasing limit to allow a second indi spell.')
			end

		-- CONTINUE: SPELL AWAITING RECAST
		elseif recast > 0 then -- Spell waiting on recast
			if decision.min_recast == 0 or recast < decision.min_recast then
				decision.best_spell, decision.min_recast = spell, recast
			end

		-- BREAK: WAIT FOR TWICE AS CHEAP SPELL IF READY IN LESS THAN 1.2 SECS
		elseif decision.best_spell and spell_recast(decision.best_spell.id)/60 < 1.2 and spell.mp_cost / math.max(1, decision.best_spell.mp_cost) > 2 then
			decision.awaiting_more_efficient_spell = true
			logger(chat_colors.purple, '[SPELL BREAK] Broke on "' .. spell.en ..'" due to comparison to "' .. decision.best_spell.en .. '"...', false, true)
			break

		-- BREAK: SPELL OVER MP_LIMIT (MODULE)
		elseif mp_limit and spell.mp_cost > mp_limit then
			decision.over_mp_limit = true
			logger(chat_colors.purple, '[SPELL BREAK] Broke on "' .. spell.en ..'" due to being ' .. (spell.mp_cost - mp_limit) .. ' over the MP limit of ' .. mp_limit .. '.', false, true)
			break

		-- RETURN: CHEAPEST SPELL TOO EXPENSIVE (NEED TO REST)
		elseif me.mp < spell.mp_cost + ((modules.convert.active and modules.convert.ready) and 1 or 0) then -- ensure 1 MP is left if convert is viable
			logger(chat_colors.red, '[MP NEEDED] Insufficient MP for next spell "' .. spell.en .. '" (MP: ' .. me.mp .. '/' .. spell.mp_cost .. ')')
			decision.out_of_mp = true
			return decide_to_rest('Out of MP')
		else
			-- RESOLVE TARGET STRING (<me>, <p1>, <t>, etc)
			local target_string = (function()
				-- SELF/PARTY SPELLS (Prefer trusts for ilvl target skillup chance multiplier)
				if spell.targets.Self and spell.targets.Party then
					for i = 1, 5, 1 do
						local entity = get_party_member_entity(i)
						if is_trust(entity) and not util.contains(statics.untargetable_trusts, entity.Name) and distance(entity) <= 20 then
							return '<p' .. i .. '>'
						end
					end
					return '<me>' -- fallback target

				-- SELF-ONLY SPELLS
				elseif spell.targets.Self then
					return '<me>'

				-- ENEMY-ONLY SPELLS (Prefer <t>, fallback to <bt> for the convenience of multiboxers, but no claim botting here.)
				elseif spell.targets.Enemy then
					for _, option in ipairs({{'<t>', targets.get_t}, {'<bt>', targets.get_bt}}) do
						local ok, entity = pcall(option[2])
						entity = ok and entity or nil
						if is_mob(entity) and entity.HPPercent > 0 then
							if distance(entity) > 20 then decision.target_issue = {'Target out of range', spell.en}
							else return option[1] end
						else
							decision.target_issue = decision.target_issue or {'Unable to find target', spell.en}
						end
					end
				end
			end)()

			-- CAST SPELL IF TARGET OBTAINED
			if target_string then
				loop.issues = 0
				toggle_to_next_skill()
				cast(spell.prefix, spell.en, target_string)
				decision.res = spell
				decision.stage = 'precast'
				start_timeout(1.5, 'decision')
				logger(chat_colors.purple, '[DECISION] Attempting to cast "' .. spell.en .. '" on ' .. target_string .. '...', true)
				return true
			end
		end
	end

	-------------------------------------
	-- PAST THIS POINT: ISSUE TERRITORY
	-------------------------------------

	-- TRACK ISSUE COUNT & GET NEXT DECISION DELAY
	loop.issues = loop.issues + 1 -- reset on each successful decision
	me.session_issues = (me.session_issues or 0) + 1 -- reset on OFF
	local delay = decision.min_recast > 0 and (decision.min_recast/60) + 0.1 --[[recast issue]] or 4 --[[target issue]]

	-- RETURN: REST IF NEEDED ON 10TH ISSUE (player is probably AFK, fill-er-up!)
	if loop.issues == 10 then
		local resting = decide_to_rest('10th Issue', true)
		if resting then return end
	end

	-- DETERMINE WHEN TO NOTIFY (don't spam the player)
	local notify = (function()
		if loop.issues < 10 then -- once per issue until 10th issue
			return true
		elseif loop.issues == 10 then -- special notice on 10th issue
			util.schedule(0.2, logger, chat_colors.yellow, '[IMPORTANT] You will now only be notified once every 10 consecutive issues.')
			return true
		elseif math.fmod(loop.issues, 10) == 0 and loop.issues < 100 then -- once per 10 until 100
			return true
		elseif loop.issues == 100 then -- special notice on 100th issue
			util.schedule(0.2, logger, chat_colors.yellow, '[IMPORTANT] You will now only be notified once every 100 consecutive issues.')
			return true
		elseif math.fmod(loop.issues, 100) == 0 then -- once per 100 issues from there on out
			return true
		end
		return false
	end)()

	-- NOTIFY IF APPLICABLE
	if notify then
		local count_string = ' (Issue #' .. loop.issues .. ')'
		if decision.target_issue then
			toggle_to_next_skill()
			logger(chat_colors.yellow, '[TARGET ISSUE] ' .. decision.target_issue[1] .. ' for "' .. decision.target_issue[2] .. '".' .. count_string)
		elseif decision.min_recast > 0 then
			logger(chat_colors.purple, '[DECISION DELAY] Scheduling a retry in ' .. string.format("%.2f",delay) .. ' due to "' .. decision.best_spell.en .. '" recast timer...' .. count_string, true)
		elseif decision.over_mp_limit then
			--don't mention this?
		else
			logger(chat_colors.purple, '[DECISION ISSUE] Unable to cast, scheduling another cast in ' .. string.format("%.2f",delay) .. ' seconds...' .. count_string, true)
		end
	end

	-- SCHEDULE NEXT DECISION
	schedule_decision(delay, 'DECISION:ISSUE ' .. loop.issues)
end



-------------------------------------------------------------------------------------------------------------------
-- A function where we decide whether or not to rest after running out of MP or make_decision tries
-------------------------------------------------------------------------------------------------------------------
function decide_to_rest(source, give_countdown, override)
	source = source or 'UNDEFINED'
	logger(chat_colors.purple, '[DECIDE TO REST] Source: ' .. source, true)

	-- RETURN: POTENTIALLY VALID MOB
	if me.status == 'Engaged' then
		return logger(chat_colors.yellow, '[MP NEEDED] Cannot rest while engaged.')
	end
	for _, option in ipairs({{'t', targets.get_t}, {'bt', targets.get_bt}}) do
		local ok, mob = pcall(option[2])
		mob = ok and mob or nil
		if (option[1] == 't' and is_mob(mob) and mob.ClaimStatus == me.id and mob.HPPercent > 0)
		or (option[1] == 'bt' and is_mob(mob) and mob.HPPercent > 0 and distance(mob) < 20) then
			return logger(chat_colors.yellow, '[MP NEEDED] Cannot rest due to valid target "' .. mob.Name .. '".')
		end
	end
	-- RETURN: MP NOT NEEDED
	if not decision.out_of_mp and me.mpp > 30 then
		return logger(chat_colors.purple, '[PROCESS RESTING] CANCEL: MP Needed flag is false and player MPP above 30.', true)
	-- RETURN: ALREADY RESTING
	elseif me.status == 'Resting' or event_pauses.Resting then
		return
	end

	-- BEGIN RESTING
	loop.issues = 0
	auto_resting = true
	end_timeout_and_decision(source)
	if give_countdown then
		initialize_healing_notice(10, source .. (override and ' <30% MP' or ''), true)
	else
		util.input('/heal')
	end
	return true
end



-------------------------------------------------------------------------------------------------------------------
-- The processors for the various (polled) events and packets being monitored
-------------------------------------------------------------------------------------------------------------------
function process_status_change(newStatusId, oldStatusId)
	local newStatus, oldStatus = res.status_name(newStatusId), res.status_name(oldStatusId)
	me.status = newStatus
	process_status_events(newStatus, oldStatus, newStatusId, oldStatusId)
	processing_resting_change(newStatus, oldStatus)

	if active then
		if oldStatus == 'Resting' and not paused then
			me.getting_up = true
			util.schedule(3, function() me.getting_up = nil end)
		end

		-- PLAYER IS ENGAGED
		if newStatus == 'Engaged' then
			-- TERMINATE ANY HEALING COUNTDOWN
			terminate_healing_notice('Player engaged')
			-- ENGAGE TO UNPAUSE
			if not paused then
				begin_loop('PLAYER ENGAGED', true)
			end

		-- PLAYER IS IDLE
		elseif newStatus == 'Idle' then
			-- DISENGAGEMENT
			if oldStatus == 'Engaged' then
				if me.shutdown_awaiting_disengage then
					util.schedule(2, util.input, '/shutdown')
					return logger(chat_colors.yellow, '[AUTO-SHUTDOWN] Performing the requested /shutdown.')
				end

				local override = not auto_resting and me.mpp < 30
				if auto_resting or override then
					decide_to_rest('Player disengaged', true, override)
				end
			end
		end
	end
end

function process_action(act)
	if not act.actor_id or act.actor_id ~= me.id then return end
	local first_param = act.targets[1] and act.targets[1].actions[1].param

	-- CASTING STARTED
	if act.category == 8 and act.param ~= 28787 then
		process_event({name='Casting Started',     stage='midcast',   timeout=false, res=first_param and res.spell(first_param)})

	-- CASTING INTERRUPTED
	elseif act.category == 8 then
		process_event({name='Casting Interrupted', stage='aftercast', timeout=false}) -- no spell provided in act data

	-- CASTING COMPLETED
	elseif act.category == 4 then
		process_event({name='Casting Completed',   stage='aftercast', timeout=false, res=res.spell(act.param)})

	-- JOB ABILITY USE
	elseif act.category == 6 then
		process_event({name='Job Ability Used',    stage='aftercast', timeout=false, res={en='Job Ability'}})

	-- ITEM STARTED
	elseif act.category == 9 and act.param == 24931 then
		process_event({name='Item Started',        stage='midcast',   timeout=false, res=first_param and res.item(first_param)})

	-- ITEM INTERRUPTED
	elseif act.category == 9 then
		process_event({name='Item Interrupted',    stage='aftercast', timeout=false}) -- no item provided in act data

	-- ITEM COMPLETED
	elseif act.category == 5 then
		local item = res.item(act.param)
		process_event({name='Item Completed',      stage='aftercast', timeout=false, res=item})
		if item then update_me_food_locations(false, item) end
	end
end

function process_action_message_packet(packet) -- https://github.com/Windower/Lua/wiki/Message-IDs
	if packet.actor ~= me.id then return end

	-- UNABLE TO CAST
	if packet.message == 17 --[[Unable1]] or packet.message == 18 --[[Unable2]] then
		process_event({name='Unable to Cast',      stage='aftercast', timeout=false}) -- no spell provided in act data

	-- EFFECT ALREADY ACTIVE
	elseif packet.message == 523 then
		process_event({name='Already Active', stage='aftercast', timeout=false, res=res.spell(packet.param_1)})

	-- STANDARD/BLU SPELL LEARN MESSAGE
	elseif packet.message == 23 --[[Normal]] or packet.message == 419 --[[Blue Magic]] then
		util.schedule(1, function() -- let the known-spells memory update first
			get_valid_spells() --rebuilds list
			logger(chat_colors.purple, '[SPELL LEARNED] Rebuilt valid spells.', true)
		end)
	end
end

ashita.events.register('packet_out', 'sms_packet_out', function(e)
	if not sms_ready then return end

	-- PLAYER MOVEMENT
	if e.id == 0x015 then
		update_me_coords(packets.parse_position(e.data_modified))

	-- PLAYER CHANGED SET BLU SPELLS
	elseif e.id == 0x102 then
		util.cancel(threads.update_me_blu_spells) -- avoid processing spammed packets
		threads.update_me_blu_spells = util.schedule(7, function()
			update_me_blu_spells()
			get_valid_spells()
		end)

	-- PLAYER INCREASED A MERIT ABILITY
	elseif e.id == 0x0BE then
		util.schedule(1, determine_modules)
	end
end)

ashita.events.register('packet_in', 'sms_packet_in', function(e)
	-- ZONE OUT PACKET
	if e.id == 0x00B then
		ui.show_primitives(false)
		if sms_ready then pause_event('Zoning') end
		return

	-- ZONE IN PACKET
	elseif e.id == 0x00A then
		ui.show_primitives(true)
		if sms_ready then unpause_event('Zoning', 6) end
		return
	end

	if not sms_ready then return end

	-- SKILL INFO PACKETS
	if e.id == 0x062 then -- CREDIT: Partially SMD111
		local data = e.data_modified
		process_skill_data(function(skill_id) return packets.parse_skill(data, skill_id) end)

	-- ACTION PACKETS
	elseif e.id == 0x028 then
		process_action(packets.parse_action(e.data_modified_raw))

	-- ACTION MESSAGES
	elseif e.id == 0x029 then
		process_action_message_packet(packets.parse_action_message(e.data_modified))

	-- NPC LOCK PACKET (IDs: NPC Lock 1 & 2, String Lock)
	elseif e.id == 0x032 or e.id == 0x033 or e.id == 0x034 then
		pause_event('NPC')

	-- NPC MENU PACKET (HPs: lock > *MENU* > unlock #1 > player decision > unlock #2
	elseif e.id == 0x05C then
		me.awaiting_0x052 = true
		util.schedule(1.5, function() me.awaiting_0x052 = nil end)

	-- NPC UNLOCK PACKET
	elseif e.id == 0x052 then
		if me.awaiting_0x052 then me.awaiting_0x052 = nil return end -- ignores HP's unlock #1
		unpause_event('NPC', 1.5)

	-- PARTY STRUCTURE UPDATE PACKETS
	elseif e.id == 0x0C8 then
		util.cancel(threads.update_me_party) -- avoid processing spammed packets
		threads.update_me_party = util.schedule(1, update_me_party)
	end
end)



-------------------------------------------------------------------------------------------------------------------
-- The initialize function that is auto-called on login/load and on-job-change, and can also be called ad-hoc via /sms resetsession
-------------------------------------------------------------------------------------------------------------------
function initialize_sms()
	end_timeout_and_decision('initialize')
	active, paused, going, skill_to_skillup, skills_to_skillup = false, false, false, false, {}
	build_me_table()
	get_main_skills()
	get_valid_spells()
	determine_modules()
	process_skill_data(read_skills_from_memory())
	me.awaiting_initialize = nil
	sms_ready = true
	if settings.ui_hidden then
		logger(chat_colors.yellow, '[UI HIDDEN] The UI is hidden due to user preferences. Type "/sms uishow" to restore the UI.')
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Frame / load / unload events
-------------------------------------------------------------------------------------------------------------------
ashita.events.register('d3d_present', 'sms_present', function()
	util.process_timers()
	local ok, err = pcall(poll_state)
	if not ok then logger(chat_colors.red, '[ERROR] ' .. tostring(err)) end
	ui.render()
end)

ashita.events.register('load', 'sms_load', function()
	ui.load_font() -- fonts must be added here, never mid-frame
end)

ashita.events.register('unload', 'sms_unload', function()
	util.cancel_all()
	save_settings()
end)

ashita.events.register('command', 'sms_command', function(e)
	local args = e.command:args()
	if #args == 0 or not (args[1]:lower() == '/sms' or args[1]:lower() == '/smartskillup') then return end
	e.blocked = true
	table.remove(args, 1)
	handle_command(args)
end)



-------------------------------------------------------------------------------------------------------------------
-- All addon commands (called by the /sms chat command and by the UI)
-------------------------------------------------------------------------------------------------------------------
local function print_table(t)
	local inspect = require('inspect')
	for line in inspect(t):gmatch('[^\n]+') do
		logger(chat_colors.grey, line)
	end
end

function handle_command(cmd)
	if not sms_ready then
		return logger(chat_colors.yellow, '[WAIT] Processing, please wait... (SmartSkillup is still initializing)')
	end
	if cmd[1] == nil then cmd = {'help'} end
	logger(chat_colors.purple, '[COMMAND] ' .. table.concat(cmd, ' '), false, true)
	local sub = cmd[1]:lower()
	local function pop_silent() -- UI buttons use this
		if cmd[2] == 'silent' then table.remove(cmd, 2) return true end
		return false
	end
	---------------------------
	--[[ STANDARD COMMANDS ]]--
	---------------------------
	if util.contains({'addskill', 'adds', 'delskill', 'dels', 'rs', 'togskill', 'togs'}, sub) then
		local silent = pop_silent()
		table.remove(cmd, 1) --drop 'addskill' arg
		local toggling = sub == 'togskill' or sub == 'togs'

		-- SEARCH FOR MATCH
		local search_term = util.fuzzy(table.concat(cmd, ''))
		local main_skill, match_en, matches = nil, nil, 0
		for _, skill_en in pairs(res.skills) do
			if search_term ~= '' and util.startswith(util.fuzzy(skill_en), search_term) then -- CREDIT: SuperWarp
				main_skill, match_en, matches = main_skills[skill_en], skill_en, matches + 1
			end
		end

		-- DETERMINE CURRENT ACTION
		local adding = (toggling and not util.contains(skills_to_skillup, match_en)) or sub == 'addskill' or sub == 'adds'

		-- PROCESS EXIT SCENARIOS
		if matches ~= 1 then
			return logger(chat_colors.red, '[ERROR] ' .. matches .. ' matches found. Please try again to narrow your search to one result...')
		elseif not main_skill then
			return logger(chat_colors.red, '[DENIED] As a ' .. me.main_job .. ', you cannot skill up ' .. match_en .. '.')
		elseif adding then
			if main_skill.capped and not util.any_debug() then
				return logger(chat_colors.red, '[DENIED] ' .. match_en .. ' is currently capped. (' .. main_skill.level .. '/' .. main_skill.level .. ')')
			elseif util.contains(skills_to_skillup, match_en) then
				return logger(chat_colors.yellow, '[UNNECESSARY] "' .. match_en .. '" is already in your skillup list.')
			elseif valid_spells[match_en] == nil or next(valid_spells[match_en]) == nil then
				return logger(chat_colors.red, '[DENIED] No "' .. match_en .. '" spells available. Try /sms spellreport!')
			elseif (match_en == 'Geomancy' or match_en == 'Handbell') and 2 > util.count(valid_spells_sorted[match_en], function(s) return util.startswith(s.en, 'Indi-') end) then
				return logger(chat_colors.red, '[DENIED] Not enough indi spells to alternate. Please learn more indi spells and try again.')
			end
		elseif not util.contains(skills_to_skillup, match_en) then
			return logger(chat_colors.red, '[DENIED] ' .. match_en .. ' has not been added to the current session.')
		end

		-- ADD/REMOVE SKILL FROM SESSION
		if adding then
			table.insert(skills_to_skillup, main_skill.en)
			toggle_to_next_skill() -- this is needful, otherwise skill_to_skillup would never get an initial value
			if not silent then return logger(chat_colors.green, '[SUCCESS] Added "' .. main_skill.en .. '" to your skillup list.') end
		else
			remove_skill_from_session(main_skill.en)
			if not silent then return logger(chat_colors.green, '[SUCCESS] Removed "' .. main_skill.en .. '" from your skillup list.') end
		end
	elseif util.contains({'on', 'go', 'start', 'begin', 'commence'}, sub) then
		begin_loop('SMS GO', true)
	elseif util.contains({'off', 'come', 'stop', 'finish', 'complete'}, sub) then
		-- PROCESS EXIT SCENARIO
		if not active then
			return logger(chat_colors.red, '[DENIED] There is no active skillup session to attempt to stop.')
		end

		-- END AND PRODUCE REPORT
		logger(chat_colors.grey, '[FINISH] Skillup ending, producing your skillup report...')
		going, active, paused = false, false, false
		end_timeout_and_decision('SMS STOP')
		print_skillup_report()
	elseif util.contains({'pause', 'paused', 'pauseon', 'pauseoff'}, sub) then
		local pausing = ((sub == 'pause' or sub == 'paused') and not paused) or sub == 'pauseon'
		local silent = pop_silent()
		-- PROCESS EXIT SCENARIOS
		if not active then
			return logger(chat_colors.red, '[DENIED] There is no active skillup session to attempt to pause.')
		elseif pausing == paused then
			return logger(chat_colors.red, '[DENIED] The skillup session is already ' .. (pausing and '' or 'un') .. 'paused.')
		end

		paused = pausing

		if not silent then
			local term = pausing and 'paused' or 'unpaused'
			logger(chat_colors.yellow, '[' .. term:upper() .. '] Skillup session has been ' .. term .. '.')
		end

		if pausing then
			going = false -- don't do the inverse of this, as begin_loop is requiring going to be false
			end_timeout_and_decision('PLAYER PAUSE')
		else
			begin_loop('PLAYER UNPAUSE')
		end
	elseif sub == 'autoshutdown' then
		auto_shutdown = not auto_shutdown
		logger(chat_colors.yellow, '[AUTO-SHUTDOWN] Feature has been ' .. (auto_shutdown and 'activated; will /shutdown when last skill is capped' or 'deactivated') .. '.')
	elseif sub == 'nomagicskills' then -- called by UI button
		logger(chat_colors.yellow, 'There are no magic skills that the player\'s main job can skill up.')
	elseif sub == 'resetsession' then
		if active or #skills_to_skillup > 0 then
			logger(chat_colors.yellow, '[SESSION RESET] Session resetting, producing your skillup report...')
			print_skillup_report()
		end
		initialize_sms()
	-------------------------
	--[[ MODULE COMMANDS ]]--
	-------------------------
	elseif sub == 'mplimit' then
		local toggle = cmd[2] == 'toggle' and table.remove(cmd, 2) and true or false
		local silent = pop_silent()
		if toggle then
			mp_limit = mp_limit or 10
			mp_limit = (math.floor(mp_limit/5)*5) + 5
			if mp_limit > 50 then mp_limit = 10 end
		elseif not cmd[2] then
			return logger(chat_colors.grey, 'MP Limit is ' .. tostring(mp_limit))
		else
			local value = tonumber(cmd[2])
			if value == nil then return logger(chat_colors.red, '[DENIED] Please provide a number for the MP limit.') end
			mp_limit = value
		end
		if not modules.mp_limit.active then
			modules.mp_limit.active = true
		end
		if not silent then logger(chat_colors.grey, 'Set MP Limit to ' .. mp_limit) end
	elseif util.contains({'addmodule', 'addm', 'delmodule', 'delm', 'togmodule', 'togm'}, sub) then
		local silent = pop_silent()
		local name = cmd[2] and cmd[2]:lower()
		if not name then
			return logger(chat_colors.red, '[DENIED] Please specify a module...')
		end

		-- SEARCH FOR RESULT
		local mod
		for _, data in pairs(modules) do
			if util.startswith(util.fuzzy(data.label), util.fuzzy(name)) or util.startswith(data.label:lower(), name) then
				if mod then
					mod = 'multiple results'
				else
					mod = data
				end
			end
		end

		-- PROCESS EXIT SCENARIOS
		if mod == nil then
			return logger(chat_colors.red, '[DENIED] Module "' .. name .. '" does not exist...')
		elseif mod == 'multiple results' then
			return logger(chat_colors.red, '[DENIED] Matched multiple modules, please narrow your search term and try again.')
		elseif not mod.available then
			return logger(chat_colors.red, '[DENIED] Your main job does not get access to module "' .. name .. '"...')
		end

		-- DETERMINE ADDING/TOGGLING & EXECUTE
		local toggling = sub == 'togmodule' or sub == 'togm'
		local adding = (toggling and not mod.active) or sub == 'addmodule' or sub == 'addm'

		-- PERFORM ADDITIONAL MODULE-SPECIFIC CHECKS
		if mod.label == 'MP Limit' then
			mp_limit = adding and (mp_limit or 10) or nil
		elseif adding and mod.label == 'Convert' and #me.best_cures == 0 then
			return logger(chat_colors.red, '[DENIED] No cure spells available for convert recovery.')
		elseif adding and mod.label == 'Refresh' and modules.sublim.available then
			modules.sublim.active = false
		elseif adding and mod.label == 'Sublim.' and modules.refresh.available then
			modules.refresh.active = false
		elseif adding and (mod.label == 'Moogle' or mod.label == 'T.Target') then
			if not me.can_summon_trusts then
				logger(chat_colors.yellow, '[NOTICE] Your character can\'t summon trusts due to party composition.')
			elseif me.in_town then
				logger(chat_colors.yellow, '[NOTICE] Your character can\'t summon trusts due to being in ' .. me.in_town .. '.')
			end
		elseif adding and mod.label == 'Food' and not me.has_skillup_food then
			return logger(chat_colors.red, '[DENIED] No magic skillup food in available bags.')
		elseif adding and mod.label == 'Geo-Ref.' and me.in_town then
			logger(chat_colors.yellow, '[NOTICE] Cannot currently cast Geo-Refresh due to being in ' .. me.in_town .. '.')
		end

		-- ACTIVATE MODULE
		mod.active = adding
		if not silent then logger(chat_colors[adding and 'green' or 'red'], '[MODULE] ' .. (adding and 'Activated' or 'Deactivated') .. ' the "' .. mod.label .. '" module...') end

		if (mod.label == 'Refresh' or mod.label == 'Haste') and modules.compo.available then
			evaluate_composure_active()
		end
	---------------------
	--[[ UI COMMANDS ]]--
	---------------------
	elseif sub == 'uizoom' then
		local mode = cmd[2]
		if mode ~= 'in' and mode ~= 'out' then
			logger(chat_colors.red, '[UI ZOOM] Please specify "in" or "out".')
		elseif (settings.user_ui_scalar < 1.5 and mode == 'in') or (settings.user_ui_scalar > 0.5 and mode == 'out') then
			settings.user_ui_scalar = settings.user_ui_scalar + (mode == 'in' and 0.1 or -0.1)
			save_settings()
		end
	elseif util.contains({'uiscale', 'uis', 'scale'}, sub) then
		if cmd[2] == nil then
			logger(chat_colors.grey, '[UI SCALE] Your UI\'s current scale is ' .. settings.user_ui_scalar)
		else
			local new_scalar = tonumber(cmd[2])
			if new_scalar == nil or new_scalar > 1.5 or new_scalar < 0.5 then
				return logger(chat_colors.red, '[DENIED] Please provide a ui scale between 0.5 and 1.5.')
			end
			settings.user_ui_scalar = new_scalar
			save_settings()
		end
	elseif sub == 'uipos' then
		if cmd[2] == nil then
			return logger(chat_colors.grey, '[UI POSITION] Your UI\'s current x/y coordinates are ' .. settings.top_left.x .. '/' .. settings.top_left.y)
		end
		local x, y = tonumber(cmd[2]), tonumber(cmd[3])
		if x == nil or y == nil then
			return logger(chat_colors.grey, '[SET UI POSITION] Please provide two numbers, separated by a space, as the x/y coordinates.')
		end
		settings.top_left.x, settings.top_left.y = x, y
		ui.force_pos = true
		save_settings()
	elseif sub == 'uirebuild' then
		ui.force_pos = true
		logger(chat_colors.grey, '[UI REBUILD] Rebuilt user UI.')
	elseif sub == 'uidefaults' then
		settings.user_ui_scalar = defaults.user_ui_scalar
		settings.top_left.x, settings.top_left.y = defaults.top_left.x, defaults.top_left.y
		settings.ui_hidden = defaults.ui_hidden
		ui.force_pos = true
		save_settings()
		logger(chat_colors.grey, '[UI DEFAULTS] Restored UI defaults. (TIP: Use this or uipos if you drag your UI offscreen.)')
	elseif sub == 'uihide' or sub == 'uishow' then
		local hiding = sub == 'uihide'
		if hiding == settings.ui_hidden then
			return logger(chat_colors.grey, '[UI ' .. (hiding and 'HIDE' or 'SHOW') .. '] Denied, UI is already ' .. (hiding and 'hidden' or 'visible') .. '.')
		end
		settings.ui_hidden = hiding
		save_settings()
		return logger(chat_colors.grey, '[UI ' .. (hiding and 'HIDE' or 'SHOW') .. '] UI has been ' .. (hiding and 'hidden' or 'revealed') .. '.')
	------------------------
	--[[ DEBUG COMMANDS ]]--
	------------------------
	elseif sub == 'reload' or sub == 'r' then
		util.input('/addon reload smartskillup')
	elseif sub == 'unload' or sub == 'u' then
		util.input('/addon unload smartskillup')
	elseif sub == 'debug' then -- "/sms debug" or "/sms debug deep"
		local desiredMode = cmd[2] and cmd[2]:lower() or 'norm'
		if desiredMode == 'off' then -- "/sms debug off" disables every mode
			for k in pairs(debugModes) do debugModes[k] = false end
		elseif debugModes[desiredMode] == nil then
			return logger(chat_colors.red, '[ERROR] No "' .. desiredMode .. '" debug mode exists.')
		else
			debugModes[desiredMode] = not debugModes[desiredMode]
		end
		local on = {}
		for k, v in pairs(debugModes) do if v then on[#on+1] = k end end
		logger(chat_colors.purple, '[DEBUG MODES] Active modes: ' .. (#on > 0 and table.concat(on, ', ') or '[NONE]'))
	elseif sub == 'allcolors' then
		for i = 0, 255, 1 do
			logger(i, 'color code ' .. i)
		end
	elseif sub == 'forcestopcast' then
		force_stop_cast = true
	elseif sub == 'printplayer' then
		logger(chat_colors.grey, 'Printing player...')
		print_table(me)
	elseif sub == 'printtarget' then
		local getter = targets['get_' .. (cmd[2] and cmd[2]:lower() or 't')]
		local ok, entity = pcall(getter or function() end)
		if ok and entity then
			logger(chat_colors.grey, 'Printing target...')
			print_table({Name = entity.Name, ServerId = entity.ServerId, TargetIndex = entity.TargetIndex, HPPercent = entity.HPPercent,
				Distance = distance(entity), SpawnFlags = entity.SpawnFlags, Status = entity.Status, ClaimStatus = entity.ClaimStatus})
		else
			logger(chat_colors.grey, 'Invalid target...')
		end
	elseif sub == 'print' then -- ex: /sms print main_skills['Enfeebling Magic'].capped
		if cmd[2] == nil then
			return logger(chat_colors.grey, '[PRINT ERROR] A subject is required. (/sms print subject)')
		end
		local expr = table.concat(cmd, ' ', 2)
		local fn = loadstring('return ' .. expr)
		local ok, subject = pcall(fn or function() end)
		if not ok or subject == nil then
			logger(chat_colors.grey, '[PRINT ERROR] ' .. expr .. ' does not exist...')
		else
			logger(chat_colors.grey, '[PRINT] Printing ' .. expr .. '...')
			if type(subject) == 'table' then print_table(subject) else logger(chat_colors.grey, tostring(subject)) end
		end
	elseif sub == 'eval' or sub == 'exec' then -- ex: /sms eval get_valid_spells()
		local expr = table.concat(cmd, ' ', 2)
		logger(chat_colors.grey, '[EVALUATE] Evaluating "' .. expr .. '"...')
		local fn, err = loadstring(expr)
		if not fn then return logger(chat_colors.red, 'Eval error, check syntax: ' .. tostring(err)) end
		local ok, run_err = pcall(fn)
		if not ok then return logger(chat_colors.red, 'Eval error: ' .. tostring(run_err)) end
		logger(chat_colors.grey, '[EVALUATE FINISHED] Processing complete.')
	-----------------------
	--[[ HELP COMMANDS ]]--
	-----------------------
	elseif sub == 'spellreport' then
		print_spell_availability(cmd[2] and cmd[2]:lower() == 'weighted')
	elseif sub == 'modulehelp' then
		logger(chat_colors.grey, 'SmartSkillup  v' .. addon.version .. ' modules:')
		for _, help in ipairs(statics.module_help) do
			local label = (help.job_only and '*' or '') .. help.name .. ':'
			logger(chat_colors.grey, label .. string.rep(' ', math.max(1, 14 - #label)) .. help.text)
		end
		logger(chat_colors.grey, 'NOTE: Modules marked with * are only available when the player is on a relevant main job.')
	elseif sub == 'automodules' then
		logger(chat_colors.grey, 'SmartSkillup  v' .. addon.version .. ' auto modules:')
		logger(chat_colors.grey, 'Composure: Used prior to refresh and haste - and removed after - if player is RDM50+.')
		logger(chat_colors.grey, 'Radial Arcana: Used when MP is below 60% if player is GEO75+ and has the related merit.')
	elseif sub == 'help' then
		logger(chat_colors.grey, 'SmartSkillup  v' .. addon.version .. ' commands:')
		logger(chat_colors.grey, '/sms [command]')
		for _, group in ipairs(statics.command_help) do
			logger(chat_colors.grey, '-- ' .. group.section .. ' --')
			for _, entry in ipairs(group.commands) do
				logger(chat_colors.grey, entry[1] .. string.rep(' ', math.max(1, 13 - #entry[1])) .. '- ' .. entry[2])
			end
		end
		for _, tip in ipairs(statics.help_tips) do
			logger(chat_colors.grey, 'DID YOU KNOW: ' .. tip)
		end
	else
		handle_command({'help'})
	end
end
