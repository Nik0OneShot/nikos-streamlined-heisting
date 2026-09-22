-- A camera that starts its alarm means the heist is going loud, awake bots in stealth stop holding their fire
-- (see req/bot_stealth.lua). The police call follows a few seconds later.
Hooks:PostHook(SecurityCamera, "_sound_the_alarm", "sh_sound_the_alarm", function()
	if not Network:is_server() then
		return
	end

	local state = managers.groupai:state()
	if not state._sh_camera_alarm then
		state._sh_camera_alarm = true

		StreamHeist:log("A camera started its alarm, the heist is going loud")
	end
end)


-- What set a camera off: who it was, and who else it was watching (a camera drops all of that right after the alarm starts)
local function describe(unit)
	if not alive(unit) then
		return "nobody"
	end

	if unit == managers.player:player_unit() then
		return "the player"
	end

	if managers.groupai:state():is_unit_team_AI(unit) then
		return UsefulBots.hold:bot_name(unit)
	end

	return "someone (" .. tostring(unit:base() and unit:base()._tweak_table or "?") .. ")"
end

Hooks:PreHook(SecurityCamera, "_sound_the_alarm", "sh_sound_the_alarm_pre", function(self, detected_unit)
	if self._alarm_sound or not Network:is_server() then
		return
	end

	local watching = {}

	for _, info in pairs(self._detected_attention_objects or {}) do
		table.insert(watching, string.format("%s %s", describe(info.unit), info.identified and "identified" or string.format("%d%%", (info.notice_progress or 0) * 100)))
	end

	local delay = self._detection_delay or {}

	StreamHeist:log("A camera is about to sound its alarm because of %s (its delay is %.1f to %.1f s, range %.1f m, fov %d), it was watching: %s",
		describe(detected_unit), delay[1] or 0, delay[2] or 0, (self._range or 0) / 100, self._cone_angle or 0, #watching > 0 and table.concat(watching, ", ") or "nobody")
end)


-- Bots build up notice against them slower than a player would (req/bot_stealth.lua, setting stealth_detection_mul). A guard or a
-- civilian noticing one has its own copy of the same thing in lua/coplogicbase.lua; the two keep entirely separate attention_info
-- tables and neither one calls into the other.
Hooks:PreHook(SecurityCamera, "_upd_detect_attention_objects", "sh_bot_detection_slow_pre", function(self)
	if not Network:is_server() then
		return
	end

	self._sh_notice_before = UsefulBots.stealth:before_notice(self._detected_attention_objects)
end)

Hooks:PostHook(SecurityCamera, "_upd_detect_attention_objects", "sh_bot_detection_slow_post", function(self, t)
	if not Network:is_server() then
		return
	end

	UsefulBots.stealth:after_notice(self._detected_attention_objects, self._sh_notice_before, t)

	self._sh_notice_before = nil
end)
