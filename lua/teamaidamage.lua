-- Add missing friendly fire check
TeamAIDamage.is_friendly_fire = PlayerDamage.is_friendly_fire

-- port super serious shooter code to make team a.i regenerate health in "pulses" instead of a full heal.
Hooks:OverrideFunction(TeamAIDamage, "_regenerated", function (self)
	if self._bleed_out or self._fatal then
		self._health = self._HEALTH_INIT
		self._health_ratio = 1

		self._bleed_out = nil
		self._bleed_death_t = nil
		self._bleed_out_health = nil
		self._fatal = nil

		self._regenerate_t = nil
	else
		self._health = math.min(self._health + self._HEALTH_INIT * 0.1, self._HEALTH_INIT)
		self._health_ratio = self._health / self._HEALTH_INIT

		if self._health_ratio < 1 then
			self._regenerate_t = TimerManager:game():time() + self._char_dmg_tweak.REGENERATE_TIME
		end
	end

	self._bleed_out_paused_count = 0
	self._to_dead_t = nil
	self._to_dead_remaining_t = nil

	self:_clear_damage_transition_callbacks()
end)
