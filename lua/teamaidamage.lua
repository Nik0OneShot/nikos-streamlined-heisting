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

-- announce low health
Hooks:PostHook(TeamAIDamage, "_apply_damage", "aaaaaa i need medic bag", function(self)
	local t = TimerManager:game():time()
	if (not self._said_hurt_t or self._said_hurt_t + 10 < t) and self._health_ratio < 0.33 and not self:need_revive() and not self._unit:sound():speaking() then
		self._said_hurt_t = t
		self._unit:sound():say("g80x_plu", true, true)
	end
end)

-- makes it so team a.i can regenerate health even when they're being damaged.
Hooks:PostHook(TeamAIDamage, "update", "sh_constant_regen", function(self, unit, t, dt)
    if self._dead or self._bleed_out or self._fatal or self._health_ratio >= 1 then
        self._sh_next_regen = nil
        return
    end

    if not self._sh_next_regen then
        self._sh_next_regen = t + self._char_dmg_tweak.REGENERATE_TIME
        return
    end

    if t >= self._sh_next_regen then
        self._sh_next_regen = t + self._char_dmg_tweak.REGENERATE_TIME

        self._health = math.min(self._health + self._HEALTH_INIT * 0.1, self._HEALTH_INIT)
        self._health_ratio = self._health / self._HEALTH_INIT
    end
end)

-- useful bots code
-- fix for bots losing their i-frames in rare cases
local damage_bullet_original = TeamAIDamage.damage_bullet
function TeamAIDamage:damage_bullet(...)
	local result = damage_bullet_original(self, ...)

	if result then
		-- _chk_dmg_too_soon uses managers.player:player_timer():time() so use it here too
		self._next_allowed_dmg_t = managers.player:player_timer():time() + self._dmg_interval
	end

	return result
end
