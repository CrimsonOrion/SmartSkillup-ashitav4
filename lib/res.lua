--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: A thin stand-in for Windower's 'resources' library, built on Ashita's IResourceManager.]]

local bit = require('bit')

local res = {}
local rm = AshitaCore:GetResourceManager()



-------------------------------------------------------------------------------------------------------------------
-- Static tables that Windower's resources provided but Ashita has no string table for
-------------------------------------------------------------------------------------------------------------------
res.skills = { -- magic skills only; the addon never deals with combat skills
	[32] = 'Divine Magic',    [33] = 'Healing Magic',  [34] = 'Enhancing Magic',     [35] = 'Enfeebling Magic',
	[36] = 'Elemental Magic', [37] = 'Dark Magic',     [38] = 'Summoning Magic',     [39] = 'Ninjutsu',
	[40] = 'Singing',         [41] = 'Stringed Instrument', [42] = 'Wind Instrument', [43] = 'Blue Magic',
	[44] = 'Geomancy',        [45] = 'Handbell',
}

res.statuses = { -- player entity statuses (Windower res.statuses)
	[0] = 'Idle', [1] = 'Engaged', [2] = 'Dead', [3] = 'Engaged dead', [4] = 'Event', [5] = 'Chocobo',
	[33] = 'Resting', [38] = 'Fishing', [44] = 'Crafting', [47] = 'Sitting', [48] = 'Kneeling', [85] = 'Mount',
}

function res.status_name(id)
	return res.statuses[id] or ('Status ' .. tostring(id))
end

res.spell_types = { -- ISpell.Type
	white = 1, black = 2, summoning = 3, ninjutsu = 4, song = 5, blue = 6, geomancy = 7, trust = 8,
}

res.target_flags = { -- ISpell.Targets bitfield
	self = 0x01, player = 0x02, party = 0x04, ally = 0x08, npc = 0x10, enemy = 0x20,
}



-------------------------------------------------------------------------------------------------------------------
-- Spells: normalized once into Windower-like records ({id, en, skill, mp_cost, cast_time, levels, targets, ...})
-------------------------------------------------------------------------------------------------------------------
local spells_cache

local function normalize_spell(id, s)
	local name = s.Name[1]
	if name == nil or name == '' or name == '.' then return nil end
	local levels = {}
	for job = 1, 22 do
		local lvl = s.LevelRequired[job + 1]
		if lvl ~= nil and lvl > 0 and lvl ~= 0xFF and lvl ~= 0xFFFF then levels[job] = lvl end
	end
	return {
		id        = id,
		en        = name,
		skill     = s.Skill,
		type      = s.Type,
		mp_cost   = s.ManaCost,
		cast_time = s.CastTime / 4, -- dat value is in quarter-seconds
		levels    = levels,
		targets   = {
			Self  = bit.band(s.Targets, res.target_flags.self)  ~= 0,
			Party = bit.band(s.Targets, res.target_flags.party) ~= 0,
			Enemy = bit.band(s.Targets, res.target_flags.enemy) ~= 0,
		},
		prefix    = '/ma',
	}
end

function res.spells()
	if spells_cache then return spells_cache end
	spells_cache = {}
	for id = 1, 1023 do
		local s = rm:GetSpellById(id)
		if s ~= nil then
			spells_cache[id] = normalize_spell(id, s)
		end
	end
	return spells_cache
end

function res.is_trust_spell(spell)
	return spell.type == res.spell_types.trust or (spell.skill == 0 and spell.id >= 896)
end

function res.spell(id)
	return res.spells()[id]
end

function res.spell_by_name(name)
	for _, spell in pairs(res.spells()) do
		if spell.en == name then return spell end
	end
	return nil
end



-------------------------------------------------------------------------------------------------------------------
-- Job abilities (only the handful the modules use), items, buffs, jobs, zones
-------------------------------------------------------------------------------------------------------------------
function res.ability_by_name(name)
	local a = rm:GetAbilityByName(name, 0)
	if a == nil then return nil end
	return {id = a.Id, en = a.Name[1], recast_id = a.RecastTimerId, prefix = '/ja'}
end

function res.item(id)
	local i = rm:GetItemById(id)
	if i == nil then return nil end
	return {id = id, en = i.Name[1]}
end

function res.buff_name(id)
	return rm:GetString('buffs.names', id)
end

function res.job_abbr(id)
	return rm:GetString('jobs.names_abbr', id)
end

function res.zone_name(id)
	return rm:GetString('zones.names', id)
end

return res
