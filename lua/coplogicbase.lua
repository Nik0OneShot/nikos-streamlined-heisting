-- Bots build up notice against them slower than a player would (req/bot_stealth.lua, setting stealth_detection_mul). A guard or a
-- civilian noticing one goes through here; a camera has its own copy of the same thing in lua/securitycamera.lua, since the two
-- keep entirely separate attention_info tables and neither one calls into the other.
Hooks:PreHook(CopLogicBase, "_upd_attention_obj_detection", "sh_bot_detection_slow_pre", function(data)
	if not Network:is_server() then
		return
	end

	data._sh_notice_before = UsefulBots.stealth:before_notice(data.detected_attention_objects)
end)

Hooks:PostHook(CopLogicBase, "_upd_attention_obj_detection", "sh_bot_detection_slow_post", function(data)
	if not Network:is_server() then
		return
	end

	UsefulBots.stealth:after_notice(data.detected_attention_objects, data._sh_notice_before, data.t)

	data._sh_notice_before = nil
end)
