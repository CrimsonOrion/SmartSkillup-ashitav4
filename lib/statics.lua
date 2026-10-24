--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: Buff/bag/item lookups switched from Windower resource names to static ids.]]

local statics = {}

statics.resistable_spells = { --avoid these since skillups cannot occur on resists nor on attempts to stack these effects
	['Enfeebling Magic'] = {'Addle', 'Addle II', 'Bind', 'Blind', 'Blind II', 'Break', 'Breakga', 'Dispel',
		'Distract', 'Distract II', 'Distract III', 'Frazzle', 'Frazzle II', 'Frazzle III', 'Gravity', 'Gravity II',
		'Paralyze', 'Paralyze II', 'Poison', 'Poison II', 'Poisonga', 'Sleep', 'Sleep II', 'Sleepga', 'Sleepga II',
		'Silence', 'Slow', 'Slow II'},
	['Elemental Magic'] = {'Burn', 'Choke', 'Drown', 'Frost', 'Rasp', 'Shock'},
	['Singing'] = {'Foe Requiem', 'Foe Requiem II', 'Foe Requiem III', 'Foe Requiem IV', 'Foe Requiem V',
		'Foe Requiem VI', 'Foe Requiem VII', 'Fire Threnody', 'Ice Threnody', 'Wind Threnody', 'Earth Threnody',
		'Ltng. Threnody', 'Water Threnody', 'Light Threnody', 'Dark Threnody', 'Fire Threnody II', 'Ice Threnody II',
		'Wind Threnody II', 'Earth Threnody II', 'Ltng. Threnody II', 'Water Threnody II', 'Light Threnody II',
		'Dark Threnody II', 'Battlefield Elegy', 'Carnage Elegy', 'Foe Lullaby', 'Horde Lullaby'},
}
statics.resistable_spells['Wind Instrument'] = statics.resistable_spells.Singing -- assign this also to the indirect skill
statics.resistable_spells['Stringed Instrument'] = statics.resistable_spells.Singing -- assign this also to the indirect skill

statics.untargetable_trusts = {'Brygid','Star Sibyl','Kuyin Hathdenna','Kupofried','Moogle','Sakura'} -- used to avoid attempting to cast on these trusts

statics.ignore_main_spells = { -- skills artificially available to main jobs who cannot necessarily skill up their related skill
	'Dispelga', -- granted via the 'Daybreak' club
	'Impact',   -- granted via the 'Twilight Cloak' or 'Crepuscular Cloak'
}

statics.indirect_skills = { -- used to give spells to skills that inherit spells (Ex: Wind and String inherit from Singing spells)
	['Singing'] = {
		{id = 42, en = 'Wind Instrument', casts = 0, parent = 'Singing'},
		{id = 41, en = 'Stringed Instrument', casts = 0, parent = 'Singing'},
	},
	['Geomancy'] = {
		{id = 45, en = 'Handbell', casts = 0, parent = 'Geomancy'},
	},
}

statics.modules_order = { -- used to build the modules in a strict order
	'mp_limit',
	't_target',
	'food',
	'moogle',
	'convert',
	'refresh',
	'haste',
	'georef',
	'sublim',
}

statics.module_help = { -- shared by /sms modulehelp and the UI's MODULES popup (job_only: needs a relevant main job)
	{key = 'mp_limit', name = 'MP Limit',     text = 'Only spells below the current limit will be auto-cast.'},
	{key = 't_target', name = 'Trust Target', text = 'Ensures a targetable trust is summoned, as their ilvl mob status boosts skillup rate.'},
	{key = 'food',     name = 'SkillUp Food', text = 'Uses the best magic food available in your inventory, sack, satchel, or case.'},
	{key = 'moogle',   name = 'Moogle',       text = 'Summons the "Moogle" trust to utilize its refresh and skillup rate boost.', job_only = true},
	{key = 'convert',  name = 'Convert',      text = 'Uses convert when MP is below 25%. Requires a cure spell for use in recovering.', job_only = true},
	{key = 'refresh',  name = 'Refresh',      text = 'Casts the most potent refresh available to your main/sub jobs.', job_only = true},
	{key = 'haste',    name = 'Haste',        text = 'Casts the most potent haste available to your main/sub jobs.', job_only = true},
	{key = 'georef',   name = 'Geo-Refresh',  text = 'Sustains a Geo-Refresh colure on the player.', job_only = true},
	{key = 'sublim',   name = 'Sublimation',  text = 'Automatically activates and completes Sublimation.', job_only = true},
}

