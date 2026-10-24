--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: The Windower primitive/text UI (sms_ui, sms_images, sms_texts) rebuilt as an ImGui window.
The layout mirrors the original: header (ON/OFF, PAUSE, HELP), skill buttons, auto-shutdown/main job footer,
and the modules sidecar with the MP limit. The UI reads addon state each frame, so it needs no update calls.]]

local bit = require('bit')
local imgui = require('imgui')

local ui = {}

local colors = {
	white  = {1.00, 1.00, 1.00, 1.0},
	grey   = {0.38, 0.38, 0.38, 1.0},
	blue   = {0.20, 0.60, 1.00, 1.0},
	yellow = {0.98, 0.98, 0.39, 1.0},
	orange = {1.00, 0.60, 0.20, 1.0},
}
local button_colors = {
	idle   = {{0.13, 0.27, 0.53, 0.9}, {0.20, 0.36, 0.66, 0.9}, {0.10, 0.20, 0.42, 1.0}}, -- normal, hovered, pressed
	active = {{0.80, 0.42, 0.10, 0.9}, {0.90, 0.52, 0.18, 0.9}, {0.66, 0.33, 0.06, 1.0}},
}

local zoning = false -- hidden between zone-out and zone-in, like the original
local last_saved_pos



-------------------------------------------------------------------------------------------------------------------
-- Small drawing helpers
-------------------------------------------------------------------------------------------------------------------
local function push_button_colors(is_active)
	local c = button_colors[is_active and 'active' or 'idle']
	imgui.PushStyleColor(ImGuiCol_Button, c[1])
	imgui.PushStyleColor(ImGuiCol_ButtonHovered, c[2])
	imgui.PushStyleColor(ImGuiCol_ButtonActive, c[3])
end

-- A clickable text label (ON, OFF, PAUSE, HELP, etc). Returns true when clicked.
local function text_button(label, color, id)
	imgui.PushStyleColor(ImGuiCol_Text, color)
	imgui.PushStyleColor(ImGuiCol_Button, {0, 0, 0, 0})
	imgui.PushStyleColor(ImGuiCol_ButtonHovered, {1, 1, 1, 0.12})
	imgui.PushStyleColor(ImGuiCol_ButtonActive, {1, 1, 1, 0.20})
	local clicked = imgui.SmallButton(label .. '##' .. (id or label))
	imgui.PopStyleColor(4)
	return clicked
end

-- A skill/module button: label on the left, optional subtext (skill level) on the right
local function toggle_button(label, subtext, is_active, text_color, width, height)
	push_button_colors(is_active)
	imgui.PushStyleColor(ImGuiCol_Text, text_color)
	local text = label
	if subtext then
		local pad = width - imgui.CalcTextSize(label) - imgui.CalcTextSize(subtext) - 16
		text = label .. string.rep(' ', math.max(1, math.floor(pad / imgui.CalcTextSize(' ')))) .. subtext
	end
	local clicked = imgui.Button(text .. '##' .. label, {width, height})
	imgui.PopStyleColor(4)
	return clicked
end



-------------------------------------------------------------------------------------------------------------------
-- Visibility helpers (zone-out/zone-in hide the UI, matching the original)
-------------------------------------------------------------------------------------------------------------------
function ui.show_primitives(bool)
	zoning = not bool
end



