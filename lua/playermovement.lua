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
end)

-- then make cloaker kicks cuff you instead, but if on pro job, force incapacitation state. todo: make revive health be whatever health you had before being kicked, then decreased by 25% of your max HP to a minimum of 1 hp.

Hooks(PostHook, "on_SPOOCed", "cuff_cloakers", function(self)
    if self._current_state_name == "standard" or self._current_state_name == "bleed_out" or == "carry" or self._current_state_name == "tased" or self._current_state_name == "bipod" or ~= pro_job then
      managers.player:set_player_state("arrested")
    else
      managers.player:set_player_state("incapacitated")
    end
end)
