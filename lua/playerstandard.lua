-- remember when i deleted this thinking it dindu nuffin?

local level_id = Global.level_data and Global.level_data.level_id or ""

function PlayerStandard:_get_detection_status()
	local level_data = tweak_data.levels[level_id]
	
	if  level_data.is_map_hostile then
		return "hostile"
	end
	
	return "none"
end

Hooks:PostHook(PlayerStandard, "_start_action_interact", "_on_interact", function(self)
	if not self._is_suspicious then
		self._is_suspicious = true
	end
end)

Hooks:PostHook(PlayerStandard, "_interupt_action_interact", "_on_interact_interrupt", function(self)
	if self._is_suspicious then
		self._is_suspicious = nil
	end
end)

Hooks:PostHook(PlayerStandard, "_end_action_interact", "_on_interact_ended", function(self)
	if self._is_suspicious then
		self._is_suspicious = nil
	end
end)

-- not anymore