statics.command_help = { -- shared by /sms help and the UI's HELP popup
	{section = 'Session', commands = {
		{'go',           'Activates a skillup session. Cannot activate if no skills have been added.'},
		{'stop',         'If active, deactivates the skillup session and provides a skillup report.'},
		{'pause',        'If active, toggles the session\'s paused/unpaused state.'},
		{'pauseon',      'If active and unpaused, pauses the session.'},
		{'pauseoff',     'If active and paused, unpauses the session.'},
		{'autoshutdown', 'If active, will perform /shutdown when the session\'s last remaining skill is capped.'},
		{'resetsession', 'Deactivates any active skillup session and removes all selected skills. (called on job change)'},
	}},
	{section = 'Skills', commands = {
		{'addskill',     'If skillable by the player\'s main job, adds the given skill to the current skillup session.'},
		{'delskill',     'Removes the given skill from the current skillup session.'},
		{'togskill',     'Adds/removes, if applicable, the given skill from the current skillup session.'},
		{'spellreport',  'Prints the spells SmartSkillup will use. Do "/sms spellreport weighted" to see the spell weights!'},
	}},
	{section = 'Modules', commands = {
		{'addmodule',    'Turns on the selected module. (Modules are additional misc skillup logic.)'},
		{'delmodule',    'Turns off the selected module. (Modules are additional misc skillup logic.)'},
		{'mplimit',      'An optional limit to provide heavier MP conservation; any spells above this limit will be skipped.'},
		{'modulehelp',   'Displays additional information on each module.'},
		{'automodules',  'Displays information on the automatic modules not listed in the UI.'},
	}},
	{section = 'UI', commands = {
		{'uihide',       'Hides the UI if it was visible. (persists on reload)'},
		{'uishow',       'Reveals the UI if it was hidden. (persists on reload)'},
		{'uiscale',      'Returns the UI scale or sets it to the provided scale. (persists on reload)'},
		{'uipos',        'Returns the UI position or sets it to the provided x/y coordinates. (persists on reload)'},
		{'uirebuild',    'Snaps the UI back to its saved position.'},
		{'uidefaults',   'Returns the UI to the default position and scale. (wipes all persisting settings)'},
	}},
	{section = 'Other', commands = {
		{'debug',        'Toggles debug-level logging ("debug" or "debug deep") and allows capped skills to be added. "debug off" disables all modes.'},
		{'help',         'Shows this help text.'},
	}},
}

statics.help_tips = {
	'You can only receive skillups for skills natively available to your current main job.',
	'The UI can be dragged with right mouse clicks or zoomed with scroll! Try it out!',
	'For additional module information, type "/sms modulehelp" or hover over MODULES!',
}

statics.numerals ={'',' II',' III',' IV',' V',' VI'}

statics.bags_ordered = { -- used for iterating bags, always processing inventory first (ids are Ashita container ids)
	{id = 0, en = 'Inventory'},
	{id = 5, en = 'Satchel'},
	{id = 6, en = 'Sack'},
	{id = 7, en = 'Case'},
}

statics.skillup_foods = { -- magic skillup foods, indexed by potency for ipairs usage
	{id = 5892, en = 'B.E.W. Pitaru'},  -- 80%
	{id = 5891, en = 'Seafood Pitaru'}, -- 60%
	{id = 5890, en = 'Poultry Pitaru'}, -- 40%
	{id = 5889, en = 'Stuffed Pitaru'}, -- 20%
}

statics.cities = { -- used to detect if the player can currently summon trusts/cast Geo-Refresh
	"Ru'Lude Gardens",     "Upper Jeuno",          "Lower Jeuno",         "Port Jeuno",      "Port Windurst",
	"Windurst Waters",     "Windurst Woods",       "Windurst Walls",      "Heavens Tower",   "Port San d'Oria",
	"Northern San d'Oria", "Southern San d'Oria",  "Port Bastok",         "Bastok Markets",  "Bastok Mines",
	"Metalworks",          "Aht Urhgan Whitegate", "Tavanazian Safehold", "Nashmau",         "Selbina",
	"Mhaura",              "Norg",                 "Eastern Adoulin",     "Western Adoulin", "Kazham",
}

statics.buffs = { -- buff ids (Windower's buffactive names replaced with ids)
	addle = 21,
	haste = 33,
	refresh = 43,
	sublimation_activated = 187,
	sublimation_complete = 188,
	food = 251,
	composure = 419,
	geo_refresh = 541, -- the colure "Refresh" from Indi-/Geo-Refresh
}

statics.JA_lock_buffs = {[16] = 'Amnesia', [262] = 'Omerta'}
statics.all_lock_buffs = {[2] = 'Sleep', [19] = 'Sleep', [10] = 'Stun', [14] = 'Charm', [17] = 'Charm', [28] = 'Terror', [7] = 'Petrification'}
statics.cast_lock_buffs = {[6] = 'Silence', [29] = 'Mute', [262] = 'Omerta'}

statics.self_refresh_spells = {['Refresh III'] = 4, ['Refresh II'] = 3, ['Battery Charge'] = 2, ['Refresh'] = 1} -- priority
statics.self_haste_spells = {['Haste II'] = 3, ['Erratic Flutter'] = 2, ['Haste'] = 1} -- priority

statics.larr = '<-' -- used for debug logging

return statics
