--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: The Windower primitive/text UI (sms_ui, sms_images, sms_texts) recreated in ImGui.
Buttons are the original Button002 images drawn through the window draw list, with invisible ImGui buttons on
top for clicks/hovers. Positions and sizes follow the original UI's scalars and offsets. The UI reads addon state
each frame, so it needs no update calls. Text uses Arial Bold Italic, like the original.
Controls (same as the original): left-click buttons/labels, right-drag anywhere to move, scroll to zoom.]]

local bit = require('bit')
local ffi = require('ffi')
local d3d8 = require('d3d8')
local imgui = require('imgui')

local ui = {}

local colors = { -- 0-255, the original UI's colors
	white  = {255, 255, 255},
	grey   = { 96,  96,  96},
	blue   = { 51, 153, 255},
	yellow = {250, 250, 100},
	orange = {255, 153,  51},
	black  = {  0,   0,   0},
}

local zoning = false -- hidden between zone-out and zone-in, like the original
local right_drag -- {dx, dy} offset from the window origin while right-dragging
local last_saved_pos



-------------------------------------------------------------------------------------------------------------------
-- Small drawing helpers
-------------------------------------------------------------------------------------------------------------------
-- ImGui packs colors as ABGR; dim darkens like the original hover effect (color - 30)
local function col32(c, alpha, dim)
	local d = dim or 0
	local r, g, b = math.max(0, c[1] - d), math.max(0, c[2] - d), math.max(0, c[3] - d)
	return (alpha or 255) * 16777216 + b * 65536 + g * 256 + r
end

-- The original Button002 images, loaded once (false if loading failed, so we fall back to plain rectangles)
local textures = {}
local function texture(name)
	if textures[name] == nil then
		local base = addon.path
		if not base:match('[\\/]$') then base = base .. '\\' end
		local ptr = ffi.new('IDirect3DTexture8*[1]')
		if ffi.C.D3DXCreateTextureFromFileA(d3d8.get_device(), base .. 'data\\Button002-' .. name .. '.png', ptr) == ffi.C.S_OK then
			textures[name] = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]))
		else
			textures[name] = false
		end
	end
	return textures[name]
end

local function draw_button_image(dl, x, y, w, h, active, hovered)
	local tex = texture(active and 'Orange' or 'Blue')
	local tint = hovered and col32({225, 225, 225}) or col32(colors.white)
	if tex then
		dl:AddImage(tonumber(ffi.cast('uint32_t', tex)), {x, y}, {x + w, y + h}, {0, 0}, {1, 1}, tint)
	else
		dl:AddRectFilled({x, y}, {x + w, y + h}, col32(active and {200, 110, 40} or {90, 100, 170}, 255, hovered and 30), h / 2)
	end
end

-- The original's font (Arial Bold Italic). Must be loaded from the 'load' event: adding fonts to the atlas
-- mid-frame (d3d_present) can crash the client. CREDIT: Ashita's xiui addon for the approach.
local font -- nil until loaded; falls back to ImGui's default font (drawn with a faux bold)
function ui.load_font()
	local path = (os.getenv('WINDIR') or 'C:\\Windows') .. '\\Fonts\\arialbi.ttf'
	if not ashita.fs.exists(path) then return end
	local ok, result = pcall(imgui.AddFontFromFileTTF, path, 20.0)
	if ok and result then font = result end
end

-- Text with the original's look: a dark stroke around bold text
local function draw_text(dl, x, y, size, color, text)
	local f = font or imgui.GetFont()
	local stroke = col32(colors.black, 200)
	for _, o in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1}, {font and 1 or 2, 0}}) do
		dl:AddText(f, size, {x + o[1], y + o[2]}, stroke, text)
	end
	local fill = col32(color)
	dl:AddText(f, size, {x, y}, fill, text)
	if not font then dl:AddText(f, size, {x + 1, y}, fill, text) end -- faux bold for the default font
end

local function text_size(size, text)
	imgui.PushFont(font or imgui.GetFont(), size)
	local w, h = imgui.CalcTextSize(text)
	imgui.PopFont()
	return w + (font and 0 or 1), h -- +1 for the faux bold