-------------------------------------------------------------------------------------------------------------------
-- The function that draws the UI each frame
-------------------------------------------------------------------------------------------------------------------
function ui.render()
	if settings.ui_hidden or zoning or not sms_ready or main_skills == nil then return end

	local scale = settings.user_ui_scalar
	local skill_w, skill_h = 209 * scale, 23 * scale
	local module_w, module_h = 76 * scale, 19 * scale

	imgui.SetNextWindowPos({settings.top_left.x, settings.top_left.y}, ui.force_pos and ImGuiCond_Always or ImGuiCond_FirstUseEver)
	ui.force_pos = nil
	imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {4 * scale, 2 * scale})
	local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoScrollbar)
	if imgui.Begin('SmartSkillup##sms_main', true, flags) then
		if imgui.SetWindowFontScale then imgui.SetWindowFontScale(scale) end

		-- HEADER: title, ON/OFF, PAUSE, HELP
		imgui.TextColored(colors.yellow, 'SmartSkillup')
		imgui.SameLine()
		if text_button('ON', active and colors.white or colors.grey) then handle_command({'go'}) end
		imgui.SameLine(0, 0)
		imgui.TextColored(colors.grey, '/')
		imgui.SameLine(0, 0)
		if text_button('OFF', active and colors.grey or colors.white) then handle_command({'stop'}) end
		imgui.SameLine()
		local pause_color = (active and paused) and colors.white or (next(event_pauses) ~= nil and colors.orange or colors.grey)
		if text_button('PAUSE', pause_color) then handle_command({'pause'}) end
		imgui.SameLine()
		if text_button('HELP', colors.white) then handle_command({'help'}) end
		if imgui.IsItemHovered() and next(event_pauses) ~= nil then
			imgui.SetTooltip('Event pauses: ' .. table.concat(util.keys(event_pauses, true), ', '))
		end

		-- LEFT COLUMN: SKILL BUTTONS
		imgui.BeginGroup()
		local skill_names = util.keys(main_skills, true)
		if #skill_names == 0 then
			if toggle_button('No Magic Skills', nil, false, colors.white, skill_w, skill_h) then handle_command({'nomagicskills'}) end
		end
		for _, name in ipairs(skill_names) do
			local data = main_skills[name]
			local in_session = util.contains(skills_to_skillup, name)
			local text_color = (data.capped and not util.any_debug()) and colors.blue or colors.white
			local short = #name <= 16 and name or name:sub(1, 16) .. '...'
			if toggle_button(short, tostring(data.level or ''), in_session, text_color, skill_w, skill_h) then
				handle_command({'togs', 'silent', name})
			end
		end

		-- FOOTER: AUTO-SHUTDOWN & MAIN JOB
		if text_button('AUTO-SHUTDOWN', auto_shutdown and colors.orange or colors.grey) then handle_command({'autoshutdown'}) end
		imgui.SameLine()
		imgui.TextColored(colors.white, 'MAIN JOB SKILLS:')
		imgui.SameLine()
		imgui.TextColored(colors.orange, tostring(me.main_job))
		imgui.EndGroup()

		-- RIGHT COLUMN: MODULES SIDECAR
		if #skill_names > 0 and modules then
			imgui.SameLine()
			imgui.BeginGroup()
			if text_button('MODULES', colors.white) then handle_command({'modulehelp'}) end
			for _, key in ipairs(statics.modules_order) do
				local mod = modules[key]
				if mod.available and not mod.hidden then
					if toggle_button(mod.label, nil, mod.active, colors.white, module_w, module_h) then
						handle_command({'togm', 'silent', mod.label})
					end
				end
			end
			if modules.mp_limit.active then
				imgui.TextColored(colors.white, 'MP LIMIT:')
				imgui.SameLine()
				if text_button(tostring(mp_limit or 10), colors.orange, 'mp_limit_value') then
					handle_command({'mplimit', 'toggle', 'silent'})
				end
			end
			imgui.EndGroup()
		end

		-- PERSIST POSITION AFTER A DRAG
		local x, y = imgui.GetWindowPos()
		if not imgui.IsMouseDown(0) and (x ~= settings.top_left.x or y ~= settings.top_left.y) then
			if last_saved_pos == nil or last_saved_pos.x ~= x or last_saved_pos.y ~= y then
				settings.top_left.x, settings.top_left.y = x, y
				last_saved_pos = {x = x, y = y}
				save_settings()
			end
		end
	end
	imgui.End()
	imgui.PopStyleVar(1)
end

return ui
