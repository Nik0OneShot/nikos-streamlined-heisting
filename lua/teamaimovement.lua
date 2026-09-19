-- team a.i will now be cuffed instead of incapacitated, unless on pro job.
function TeamAIMovement:on_SPOOCed(enemy_unit)
	local cooldown_id = "crew_ai_counter_strike"

	if managers.player:is_custom_cooldown_not_active("team", cooldown_id) then
		local cooldown = managers.player:crew_ability_upgrade_value(cooldown_id, tweak_data.upgrades.values.team.crew_ai_counter_strike[1][1])

		managers.player:start_custom_cooldown("team", cooldown_id, cooldown)

		local melee_weapon = self._unit:base():melee_weapon()
		local is_weapon = melee_weapon == "weapon"

		self:play_redirect(is_weapon and "melee" or "melee_item")

		return "countered"
	end

	local pro_job = Global.game_settings and Global.game_settings.one_down
	local state = pro_job and "incapacitated" or "arrested"

	state = managers.modifiers:modify_value("TeamAIMovement:OnSpooked", state)

	if state == "arrested" then
		self:on_cuffed()
	else
		self._unit:character_damage():on_incapacitated()
	end

	return true
end