end

-- An invisible click area; returns clicked, hovered, held
local function hit(id, x, y, w, h)
	imgui.SetCursorScreenPos({x, y})
	local clicked = imgui.InvisibleButton(id, {math.max(1, w), math.max(1, h)})
	return clicked, imgui.IsItemHovered(), imgui.IsItemActive()
end

-- A clickable text label (ON, OFF, PAUSED, HELP, etc). Returns true when clicked.
local function text_button(dl, id, x, y, size, color, text, s)
	local w, h = text_size(size, text)
	local clicked, hovered, held = hit(id, x, y, w, h)
	local off = held and s or 0
	draw_text(dl, x + off, y + off, size, hovered and {math.max(0, color[1] - 30), math.max(0, color[2] - 30), math.max(0, color[3] - 30)} or color, text)
	return clicked, hovered
end

-- An image button with a label (and optional subtext at a fixed x offset). Returns true when clicked.
local function image_button(dl, id, x, y, w, h, active, label, label_size, label_x, label_color, subtext, subtext_x, s)
	local clicked, hovered, held = hit(id, x, y, w, h)
	local off = held and s or 0 -- the original nudged the button 1px down/right while held
	draw_button_image(dl, x + off, y + off, w, h, active, hovered)
	local _, th = text_size(label_size, label)
	local ty = y + off + (h - th) / 2
	draw_text(dl, x + off + label_x, ty, label_size, label_color, label)
	if subtext then draw_text(dl, x + off + subtext_x, ty, label_size, label_color, subtext) end
	return clicked
end



-------------------------------------------------------------------------------------------------------------------
-- Hover popups
-------------------------------------------------------------------------------------------------------------------
local function rgba(c) return {c[1] / 255, c[2] / 255, c[3] / 255, 1} end

-- A theme matching the Button002 images: dark navy body, periwinkle border, button-blue headers, orange when pressed.
-- Push before Begin/BeginTooltip (window styling is read there) and pop after End/EndTooltip.
local theme_colors = {
	{ImGuiCol_WindowBg,         {0.05, 0.06, 0.15, 0.94}},
	{ImGuiCol_PopupBg,          {0.05, 0.06, 0.15, 0.94}},
	{ImGuiCol_Border,           {0.55, 0.58, 0.88, 0.90}},
	{ImGuiCol_TitleBg,          {0.20, 0.23, 0.50, 1.00}},
	{ImGuiCol_TitleBgActive,    {0.27, 0.31, 0.64, 1.00}},
	{ImGuiCol_TitleBgCollapsed, {0.20, 0.23, 0.50, 1.00}},
	{ImGuiCol_Header,           {0.33, 0.37, 0.72, 0.90}},
	{ImGuiCol_HeaderHovered,    {0.44, 0.48, 0.84, 0.95}},
	{ImGuiCol_HeaderActive,     {0.80, 0.42, 0.10, 1.00}},
	{ImGuiCol_Separator,        {0.55, 0.58, 0.88, 0.60}},
	{ImGuiCol_Button,           {0.00, 0.00, 0.00, 0.00}}, -- the title bar's close X
	{ImGuiCol_ButtonHovered,    {0.80, 0.42, 0.10, 0.85}},
	{ImGuiCol_ButtonActive,     {0.66, 0.33, 0.06, 1.00}},
	{ImGuiCol_Text,             {1.00, 1.00, 1.00, 1.00}},
}
local function push_theme(s)
	for _, c in ipairs(theme_colors) do imgui.PushStyleColor(c[1], c[2]) end
	imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8 * s)
	imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, 8 * s)
	imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 10 * s) -- pill-shaped section headers, like the buttons
	imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.5)
	imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1.5)
	imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {8 * s, 6 * s}) -- the main window pushes 0 padding; popups need their own
	imgui.PushFont(font or imgui.GetFont(), 15 * s) -- before Begin, so the title bar uses it too
