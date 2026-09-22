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

-- Bags do not slow Team AI while the heist is in stealth. Calculate this at
-- movement time so the normal penalty returns immediately when whisper mode ends.
function TeamAIMovement:speed_modifier()
	local modifier = CopMovement.speed_modifier(self)
	local group_ai = managers.groupai and managers.groupai:state()

	if self._carry_speed_modifier and group_ai and group_ai:whisper_mode() then
		modifier = (modifier or 1) / self._carry_speed_modifier
	end

	return modifier ~= 1 and modifier or nil
end

-- Cancel a manual stealth delivery immediately when this bot loses the ordered
-- bag. CarryData calls this method when a player or another unit takes the bag.
local set_carrying_bag_original = TeamAIMovement.set_carrying_bag
function TeamAIMovement:set_carrying_bag(unit, ...)
	local order = self._sh_bag_order
	local result = set_carrying_bag_original(self, unit, ...)

	if order and not order.finishing and unit ~= order.carry_unit then
		UsefulBots.bag:cancel(self._unit, "bag was taken")
	end

	return result
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

-- forget the hold mode when the bot is told to follow again
Hooks:PostHook(TeamAIMovement, "set_should_stay", "set_should_stay_hold_sh", function (self, should_stay)
	if not should_stay then
		UsefulBots.hold:reset(self)
		UsefulBots.sneak:release(self._unit)
		UsefulBots.interact:on_released(self._unit)
	end
end)

-- awake bots in stealth do not fire unless the heist is going loud anyway (req/bot_stealth.lua)
local set_allow_fire_original = TeamAIMovement.set_allow_fire
function TeamAIMovement:set_allow_fire(state, ...)
	if state and UsefulBots.stealth:holds_fire(self._unit) then
		state = false
	end

	return set_allow_fire_original(self, state, ...)
end

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


-- Awake bots in stealth that have to wait until nobody can see them do not walk (req/bot_sneak.lua)
local chk_action_forbidden_sneak_original = TeamAIMovement.chk_action_forbidden
function TeamAIMovement:chk_action_forbidden(action_type, ...)
	if action_type == "walk" and self._sh_hold_still then
		return true
	end

	return chk_action_forbidden_sneak_original(self, action_type, ...)
end
