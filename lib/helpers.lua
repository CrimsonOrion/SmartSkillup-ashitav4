--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port of helpers.lua]]

-- Helper functions not running the skillup loop, events, or me

local mm = AshitaCore:GetMemoryManager()



-------------------------------------------------------------------------------------------------------------------
-- Recast helpers (Windower's get_spell_recasts/get_ability_recasts replacements)
-------------------------------------------------------------------------------------------------------------------
function spell_recast(spell_id) -- in 1/60ths of a second, like Windower
	return mm:GetRecast():GetSpellTimer(spell_id)
end

function ability_recast(recast_id) -- in seconds, like Windower
	local recast = mm:GetRecast()
	for i = 0, 31 do
		if recast:GetAbilityTimerId(i) == recast_id and (recast_id ~= 0 or i == 0) then
			return recast:GetAbilityTimer(i) / 60
		end
	end
	return 0
end



-------------------------------------------------------------------------------------------------------------------
-- The end-of-session report generation, provides count of casts and skill levels gained
-------------------------------------------------------------------------------------------------------------------
function print_skillup_report()
	local reported = false
	for skill_en, data in pairs(main_skills) do
		local gained_levels = (data.level or 0) - (data.level_init or 0)
		if data.casts > 0 or gained_levels > 0 then
			reported = true
			logger(chat_colors.grey, '   [' .. skill_en .. '] ' .. data.casts .. ' casts' .. (gained_levels > 0 and (' (+' .. gained_levels .. ' levels)') or ''))
		end
		logger(chat_colors.purple, '   [' .. skill_en .. '] Initial: ' .. tostring(data.level_init) .. ', Current: ' .. tostring(data.level), true)
		data.casts = 0 -- reset this var now to prepare for the next session
	end
	if not reported then logger(chat_colors.grey, '   Nothing to report...') end
end



-------------------------------------------------------------------------------------------------------------------
-- The spell availability report, helps users understand which spells SmartSkillup is using, and why
-------------------------------------------------------------------------------------------------------------------
function print_spell_availability(show_weight)
	logger(chat_colors.grey, '[SPELL REPORT] Printing your spell ' .. (show_weight and 'weight' or 'availability') .. ' report...')
	logger(chat_colors.grey, 'NOTE: Only spells your ' .. me.main_job .. me.main_job_level .. '/' .. me.sub_job .. me.sub_job_level .. ' knows & can cast/skillup on.')
	if show_weight then
		logger(chat_colors.grey, 'NOTE: Spells are weighted equally by MP cost and cast time.')
		logger(chat_colors.grey, 'LEGEND: Spells are prefixed by spell weight; lower is better.')
	else
		logger(chat_colors.grey, 'LEGEND: (+) SmartSkillup will use these spells')
		logger(chat_colors.grey, 'LEGEND: (-) SmartSkillup ignores these spells')
	end
	for _, skill_en in ipairs(util.keys(valid_spells_sorted, true)) do
		local spells = valid_spells_sorted[skill_en]
		logger(chat_colors.grey, '  * ' .. skill_en:upper())
		if not main_skills[skill_en].parent then
			-- PRINT VALID SPELLS
			for _, spell in ipairs(spells) do
				local prefix = show_weight and string.format("%.0f", spell.weight*100) or '(+)'
				logger(chat_colors.grey, '      ' .. prefix .. ' ' .. spell.en)
			end

			-- PRINT IGNORED SPELLS (don't do this for the weighted variant, though)
			if not show_weight then
				for _, spell in ipairs(ignored_spells[skill_en] or {}) do
					logger(chat_colors.grey, '      (-) ' .. spell.en .. ' (' .. spell.reason .. ')')
				end
			end

			-- PRINT NO-SPELLS PLACEHOLDER (main job can skill it but player has no spells yet)
			if #spells == 0 and #(ignored_spells[skill_en] or {}) == 0 then
				logger(chat_colors.grey, '      (-) No available spells')
			end
		else
			logger(chat_colors.grey, '      (o) See "' .. main_skills[skill_en].parent:upper() .. '"')
		end
	end
	logger(chat_colors.grey, 'End of spell report...')
end



-------------------------------------------------------------------------------------------------------------------
-- A toggle that adds support for allowing a player to skill multiple skills in one session
-------------------------------------------------------------------------------------------------------------------
function toggle_to_next_skill(cap_event)
	if #skills_to_skillup == 0 then
		skill_to_skillup = nil
		if not active then return end
		util.schedule(1, function() --delay for correct log order
			logger(chat_colors.yellow, '[END OF SESSION] No skills remain in the current session. Ending session...')
			if cap_event and auto_shutdown then
				if me.status == 'Engaged' then
					me.shutdown_awaiting_disengage = true
				else
					util.input('/shutdown')
					logger(chat_colors.yellow, '[AUTO-SHUTDOWN] Performing the requested /shutdown.')
				end
			else
				handle_command({'stop'})
			end
		end)
		return
	end

	local current_index = util.index_of(skills_to_skillup, skill_to_skillup) or 0
	local desired_index = current_index < #skills_to_skillup and current_index + 1 or 1 -- increment unless on max index, goto 1 if so
	skill_to_skillup = skills_to_skillup[desired_index]
end



-------------------------------------------------------------------------------------------------------------------
-- A function that removes a skill from the skill session and handles termination, if applicable
-------------------------------------------------------------------------------------------------------------------
function remove_skill_from_session(skill_en, cap_event)
	logger(chat_colors.purple, 'Removing ' .. skill_en .. ' from the session...', true)
	if not util.contains(skills_to_skillup, skill_en) then --this skill isn't in the session
		if not cap_event then
			return logger(chat_colors.red, '[REMOVE] Attempted to remove not-in-session ' .. skill_en .. ', why?', true)
		end
	else
		util.remove_value(skills_to_skillup, skill_en)
		toggle_to_next_skill(cap_event)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Processes spells to determine if the player's main job can skill them up
-------------------------------------------------------------------------------------------------------------------
function is_valid(spell, skill_en, for_module) --half of this function came from SMD111
	if not known_spells[spell.id] then --player doesn't know
		return false
	elseif (not spell.levels[me.main_job_id] or spell.levels[me.main_job_id] > me.main_job_level) --mj can't cast
	and (not spell.levels[me.sub_job_id] or spell.levels[me.sub_job_id] > me.sub_job_level) then --sj can't cast
		return false
	elseif skill_en == 'Blue Magic' and not util.contains(me.blu_spells or {}, spell.en) then
		if not for_module then -- process, but don't insert, while generating modules
			table.insert(ignored_spells[skill_en], {en = spell.en, reason = 'Unset'})
		end
		return false
	elseif not for_module and util.contains(statics.resistable_spells[skill_en] or {}, spell.en) then --resistable and bad for skillup
		table.insert(ignored_spells[skill_en], {en = spell.en, reason = 'Resistable/unstackable, poor for skillup'})
		return false
	elseif not for_module and (util.wmatch(spell.en, 'Teleport-*|Raise*|Warp*|Tractor*|Retrace|Escape|Geo-*|Sacrifice|Odin|Alexander|Recall-*|Full Cure')
	or (skill_en == 'Healing Magic' and util.endswith(spell.en, 'na'))) then --not for skillup
		table.insert(ignored_spells[skill_en], {en = spell.en, reason = 'Not for skillup'})
		return false
	end
	return true
end



-------------------------------------------------------------------------------------------------------------------
-- Reads the player's known spells from memory (Windower's get_spells replacement)
-------------------------------------------------------------------------------------------------------------------
function update_known_spells()
	local player = mm:GetPlayer()
	known_spells = {}
	for id in pairs(res.spells()) do
		if player:HasSpell(id) then known_spells[id] = true end
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Get the mj-relevant spells known by the player and weight them
-------------------------------------------------------------------------------------------------------------------
function get_valid_spells()
	-- RE-INITIALIZE VALID SPELL TABLE
	valid_spells = {}
	for skill_en in pairs(main_skills) do
		valid_spells[skill_en] = {}
		ignored_spells[skill_en] = {}
	end

	-- PROCESS EACH SPELL
	update_known_spells() --known spells, all jobs
	for _, spell in pairs(res.spells()) do
		local skill_en = res.skills[spell.skill]
		if skill_en and main_skills[skill_en] and not main_skills[skill_en].parent and is_valid(spell, skill_en) then
			valid_spells[skill_en][spell.id] = spell
			for _, data in ipairs(statics.indirect_skills[skill_en] or {}) do --these rely on its spells
				valid_spells[data.en][spell.id] = spell
			end
		end
	end

	-- PREPARE MAX MEASUREMENTS FOR WEIGHTING
	local meta = {max_mp_cost = {}, max_cast_time = {}} -- metadata on maxes per skill
	for skill_en, spells in pairs(valid_spells) do
		meta.max_mp_cost[skill_en], meta.max_cast_time[skill_en] = 0, 0
		for _, spell in pairs(spells) do
			meta.max_mp_cost[skill_en]   = math.max(meta.max_mp_cost[skill_en]  , spell.mp_cost  )
			meta.max_cast_time[skill_en] = math.max(meta.max_cast_time[skill_en], spell.cast_time)
		end
	end

	-- BUILD SPELLS SORTED BY WEIGHT
	valid_spells_sorted = {}
	for skill_en, spells in pairs(valid_spells) do
		valid_spells_sorted[skill_en] = {}
		for _, spell in pairs(spells) do
			-- CALCULATE/ASSIGN WEIGHT AND PUSH EACH SPELL TO NEW TABLE
			local mp_cost_weight   = meta.max_mp_cost[skill_en]   > 0 and spell.mp_cost   / meta.max_mp_cost[skill_en]   * 0.5 or 0 --50% weight
			local cast_time_weight = meta.max_cast_time[skill_en] > 0 and spell.cast_time / meta.max_cast_time[skill_en] * 0.5 or 0 --50% weight
			spell.weight = mp_cost_weight + cast_time_weight
			table.insert(valid_spells_sorted[skill_en], spell)
		end
		-- SORT NEW TABLE BY WEIGHT (LOWEST IS BEST)
		table.sort(valid_spells_sorted[skill_en], function(a,b) return a.weight < b.weight end)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Get the magic skills that are native to the main job (it can only skill-up these skills)
-------------------------------------------------------------------------------------------------------------------
function get_main_skills()
	main_skills = {}
	-- PROCESS ALL SPELLS (only these can be skilled up by said main job!)
	for _, spell in pairs(res.spells()) do
		local skill_en = res.skills[spell.skill]
		if skill_en and not res.is_trust_spell(spell) then
			-- INITIALIZE MAIN JOB SKILLS
			if main_skills[skill_en] == nil and spell.levels[me.main_job_id] and not util.contains(statics.ignore_main_spells, spell.en) then --main job can cast it
				main_skills[skill_en] = {id = spell.skill, en = skill_en, casts = 0}
				-- INITIALIZE INDIRECT SKILLS ALSO (Ex: Wind and String are both tied to Singing)
				for _, indirect_skill in ipairs(statics.indirect_skills[skill_en] or {}) do
					main_skills[indirect_skill.en] = util.copy(indirect_skill)
				end
			end
		end
	end
	me.no_magic_skills = next(main_skills) == nil
end



-------------------------------------------------------------------------------------------------------------------
-- Unpack skill level/capped data into main_skills. Source is either memory (on initialize) or the 0x062 packet.
-------------------------------------------------------------------------------------------------------------------
function read_skills_from_memory()
	local player = mm:GetPlayer()
	return function(skill_id)
		local skill = player:GetCombatSkill(skill_id)
		return skill:GetSkill(), skill:IsCapped()
	end
end

function process_skill_data(get_skill)
	logger(chat_colors.purple, '[SKILL DATA] Processing skill level/cap data...', true)
	for skill, data in pairs(main_skills) do
		local level, capped = get_skill(data.id)
		-- CAPTURE INITIAL LEVEL
		if data.level == nil then
			data.level_init, data.capped = level, capped
		-- SKILL CAP/UNCAP (uncap on levelup)
		elseif capped ~= data.capped and not me.awaiting_initialize then
			if capped then
				logger(chat_colors.green, '[SKILL CAP] Congratulations, "' .. skill .. '" skill has capped!')
				remove_skill_from_session(data.en, true)
			end
		end
		data.level, data.capped = level, capped
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Increment relevant cast count for main_skills on each aftercast event
-------------------------------------------------------------------------------------------------------------------
function increment_casts(event)
	if event.res == nil or event.res.skill == nil then return end
	local skill_en = res.skills[event.res.skill]
	if not skill_en or not main_skills[skill_en] then return end
	main_skills[skill_en].casts = main_skills[skill_en].casts + 1
end



-------------------------------------------------------------------------------------------------------------------
-- A function to handle processing requests to begin the loop and the situational actions required to do so correctly
-------------------------------------------------------------------------------------------------------------------
function begin_loop(source, notify)
	source = source or 'NEW LOOP'
	logger(chat_colors.purple, '[BEGIN LOOP'..statics.larr..source:upper()..'] Beginning loop...', false,true)
	local verbiage = active and {'RESUME', 'resuming'} or {'START', 'starting'}

	-- RETURN: NO SKILLS TO SKILLUP
	if #skills_to_skillup == 0 then
		return logger(chat_colors.red, '[DENIED] No skills have been added to attempt to begin. (TIP: /sms addskill [searchterm])')
	elseif going then
		return logger(chat_colors.purple, '[DENIED] Loop is already going.', true)
	end

	-- ACTIVATE
	active = true

	-- RETURN: NEED TO START GETTING UP
	if event_pauses.Resting and not me.getting_up then
		me.getting_up = true
		util.input('/heal')
		end_timeout_and_decision(source, chat_colors.purple, '[NEW LOOP] Ending any scheduled timeout and decision...', true)
		schedule_decision(3, source .. '+GET UP')
		return logger(chat_colors.green, '[' .. verbiage[1] .. '] Getting up and ' .. verbiage[2] ..' in 3 seconds...')

	-- RETURN: GET UP FASTER (just wait, lol)
	elseif event_pauses.Resting then
		return logger(chat_colors.green, '[START] Resuming skillup session...')

	-- RETURN: AWAITING EVENT PAUSES
	elseif next(event_pauses) ~= nil then
		me.awaiting_event_pause_end = true -- required when player unpauses during an event pause
		return logger(chat_colors.green, '[START] Waiting on the following pause events to end: ' .. table.concat(util.keys(event_pauses, true), ', '))
	end

	-- RESET VARIOUS VARS
	paused = false
	loop.issues = 0
	auto_resting = false

	-- NOTIFY CLIENT IF NOTIFY TRUE
	logger(chat_colors.green, '[' .. verbiage[1] .. '] Skillup session ' .. verbiage[2] .. '...', not notify and true or nil)

	-- ENSURE SINGLE TIMEOUT, THEN START DECISION
	end_timeout_and_decision(source, chat_colors.purple, '[NEW LOOP] Ending any scheduled timeout and decision...', true)
	going = true
	make_decision(source)
end



-------------------------------------------------------------------------------------------------------------------
-- A rhythmic player notice of upcoming healing session that can be prematurely terminated (10, 6, 3, 2, 1, 0 rhythm)
-------------------------------------------------------------------------------------------------------------------
function initialize_healing_notice(total_delay, reason, first)
	me.healing_countdown_running = true
	total_delay = total_delay or 9 -- total time till alert expires
	local next_tick = total_delay <= 3 and 1 or math.fmod(total_delay, 3) == 0 and 3 or math.fmod(total_delay, 3) + 3
	if total_delay > 0 then
		logger(chat_colors.yellow, '[RESTING SCHEDULED] Beginning a resting session in ' .. total_delay .. ' seconds...' .. (first and ' (Reason: ' .. reason .. ')' or ''))
		threads.healing_notice = util.schedule(next_tick, initialize_healing_notice, total_delay - next_tick, reason)
	else
		auto_resting = true
		me.healing_countdown_running = nil
		util.input('/heal')
	end
end

function terminate_healing_notice(reason)
	util.cancel(threads.healing_notice)
	if me.healing_countdown_running then
		me.healing_countdown_running = nil
		logger(chat_colors.yellow, '[RESTING CANCELLED] Cancelled the scheduled healing session.' .. (reason and ' (Reason: ' .. reason .. ')' or ''))
	end
end



-------------------------------------------------------------------------------------------------------------------
-- The new and improved event pause system, allowing all event pauses to co-exist!
-- KEYS: healing, moving, npc, zoning, various-statuses
-- (Windower version used a write-proxy metatable; here all writes go through set_event_pause)
-------------------------------------------------------------------------------------------------------------------
event_pauses = {}

local function set_event_pause(k, v)
	-- GET START COUNT
	local start_count = util.count(event_pauses)

	-- RECORD EVENT
	event_pauses[k] = v or nil

	-- GET END COUNT
	local end_count = util.count(event_pauses)

	-- EVENT PAUSE STARTED
	if start_count == 0 and end_count > 0 then
		local reason = 'PAUSE EVENT' .. statics.larr .. k:upper()
		-- LOOP INACTIVE OR PLAYER PAUSED
		if not active or paused then
			logger(chat_colors.lpurple, '['.. reason .. '] Ignored, inactive or player-paused.', true)
		-- END ACTIVE LOOP
		else
			going = false
			end_timeout_and_decision(reason, chat_colors.purple, '[' .. reason .. '] "' .. k .. '" started an event pause and ended the timeout and decisions.', true)
		end

	-- EVENT PAUSE ENDED
	elseif end_count == 0 and start_count > 0 then
		local reason = 'UNPAUSE EVENT' .. statics.larr .. k:upper()
		-- LOOP ALREADY GOING
		if going and not me.awaiting_event_pause_end then
			logger(chat_colors.lpurple, '[' .. reason .. '] Ignored, loop already going.', true)
		-- LOOP INACTIVE OR PLAYER PAUSED
		elseif not active or paused then
			logger(chat_colors.lpurple, '[' .. reason .. '] Ignored, inactive or player-paused.', true)
		-- AWAITING HEALING
		elseif me.healing_countdown_running then
			logger(chat_colors.lpurple, '[' .. reason .. '] Ignored, awaiting healing from notice.', true)
		-- LOOP REVIVAL
		else
			going = true
			me.awaiting_event_pause_end = nil -- reset
			end_timeout_and_decision(reason)
			schedule_decision(1, reason, chat_colors.purple, '[' .. reason .. '] The last event, "' .. k .. '", scheduled a decision in 1 sec...', true)
		end

	-- A NESTED EVENT STARTED OR ENDED
	elseif start_count ~= end_count then
		local mode = v and 'pause' or 'unpause'
		local events = table.concat(util.keys(event_pauses, true), ', ')
		logger(chat_colors.lpurple, '[' .. mode:upper() .. ' EVENT' .. statics.larr .. k:upper() .. '] Ignored a nested "' .. k .. '" ' .. mode .. '. (pauses: ' .. events .. ')', false, true)
	end
end

function pause_event(event)
	util.cancel(threads['sched_' .. event .. '_unpause']) -- end event's delayed unpause, it'd be premature now
	set_event_pause(event, true)
end

function unpause_event(event, delay)
	util.cancel(threads['sched_' .. event .. '_unpause'])
	threads['sched_' .. event .. '_unpause'] = util.schedule(delay or 0, set_event_pause, event, nil)
end



-------------------------------------------------------------------------------------------------------------------
-- Specialized processing for statuses (event pauses and auto_resting)
-------------------------------------------------------------------------------------------------------------------
function process_status_events(newStatus, oldStatus, newStatusId, oldStatusId)
	-- STATUS PAUSE EVENTS -- Dead, Chocobo, Cutscene, Resting, etc
	if newStatusId > 1 then
		if newStatus == 'Resting' then terminate_healing_notice('Status change') end
		pause_event(newStatus)
	end
	if oldStatusId and oldStatusId > 1 then
		unpause_event(oldStatus, 1)
	end
end

function processing_resting_change(newStatus, oldStatus)
	if not active or paused then return end
	if newStatus ~= 'Resting' and oldStatus ~= 'Resting' then return end

	-- STARTED RESTING
	if newStatus == 'Resting' then
		me.healing_countdown_running = nil
		if auto_resting or (not auto_resting and me.mpp < 70) then -- ignore rests where the player is apparently arbitrarily healing
			logger(chat_colors.yellow, '[RESTING] Skillup will resume automatically when MP is full.')
			auto_resting = true -- will get up when full
		end

	-- GOT UP FROM RESTING
	else
		auto_resting = false
		me.getting_up = true -- used to track get-up animation lock
		util.schedule(1.5, function() me.getting_up = nil end)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Specialized processing for buffs
-------------------------------------------------------------------------------------------------------------------
local function any_buff_named(list, name)
	for id, n in pairs(list) do
		if n == name and buffactive[id] then return true end
	end
	return false
end

function process_buff_change(id, gain)
	buffactive[id] = gain or nil

	-- GEO REFRESH TRACKING
	if id == statics.buffs.geo_refresh and modules then
		modules.georef.buffactive = gain
	end

	-- JA LOCKED
	if statics.JA_lock_buffs[id] then
		me.JA_locked = false
		for lock_id in pairs(statics.JA_lock_buffs) do
			if buffactive[lock_id] then me.JA_locked = true end
		end
	end

	-- TRACK CASTING-LOCKABLE BUFFS AS EVENT PAUSES
	local proper = statics.all_lock_buffs[id] or statics.cast_lock_buffs[id]
	if proper then
		local still_active = any_buff_named(statics.all_lock_buffs, proper) or any_buff_named(statics.cast_lock_buffs, proper)
		if still_active then
			pause_event(proper)
		else
			unpause_event(proper, 0.5)
		end
		if active and not paused then -- we don't usually say anything about event pauses, but this is an exception
			logger(chat_colors.yellow, '[NOTICE] An event pause has ' .. (still_active and 'started' or 'ended') .. ' for "' .. proper .. '".')
		end
	elseif id == statics.buffs.composure and modules then
		modules.compo.buffactive = gain
	elseif (id == statics.buffs.refresh or id == statics.buffs.haste) and modules and modules.compo.available then
		evaluate_composure_active()
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Get the modules relevant to the player and/or its main job
-------------------------------------------------------------------------------------------------------------------
function determine_modules()
	-- GET AVAILABLE MODULES
	update_known_spells()
	local player = mm:GetPlayer()
	modules = util.copy(modules_default)

	-- MOOGLE MODULE
	if modules.moogle.res and known_spells[modules.moogle.res.id] then
		modules.moogle.available = true -- res already populated
	end
	-- DYNAMIC SPELL MODULES (Refresh/Haste), weighted by priority
	local refresh_rank, haste_rank = 0, 0
	for _, spell in pairs(res.spells()) do
		local skill_en = res.skills[spell.skill]
		local r_rank, h_rank = statics.self_refresh_spells[spell.en], statics.self_haste_spells[spell.en]
		if (r_rank or h_rank) and is_valid(spell, skill_en, true) then
			if r_rank and r_rank > refresh_rank then
				refresh_rank = r_rank
				modules.refresh.available, modules.refresh.res = true, util.copy(spell)
				modules.refresh.res.status = statics.buffs.refresh
			elseif h_rank and h_rank > haste_rank then
				haste_rank = h_rank
				modules.haste.available, modules.haste.res = true, util.copy(spell)
				modules.haste.res.status = statics.buffs.haste
			end
		end
	end
	-- CONVERT MODULE
	if modules.convert.res and ((me.main_job == 'RDM' and me.main_job_level >= 40) or (me.sub_job == 'RDM' and me.sub_job_level >= 40)) then
		modules.convert.available = true -- res already populated
		schedule_module_readiness(modules.convert, true)
	end
	-- COMPOSURE MODULE
	if modules.compo.res and me.main_job == 'RDM' and me.main_job_level >= 50 then --not available to lv50 sj
		modules.compo.available = true -- res already populated
		schedule_module_readiness(modules.compo, true)
	end
	-- GEO REFRESH MODULE
	if modules.georef.res and ((me.main_job == 'GEO' and me.main_job_level > 34) or (me.sub_job == 'GEO' and me.sub_job_level > 34)) and known_spells[modules.georef.res.id] then
		modules.georef.available = true -- res already populated
		modules.georef.buffactive = buffactive[statics.buffs.geo_refresh]
	end
	-- RADIAL ARCANA MODULE (merit ability; known only once merited)
	if modules.radial.res and me.main_job == 'GEO' and me.main_job_level >= 75 and player:HasAbility(modules.radial.res.id) then
		modules.radial.available = true -- res already populated
		schedule_module_readiness(modules.radial, true)
	end
	-- SUBLIMATION MODULE
	if modules.sublim.res and ((me.main_job == 'SCH' and me.main_job_level >= 35) or (me.sub_job == 'SCH' and me.sub_job_level >= 35)) then
		modules.sublim.available = true -- res already populated
		schedule_module_readiness(modules.sublim, true)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Specialized processing for the composure module's active state
-------------------------------------------------------------------------------------------------------------------
function evaluate_composure_active()
	modules.compo.active = (modules.refresh.active and not buffactive[modules.refresh.res.status])
		or (modules.haste.active and not buffactive[modules.haste.res.status]) or false
end



-------------------------------------------------------------------------------------------------------------------
-- Checks readiness on addon load and schedules anticipated readiness as JA-related modules are used
-------------------------------------------------------------------------------------------------------------------
function schedule_module_readiness(mod, immediate)
	if not immediate then return util.schedule(2, schedule_module_readiness, mod, true) end

	local recast = ability_recast(mod.res.recast_id)
	if recast == 0 then
		mod.ready = true
	else
		mod.ready = false
		util.schedule(recast + 0.1, schedule_module_readiness, mod, true)
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Builds the user's two best cures known and castable by their main job, for recovering from convert
-------------------------------------------------------------------------------------------------------------------
function update_best_cures()
	update_known_spells()
	me.best_cures = {}
	for i = 6, 1, -1 do
		local cure = res.spell_by_name('Cure' .. statics.numerals[i])
		if cure and is_valid(cure, res.skills[cure.skill], true) then
			-- BEST CURE
			if me.best_cures[1] == nil then
				me.best_cures[1] = {en = cure.en, mp_cost = cure.mp_cost, prefix = cure.prefix}
				me.best_cure_index = 1

			-- SECOND BEST CURE
			else
				me.best_cures[2] = {en = cure.en, mp_cost = cure.mp_cost, prefix = cure.prefix}
				break
			end
		end
	end
end
