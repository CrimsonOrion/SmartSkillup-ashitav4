--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: Replaces the Windower-specific coroutine.schedule/coroutine.close, add_to_chat, and T{}/S{} helpers.]]

local util = {}



-------------------------------------------------------------------------------------------------------------------
-- A cancellable timer queue (Windower's coroutine.schedule + coroutine.close replacement)
-- LuaJIT has no coroutine.close and ashita.tasks cannot be cancelled, so all delayed work goes through here.
-- util.process_timers() must be called every frame (d3d_present).
-------------------------------------------------------------------------------------------------------------------
local timers = {}

function util.now()
	return os.clock()
end

function util.schedule(delay, fn, ...)
	local handle = {at = util.now() + (delay or 0), fn = fn, args = {...}, n = select('#', ...)}
	timers[#timers+1] = handle
	return handle
end

function util.cancel(handle)
	if handle then handle.cancelled = true end
end

function util.cancel_all()
	for _, handle in ipairs(timers) do handle.cancelled = true end
	timers = {}
end

function util.process_timers()
	if #timers == 0 then return end
	local now, due, pending = util.now(), {}, {}
	for _, handle in ipairs(timers) do
		if not handle.cancelled then
			if handle.at <= now then due[#due+1] = handle else pending[#pending+1] = handle end
		end
	end
	timers = pending -- swap before running, so timers scheduled by the callbacks are kept
	for _, handle in ipairs(due) do
		if not handle.cancelled then
			handle.cancelled = true -- a fired timer can no longer be cancelled
			local ok, err = pcall(handle.fn, unpack(handle.args, 1, handle.n))
			if not ok then util.log(util.colors.red, '[ERROR] ' .. tostring(err)) end
		end
	end
end



-------------------------------------------------------------------------------------------------------------------
-- Chat output (Windower's add_to_chat replacement; FFXI chat modes are shared between both platforms)
-------------------------------------------------------------------------------------------------------------------
util.colors = {
	yellow = 36,
	red = 123,
	grey = 207,
	green = 215,
	purple = 200,
	lpurple = 8,
}

util.debug_modes = {norm = false, deep = false}

function util.log(color, msg)
	AshitaCore:GetChatManager():AddChatMessage(color, false, '[SmartSkillup] ' .. tostring(msg))
end

-- A convenient logger that prefixes every message (same signature as the Windower version)
function util.logger(color, msg, is_debug_msg, deep_debug_msg)
	if is_debug_msg == nil or (util.debug_modes.norm and is_debug_msg) or (util.debug_modes.deep and deep_debug_msg) then
		util.log(color, msg)
	end
end

function util.any_debug()
	return util.debug_modes.norm or util.debug_modes.deep
end



-------------------------------------------------------------------------------------------------------------------
-- Game command output (Windower's send_command('input ...') replacement)
-------------------------------------------------------------------------------------------------------------------
function util.input(command)
	AshitaCore:GetChatManager():QueueCommand(1, command)
end



-------------------------------------------------------------------------------------------------------------------
-- Plain-table helpers (stand-ins for the Windower T{}/S{} methods the addon relied upon)
-------------------------------------------------------------------------------------------------------------------
function util.index_of(t, value)
	for i, v in ipairs(t) do
		if v == value then return i end
	end
	return nil
end

function util.contains(t, value)
	for _, v in pairs(t) do
		if v == value then return true end
	end
	return false
end

function util.find(t, fn)
	for k, v in pairs(t) do
		if fn(v, k) then return k, v end
	end
	return nil
end

function util.count(t, fn)
	local n = 0
	for k, v in pairs(t) do
		if fn == nil or fn(v, k) then n = n + 1 end
	end
	return n
end

function util.keys(t, sorted)
	local keys = {}
	for k in pairs(t) do keys[#keys+1] = k end
	if sorted then table.sort(keys) end
	return keys
end

function util.copy(t)
	if type(t) ~= 'table' then return t end
	local c = {}
	for k, v in pairs(t) do c[k] = util.copy(v) end
	return c
end

function util.remove_value(t, value)
	local i = util.index_of(t, value)
	if i then table.remove(t, i) end
end



-------------------------------------------------------------------------------------------------------------------
-- String helpers
-------------------------------------------------------------------------------------------------------------------
function util.startswith(s, prefix)
	return s ~= nil and s:sub(1, #prefix) == prefix
end

function util.endswith(s, suffix)
	return s ~= nil and (suffix == '' or s:sub(-#suffix) == suffix)
end

-- Windower's string.wmatch: '|' separated alternatives, '*' wildcards, case-insensitive, whole-string
function util.wmatch(s, pattern)
	if s == nil then return false end
	s = s:lower()
	for alt in pattern:gmatch('[^|]+') do
		local lua_pattern = '^' .. alt:lower():gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*') .. '$'
		if s:match(lua_pattern) then return true end
	end
	return false
end

function util.fuzzy(s)
	return (s:lower():gsub('%s', ''):gsub('%p', ''))
end

return util
