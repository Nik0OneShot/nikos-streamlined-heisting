-- Stealth commands for team AI (stage 1: wake / sleep, fire discipline, "is the heist going loud" check)
--
-- In stealth bots are "cool": asleep, no weapon out, no mask, and vanilla does not let you command them at all.
-- Holding the follow key on a bot wakes it (mask on, follows you), holding the wait key on an awake bot sends it back to
-- sleep, see lua/playerstandard.lua. Awake bots
--   - are noticed like a player with a mask on (see the hook in lua/teamaibrain.lua), not like an enemy in combat
--   - keep their weapon lowered, do not mark or intimidate anything, until the heist is going loud
--   - go back to normal when whisper mode ends
--
-- The heist is going loud (stealth is given up) when the police were called, a camera started its alarm, the enemies
-- have their weapons hot, or enough enemies are alerted (setting stealth_alert_count, 5 by default).
--
-- Flags: unit:base()._sh_stealth_awake is set on bots that were woken by a player.

UsefulBots.stealth = UsefulBots.stealth or {}

local Stealth = UsefulBots.stealth
Stealth.NET_ID = "sh_stealth_cmd"
Stealth.COMMANDS = { wake = true, sleep = true, stash = true }


function Stealth:enabled()
	return UsefulBots.settings.stealth_bots and not Keepers and true or false
end

-- How much slower a bot builds up notice than a player doing the same thing, 1 = same as a player, lower is slower
function Stealth:detection_mul()
	local mul = UsefulBots.settings.stealth_detection_mul

	return mul and mul > 0 and mul <= 1 and mul or 1
end

-- Never a real player (local or a networked one): the same two flags the game itself checks for exactly this in
-- lib/units/enemies/cop/logics/coplogicbase.lua, so a bot is whatever is left once both are false
function Stealth:is_bot_unit(unit)
	if not alive(unit) then
		return false
	end

	-- "not a real player" alone also matches a tied civilian, a dropped bag, a drill, or anything else a guard or camera can be
	-- suspicious of that is not a character at all - all of those would have gotten the same slowdown as an actual bot teammate.
	-- Checked against the criminal roster itself instead: only an AI-controlled member of the crew is a bot
	local record = managers.groupai:state():all_criminals()[unit:key()]

	return record and record.ai and true or false
end

-- The real, native buildup of notice against a bot (never a player) is slowed by the multiplier above, straight from the game's own
-- detection math rather than the mod's own predictive model (that is req/bot_sneak.lua, a separate thing, used only for planning
-- routes ahead of time - this is what a camera or a guard actually collects on a bot this instant, used by lua/coplogicbase.lua and
-- lua/securitycamera.lua). table is a set of attention_info entries keyed by the unit being noticed: data.detected_attention_objects
-- for a guard or civilian, self._detected_attention_objects for a camera. Call before_notice(table) right before the vanilla update
-- runs and keep what it returns, then call after_notice(table, before, t) right after: only what this one update just added is
-- scaled, decay (breaking contact) is left alone, and a bot that would have just been fully identified this update, but not at the
-- slower rate, has that undone (t has to be the same time value the vanilla update itself used, or the next update's own math breaks
-- on a nil previous-check time)
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
				-- it crossed over to fully identified this update, at the full player rate: undo that if the slower rate would not
				-- have gotten there yet (the least it could have taken to cross over, scaled the same way)
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

-- Enemies that have noticed something, tied or surrendering ones and civilians do not count
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

	-- counting is a bit expensive, twice a second is enough
	local t = TimerManager:game():time()
	if not self._count_t or t > self._count_t + 0.5 then
		self._count_t = t
		self._alerted = self:count_alerted()
	end

	return self._alerted >= UsefulBots.settings.stealth_alert_count
end

-- True for awake bots that must not fire right now
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


-- Commands, host side

function Stealth:wake(unit)
	if not alive(unit) or not self:enabled() or not managers.groupai:state():whisper_mode() then
		return
	end

	local movement = unit:movement()
	if not movement:cool() then
		return
	end

	-- the flag has to be set first, the attention settings are chosen when the bot is switched
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

-- The heist is going loud, awake bots are noticed like they normally are again
-- The no-smash link check (req/bot_nav.lua) is only ever scheduled relative to when the first nav link registers, which usually
-- means level load - long before a real playthrough gets into stealth. Its whole reason to recheck at all is that a window's own
-- geometry can still not be solid yet at the moment its link registers, so if stealth only starts after those scheduled rechecks
-- already came and went (whisper_mode was not on yet when they fired, so they did nothing), no window ever gets a working check
-- again for the rest of the heist. This runs the same recheck again the moment stealth actually starts, plus once more a few
-- seconds later for the same "not solid yet" reason - and the existing "closed to the bots" / "more links were closed" log lines
-- in bot_nav.lua will show whether it is catching something it was not catching before
function Stealth:on_whisper_mode_started()
	local ok, err = pcall(function()
		if UsefulBots.nav then
			UsefulBots.nav:recheck_links()

			if DelayedCalls then
				DelayedCalls:Add("sh_nav_recheck_whisper", 6, function()
					if UsefulBots and UsefulBots.nav then
						UsefulBots.nav:recheck_links()
					end
				end)
			end
		end
	end)

	if not ok then
		StreamHeist:error("Stealth: the no-smash links could not be looked at again when stealth started: %s", tostring(err))
	end
end

function Stealth:on_whisper_mode_ended()
	-- windows with glass are open to the bots again
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


-- Commands, called on the machine of the player that gave them

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

	-- the sender has to be somewhere near the bot
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
