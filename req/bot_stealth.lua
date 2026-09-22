UsefulBots.stealth = UsefulBots.stealth or {}

local Stealth = UsefulBots.stealth
Stealth.NET_ID = "sh_stealth_cmd"
Stealth.COMMANDS = { wake = true, sleep = true, stash = true }


function Stealth:enabled()
	return UsefulBots.settings.stealth_bots and not Keepers and true or false
end

function Stealth:detection_mul()
	local mul = UsefulBots.settings.stealth_detection_mul

	return mul and mul > 0 and mul <= 1 and mul or 1
end

function Stealth:is_bot_unit(unit)
	local base = alive(unit) and unit:base()

	return base and not base.is_local_player and not base.is_husk_player and true or false
end

function Stealth:before_notice(table)
	if not table then
		return nil
	end

	local snapshot = {}

	for key, info in pairs(table) do
		snapshot[key] = info.notice_progress
	end

	return snapshot
end

function Stealth:after_notice(table, before, t)
	local mul = self:detection_mul()

	if not table or not before or mul >= 1 then
		return
	end

	for key, info in pairs(table) do
		if self:is_bot_unit(info.unit) then
			local was = before[key]

			if info.notice_progress == nil and info.identified and info.identified_t == t then
				local slow_progress = (was or 0) + (1 - (was or 0)) * mul

				if slow_progress < 1 then
					info.identified = nil
					info.release_t = nil
					info.identified_t = nil
					info.notice_progress = slow_progress
					info.prev_notice_chk_t = t
				end
			elseif info.notice_progress and was and info.notice_progress > was then
				info.notice_progress = was + (info.notice_progress - was) * mul
			end
		end
	end
end

function Stealth:count_alerted()
	local count = 0

	for _, u_data in pairs(managers.enemy:all_enemies()) do
		local unit = u_data.unit

		if alive(unit) and not unit:movement():cool() then
			local damage_ext = unit:character_damage()
			local anim_data = unit:anim_data()

			if (not damage_ext or not damage_ext:dead()) and not anim_data.hands_tied and not anim_data.hands_back and not anim_data.surrender then
				count = count + 1
			end
		end
	end

	return count
end

function Stealth:is_loud_bound()
	local state = managers.groupai:state()

	if state:is_police_called() or state:enemy_weapons_hot() or state._sh_camera_alarm then
		return true
	end

	local t = TimerManager:game():time()
	if not self._count_t or t > self._count_t + 0.5 then
		self._count_t = t
		self._alerted = self:count_alerted()
	end

	return self._alerted >= UsefulBots.settings.stealth_alert_count
end

function Stealth:holds_fire(unit)
	if not self:enabled() then
		return false
	end

	local base = alive(unit) and unit:base()
	if not base or not base._sh_stealth_awake then
		return false
	end

	if not managers.groupai:state():whisper_mode() then
		return false
	end

	return not self:is_loud_bound()
end

function Stealth:wake(unit)
	if not alive(unit) or not self:enabled() or not managers.groupai:state():whisper_mode() then
		return
	end

	local movement = unit:movement()
	if not movement:cool() then
		return
	end

	unit:base()._sh_stealth_awake = true
	movement:set_cool(false)

	StreamHeist:log("Stealth: %s is awake", UsefulBots.hold:bot_name(unit))
end

function Stealth:sleep(unit)
	if not alive(unit) or not self:enabled() or not managers.groupai:state():whisper_mode() then
		return
	end

	local movement = unit:movement()
	if movement:cool() then
		return
	end

	UsefulBots.bag:cancel(unit)

	UsefulBots.sneak:release(unit)
	unit:base()._sh_stealth_awake = nil
	UsefulBots.hold:reset(movement)
	if movement._should_stay then
		movement:set_should_stay(false)
	end

	movement:set_cool(true)

	StreamHeist:log("Stealth: %s is asleep again", UsefulBots.hold:bot_name(unit))
end

function Stealth:stash(unit, requester)
	if not alive(unit) or not self:holds_fire(unit) or not alive(unit:movement()._carry_unit) then
		return
	end

	UsefulBots.bag:request(unit, requester)
end

function Stealth:on_whisper_mode_ended()
	if UsefulBots.nav then
		UsefulBots.nav:restore_links()
	end

	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit
		local base = alive(unit) and unit:base()

		if base and base._sh_stealth_awake then
			UsefulBots.bag:cancel(unit)

			UsefulBots.sneak:release(unit)
			base._sh_stealth_awake = nil

			local brain = unit:brain()
			if brain and brain._attention_handler then
				PlayerMovement.set_attention_settings(brain, { "team_enemy_cbt" }, "team_AI")
			end

			StreamHeist:log("Stealth: whisper mode ended, %s goes back to normal", UsefulBots.hold:bot_name(unit))
		end
	end
end

function Stealth:request(unit, command)
	if Network:is_server() then
		self[command](self, unit, managers.player:player_unit())
		return
	end

	if not LuaNetworking or not LuaNetworking.SendToPeer or not (managers.network and managers.network:session()) then
		return
	end

	local name = managers.criminals:character_name_by_unit(unit)
	if name then
		LuaNetworking:SendToPeer(1, self.NET_ID, json.encode({ name = name, command = command }))
	end
end

function Stealth:receive_request(sender, data)
	local success, decoded = pcall(json.decode, data)
	if not success or type(decoded) ~= "table" or type(decoded.name) ~= "string" or not self.COMMANDS[decoded.command] then
		return
	end

	local unit = managers.criminals:character_unit_by_name(decoded.name)
	if not alive(unit) then
		return
	end

	local record = managers.groupai:state():all_criminals()[unit:key()]
	if not record or not record.ai then
		return
	end

	local session = managers.network:session()
	local peer = session and session:peer(sender)
	local peer_unit = peer and peer:unit()
	if not alive(peer_unit) or mvector3.distance(peer_unit:position(), unit:position()) > 5000 then
		return
	end

	self[decoded.command](self, unit, peer_unit)
end

if not Stealth._net_hooked then
	Stealth._net_hooked = true

	Hooks:Add("NetworkReceivedData", "NetworkReceivedDataStreamHeistStealth", function(sender, message_id, data)
		if message_id == Stealth.NET_ID and Network:is_server() then
			Stealth:receive_request(sender, data)
		end
	end)
end