end
local function pop_theme()
	imgui.PopFont()
	imgui.PopStyleVar(6)
	imgui.PopStyleColor(#theme_colors)
end

-- MODULES: every module's description, colored by state (orange: on, white: available, grey: not on this job)
local function modules_popup(s)
	push_theme(s)
	imgui.BeginTooltip()
	imgui.PushTextWrapPos(340 * s)
	imgui.TextColored(rgba(colors.yellow), 'Modules')
	imgui.Separator()
	for _, help in ipairs(statics.module_help) do
		local mod = modules and modules[help.key]
		local available, on = mod and mod.available, mod and mod.active
		local name_color = on and colors.orange or (available and colors.white or {140, 140, 140})
		imgui.TextColored(rgba(name_color), help.name .. (on and '  (on)' or (not available and '  (not available on this job)' or '')))
		imgui.Indent(12 * s)
		imgui.PushStyleColor(ImGuiCol_Text, rgba(available and {200, 200, 200} or {140, 140, 140}))
		imgui.TextWrapped(help.text)
		imgui.PopStyleColor(1)
		imgui.Unindent(12 * s)
	end
	imgui.Separator()
	imgui.TextColored(rgba({140, 140, 140}), 'Click MODULES to print this in chat.')
	imgui.PopTextWrapPos()
	imgui.EndTooltip()
	pop_theme()
end



-- HELP (hover): a short pointer to the help window
local function help_hint(s)
	push_theme(s)
	imgui.BeginTooltip()
	imgui.TextColored(rgba(colors.white), 'Click for command help')
	imgui.EndTooltip()
	pop_theme()
end

-- HELP (click): a closable window with a collapsible section per command group, plus the tips
ui.help_open = {false}
local function help_window(s, anchor_x, anchor_y)
	if not ui.help_open[1] then return end
	local cmd_w, desc_w = 110 * s, 430 * s
	imgui.SetNextWindowPos({anchor_x, anchor_y}, ImGuiCond_Appearing)
	local flags = bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoSavedSettings)
	push_theme(s)
	if imgui.Begin('SmartSkillup Help##sms_help', ui.help_open, flags) then
		imgui.TextColored(rgba(colors.yellow), 'SmartSkillup v' .. addon.version .. ' commands  (type /sms [command])')
		local table_flags = bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_NoSavedSettings)
		for _, group in ipairs(statics.command_help) do
			if imgui.CollapsingHeader(group.section .. ' (' .. #group.commands .. ')##sms_help_' .. group.section) then
				if imgui.BeginTable('##sms_help_table_' .. group.section, 2, table_flags) then
					imgui.TableSetupColumn('command', ImGuiTableColumnFlags_WidthFixed, cmd_w, 0)
					imgui.TableSetupColumn('description', ImGuiTableColumnFlags_WidthFixed, desc_w, 0)
					for _, entry in ipairs(group.commands) do
						imgui.TableNextRow()
						imgui.TableSetColumnIndex(0)
						imgui.TextColored(rgba(colors.orange), entry[1])
						imgui.TableSetColumnIndex(1)
						imgui.PushStyleColor(ImGuiCol_Text, rgba({220, 220, 220}))
						imgui.TextWrapped(entry[2])
						imgui.PopStyleColor(1)
					end
					imgui.EndTable()
				end
			end
		end
		if imgui.CollapsingHeader('Tips (' .. #statics.help_tips .. ')##sms_help_tips') then
			imgui.PushTextWrapPos(imgui.GetCursorPosX() + cmd_w + desc_w)
			for _, tip in ipairs(statics.help_tips) do
				imgui.PushStyleColor(ImGuiCol_Text, rgba({220, 220, 220}))
				imgui.TextWrapped('- ' .. tip)
				imgui.PopStyleColor(1)
			end
			imgui.PopTextWrapPos()
		end
	end
	imgui.End()
	pop_theme()
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

	-- SIZES & OFFSETS (the original's scalars; text sizes were points, so x4/3 for pixels)
	local s = settings.user_ui_scalar
	local W, H, SW, SH, GAP = 209 * s, 23 * s, 70 * s, 17 * s, 1 * s
	local font = 13 * 4 / 3 * s
	local small = font * 0.65 -- header/footer labels
	local HEADER, FOOTER = math.max(font * 0.7, small) * 1.15 + 3 * s, small * 1.15 + 3 * s

	local names = util.keys(main_skills, true)
	local placeholder = #names == 0
	local mods = {}
	if not placeholder and modules then
		for _, key in ipairs(statics.modules_order) do
			if modules[key].available and not modules[key].hidden then mods[#mods+1] = modules[key] end
		end
	end
	local rows_h = math.max(1, #names) * (H + GAP)
	local side_h = #mods * (SH + GAP) + ((modules and modules.mp_limit.active) and small * 1.15 + 2 * s or 0)
	local width = #mods > 0 and (210 * s + SW + 4 * s) or (W + 4 * s)
	local height = HEADER + math.max(rows_h, side_h) + FOOTER

	-- WINDOW (transparent; everything is drawn through the draw list)
	imgui.SetNextWindowPos({settings.top_left.x, settings.top_left.y}, (ui.force_pos or right_drag) and ImGuiCond_Always or ImGuiCond_FirstUseEver)
	ui.force_pos = nil
	imgui.SetNextWindowSize({width, height}, ImGuiCond_Always)
	imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {0, 0})
	imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
	local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoCollapse,
		ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoScrollWithMouse)
	if imgui.Begin('SmartSkillup##sms_main', true, flags) then
		local dl = imgui.GetWindowDrawList()
		local ox, oy = imgui.GetWindowPos()
		local top = oy + HEADER

		-- HEADER: title on the left; ON / OFF, PAUSED, HELP right-aligned to the skill buttons; MODULES over the sidecar
		draw_text(dl, ox + 2 * s, oy + 1 * s, font * 0.7, colors.yellow, 'SmartSkillup')
		local _, small_h = text_size(small, 'A')
		local hy = top - small_h - 2 * s
		local event_paused = next(event_pauses) ~= nil
		local header_items = { -- {id, text, color, gap after}
			{'on',     'ON',     active and colors.white or colors.grey, 2 * s},
			{nil,      '/',      colors.grey,                            2 * s},
			{'off',    'OFF',    active and colors.grey or colors.white, 9 * s},
			{'paused', 'PAUSED', (active and paused) and colors.white or (event_paused and colors.orange or colors.grey), 9 * s},
			{'help',   'HELP',   colors.white,                           0},
		}
		local hx = ox + W - 4 * s
		for _, item in ipairs(header_items) do hx = hx - text_size(small, item[2]) - item[4] end
		local clicked = {}
		for _, item in ipairs(header_items) do
			if item[1] then
				local was_clicked, was_hovered = text_button(dl, '##sms_' .. item[1], hx, hy, small, item[3], item[2], s)
				clicked[item[1]] = was_clicked
				if item[1] == 'paused' and was_hovered and event_paused then
					push_theme(s)
					imgui.SetTooltip('Event pauses: ' .. table.concat(util.keys(event_pauses, true), ', '))
					pop_theme()
				elseif item[1] == 'help' and was_hovered then
					help_hint(s)
				end
			else
				draw_text(dl, hx, hy, small, item[3], item[2])
			end
			hx = hx + text_size(small, item[2]) + item[4]
		end
		if clicked.on then handle_command({'go'}) end
		if clicked.off then handle_command({'stop'}) end
		if clicked.paused then handle_command({'pause'}) end
		if clicked.help then ui.help_open[1] = not ui.help_open[1] end
		if #mods > 0 then
			local modules_clicked, modules_hovered = text_button(dl, '##sms_modules', ox + 213 * s, hy, small, colors.white, 'MODULES', s)
			if modules_clicked then handle_command({'modulehelp'}) end
			if modules_hovered then modules_popup(s) end
		end

		-- SKILL BUTTONS
		if placeholder then
			if image_button(dl, '##sms_placeholder', ox, top, W, H, false, 'No Magic Skills', font, 6 * s, colors.white, nil, nil, s) then
				handle_command({'nomagicskills'})
			end
		end
		for i, name in ipairs(names) do
			local data = main_skills[name]
			local in_session = util.contains(skills_to_skillup, name)
			local text_color = (data.capped and not util.any_debug()) and colors.blue or colors.white
			local short = #name <= 16 and name or name:sub(1, 16) .. '...'
			local y = top + (i - 1) * (H + GAP)
			if image_button(dl, '##sms_skill_' .. name, ox, y, W, H, in_session, short, font, 6 * s, text_color, tostring(data.level or ''), 167 * s, s) then
				handle_command({'togs', 'silent', name})
			end
		end

		-- FOOTER (spans both columns): AUTO-SHUTDOWN on the left; MAIN JOB SKILLS: <job> right-aligned
		local fy = top + math.max(rows_h, side_h) + 1 * s
		if text_button(dl, '##sms_shutdown', ox + 4 * s, fy, small, auto_shutdown and colors.orange or colors.grey, 'AUTO-SHUTDOWN', s) then
			handle_command({'autoshutdown'})
		end
		local job = tostring(me.main_job)
		local job_x = ox + width - 4 * s - text_size(small, job)
		local mj_label = 'MAIN JOB SKILLS:'
		local shutdown_end = ox + 4 * s + text_size(small, 'AUTO-SHUTDOWN')
		if job_x - 4 * s - text_size(small, mj_label) < shutdown_end + 8 * s then mj_label = 'MAIN JOB:' end -- no room: shorten
		draw_text(dl, job_x, fy, small, colors.orange, job)
		draw_text(dl, job_x - 4 * s - text_size(small, mj_label), fy, small, colors.white, mj_label)

		-- MODULES SIDECAR
		local sx = ox + 210 * s
		for i, mod in ipairs(mods) do
			local y = top + (i - 1) * (SH + GAP)
			if image_button(dl, '##sms_mod_' .. mod.label, sx, y, SW, SH, mod.active, mod.label, font * 0.7, 6 * s, colors.white, nil, nil, s) then
				handle_command({'togm', 'silent', mod.label})
			end
		end
		if modules and modules.mp_limit.active and #mods > 0 then
			local ly = top + #mods * (SH + GAP) + 1 * s
			draw_text(dl, sx + 6 * s, ly, small, colors.white, 'MP LIMIT:')
			if text_button(dl, '##sms_mp_limit', sx + 6 * s + text_size(small, 'MP LIMIT:') + 4 * s, ly, small, colors.orange, tostring(mp_limit or 10), s) then
				handle_command({'mplimit', 'toggle', 'silent'})
			end
		end

		-- RIGHT-DRAG ANYWHERE TO MOVE (like the original)
		local mx, my = imgui.GetMousePos()
		local hovered = imgui.IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem)
		if hovered and imgui.IsMouseClicked(1) then
			right_drag = {dx = mx - ox, dy = my - oy}
		end
		if right_drag then
			if imgui.IsMouseDown(1) then
				settings.top_left.x, settings.top_left.y = mx - right_drag.dx, my - right_drag.dy
			else
				right_drag = nil
				last_saved_pos = {x = settings.top_left.x, y = settings.top_left.y}
				save_settings()
			end

		-- PERSIST POSITION AFTER A LEFT-DRAG OF EMPTY SPACE
		elseif not imgui.IsMouseDown(0) and (ox ~= settings.top_left.x or oy ~= settings.top_left.y) then
			if last_saved_pos == nil or last_saved_pos.x ~= ox or last_saved_pos.y ~= oy then
				settings.top_left.x, settings.top_left.y = ox, oy
				last_saved_pos = {x = ox, y = oy}
				save_settings()
			end
		end

		-- SCROLL TO ZOOM (like the original)
		local wheel = hovered and imgui.GetIO().MouseWheel or 0
		if wheel ~= 0 then
			handle_command({'uizoom', wheel > 0 and 'in' or 'out'})
		end
	end
	imgui.End()
	imgui.PopStyleVar(2)

	-- HELP WINDOW (opened by clicking HELP), placed just right of the UI when it opens
	help_window(s, settings.top_left.x + width + 8 * s, settings.top_left.y)
end

return ui
