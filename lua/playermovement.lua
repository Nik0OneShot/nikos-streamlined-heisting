-- port code from super serious shooter that makes cloaker kicks damage you for 25% of your max hp!

local pro_job = Global.game_settings.one_down

Hooks:PreHook(PlayerMovement, "on_SPOOCed", "on_SPOOCed_sss", function(self)
	if not self._unit:character_damage().damage_health then
		return
	end

	self._unit:character_damage():damage_health({
		damage = 0.25,
		is_percentage = true
	})

	if pro_job then
		managers.player:set_player_state("incapacitated")
	else
		managers.player:set_player_state("arrested")
	end
end)

-- then make cloaker kicks cuff you instead, but if on pro job, force incapacitation state. todo: make revive health be whatever health you had before being kicked, then decreased by 25% of your max HP to a minimum of 1 hp.

-- just testing something, seeing if a prehook will work instead.
--[[Hooks:PostHook(PlayerMovement, "on_SPOOCed", "cuff_cloakers", function(self)
	if pro_job then
		managers.player:set_player_state("incapacitated")
	else
		managers.player:set_player_state("arrested")
	end
end)
--]]
