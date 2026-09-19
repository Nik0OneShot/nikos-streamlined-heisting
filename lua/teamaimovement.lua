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

if not Network:is_server() then
	return
end

-- useful bots code

-- queued actions are not initialized for some reason
Hooks:PostHook(TeamAIMovement, "init", "init_ub", function (self)
	self._queued_actions = {}
end)

Hooks:PostHook(TeamAIMovement, "set_allow_fire", "set_allow_fire_ub", function (self, state)
	if state then
		self._switch_upper_body_to_idle_t = nil
	end
end)

if Keepers then
	return
end

TeamAIMovement.chk_action_forbidden = CopMovement.chk_action_forbidden

Hooks:PostHook(TeamAIMovement, "set_should_stay", "set_should_stay_ub", function (self, should_stay, pos)
	if should_stay and pos then
		self._should_stay_pos = mvector3.copy(pos)
	end
	local objective = self._ext_brain:objective()
	if not objective or not objective.forced then
		self._ext_brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(self._unit))
	end
end)
