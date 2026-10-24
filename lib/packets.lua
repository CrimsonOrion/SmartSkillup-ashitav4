--[[Copyright © 2022, RolandJ
All rights reserved. (BSD 3-Clause, see smartskillup.lua for the full license text.)
Ashita v4 port: Hand-written parsers/builders for the few packets SmartSkillup uses (Windower's 'packets' lib replacement).
Layouts follow the Ashita-bundled libs/lin/packets.lua and addons/debuff.]]

local bit = require('bit')

local packets = {}



-------------------------------------------------------------------------------------------------------------------
-- Incoming 0x028: Action (bit-packed). Only the fields SmartSkillup reads are decoded.
-------------------------------------------------------------------------------------------------------------------
function packets.parse_action(data_raw)
	local u = ashita.bits.unpack_be
	local act = {
		actor_id     = u(data_raw,  40, 32),
		target_count = u(data_raw,  72,  6),
		category     = u(data_raw,  82,  4),
		param        = u(data_raw,  86, 32),
		targets      = {},
	}
	-- First target's first action param (the spell/item id on casting/item start)
	if act.target_count > 0 then
		local action_count = u(data_raw, 150 + 32, 4)
		if action_count > 0 then
			act.targets[1] = {actions = {{param = u(data_raw, 150 + 63, 17)}}}
		end
	end
	return act
end



-------------------------------------------------------------------------------------------------------------------
-- Incoming 0x029: Action Message
-------------------------------------------------------------------------------------------------------------------
function packets.parse_action_message(data)
	return {
		actor   = struct.unpack('I', data, 0x04 + 1),
		target  = struct.unpack('I', data, 0x08 + 1),
		param_1 = struct.unpack('I', data, 0x0C + 1),
		param_2 = struct.unpack('I', data, 0x10 + 1),
		message = struct.unpack('H', data, 0x18 + 1),
	}
end



-------------------------------------------------------------------------------------------------------------------
-- Incoming 0x062: Character Skills (level is the low 15 bits, capped is the high bit)
-------------------------------------------------------------------------------------------------------------------
function packets.parse_skill(data, skill_id)
	local raw = struct.unpack('H', data, 0x80 + (skill_id * 2) + 1)
	return bit.band(raw, 0x7FFF), bit.band(raw, 0x8000) ~= 0
end



-------------------------------------------------------------------------------------------------------------------
-- Outgoing 0x015: Player Position
-------------------------------------------------------------------------------------------------------------------
function packets.parse_position(data)
	return {
		x = struct.unpack('f', data, 0x04 + 1),
		z = struct.unpack('f', data, 0x08 + 1),
		y = struct.unpack('f', data, 0x0C + 1),
	}
end



-------------------------------------------------------------------------------------------------------------------
-- Outgoing builders
-------------------------------------------------------------------------------------------------------------------
-- 0x029: Move an item between bags (Windower's windower.ffxi.get_item replacement)
function packets.move_item(src_bag, src_slot, count, dest_bag)
	local p = struct.pack('BBBBIBBBB', 0x29, 0x06, 0x00, 0x00, count, src_bag, dest_bag or 0, src_slot, 0x52):totable()
	AshitaCore:GetPacketManager():AddOutgoingPacket(0x29, p)
end

-- 0x0F1: Cancel a buff (Windower's 'cancel' addon replacement, same as Ashita's debuff addon)
function packets.cancel_buff(buff_id)
	local p = struct.pack('bbbbhbb', 0xF1, 0x04, 0x00, 0x00, buff_id, 0x00, 0x00):totable()
	AshitaCore:GetPacketManager():AddOutgoingPacket(0xF1, p)
end

return packets
