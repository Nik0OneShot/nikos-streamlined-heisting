-- Grace period protects no matter the new potential damage but is shorter in general
function PlayerDamage:_chk_dmg_too_soon()
	local next_allowed_dmg_t = type(self._next_allowed_dmg_t) == "number" and self._next_allowed_dmg_t or Application:digest_value(self._next_allowed_dmg_t, false)
	return managers.player:player_timer():time() < next_allowed_dmg_t
end


-- Add slightly longer grace period on dodge (repurposing Anarchist/Armorer damage timer)
Hooks:PostHook(PlayerDamage, "_send_damage_drama", "sh__send_damage_drama", function (self, attack_data, health_subtracted)
	if health_subtracted == 0 and self._can_take_dmg_timer and self._can_take_dmg_timer <= 0 then
		self._can_take_dmg_timer = self._dmg_interval + 0.15
	end
end)


-- Add slightly longer grace period on armor break (repurposing Anarchist/Armorer damage timer)
local _calc_armor_damage_original = PlayerDamage._calc_armor_damage
function PlayerDamage:_calc_armor_damage(...)
	local had_armor = self:get_real_armor() > 0

	local health_subtracted = _calc_armor_damage_original(self, ...)

	if health_subtracted > 0 and had_armor and self:get_real_armor() <= 0 and self._can_take_dmg_timer <= 0 then
		self._can_take_dmg_timer = self._dmg_interval + 0.15
	end

	return health_subtracted
end


-- Fix Anarchist regen not triggering HUD armor update for clients
Hooks:PostHook(PlayerDamage, "change_armor", "sh_change_armor", function (self, change)
	if change > 0 and self:armor_ratio() < 1 then
		self:_send_set_armor()
	end
end)

-- taken from eclipse to prevent a crash
Hooks:PreHook(PlayerDamage, "replenish", "eclipse_replenish", function(self)
	if Global.game_settings and Global.game_settings.one_down then
		self._lives_init = 4
	end
end)

-- add these from super serious shooter

Hooks:PreHook(PlayerDamage, "on_arrested", "on_incapacitated_sss", function(self) -- to try to fix a bug where being cuffed...will send you to custody as if you were normally incapacitated.
	if self._bleed_out then
		return
	end

	self._pre_incap_health_ratio = self:health_ratio()
	self._pre_incap_revive_health_i = self._revive_health_i
end)

Hooks:PreHook(PlayerDamage, "on_incapacitated", "on_incapacitated_sss", function(self)
	if self._bleed_out then
		return
	end

	self._pre_incap_health_ratio = self:health_ratio()
	self._pre_incap_revive_health_i = self._revive_health_i
end)

Hooks:PostHook(PlayerDamage, "revive", "revive_sss", function(self)
	if not self._pre_incap_health_ratio then
		return
	end

	self:set_health(self:_max_health() * self._pre_incap_health_ratio)
	self._revive_health_i = self._pre_incap_revive_health_i or self._revive_health_i

	self._pre_incap_health_ratio = nil
	self._pre_incap_revive_health_i = nil
end)

function PlayerDamage:damage_health(attack_data)
	local damage_info = {
		result = {
			type = "hurt",
			variant = attack_data.variant
		}
	}

	if self._god_mode or self._invulnerable or self._mission_damage_blockers.invulnerable then
		self:_call_listeners(damage_info)
		return
	elseif self:incapacitated() then
		return
	elseif self._unit:movement():current_state().immortal then
		return
	end

	if attack_data.is_percentage then
		attack_data.damage = attack_data.damage * self:_max_health()
	end
	attack_data.damage = managers.player:modify_value("damage_taken", attack_data.damage, attack_data)

	if self._bleed_out then
		self:_bleed_out_damage(attack_data)
		return
	end

	self:mutator_update_attack_data(attack_data)
	self:_check_chico_heal(attack_data)

	self:_calc_health_damage(attack_data)
	self:_call_listeners(damage_info)
end


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
-- everything below only runs on the host, keep it at the end of this file
if not Network:is_server() then
	return
end

-- Stop bots revive objective if someone else starts reviving
Hooks:PostHook(PlayerDamage, "pause_downed_timer", "pause_downed_timer_ub", function(self, timer, peer_id)
	if not peer_id then
		return
	end

	local reviving_bot = UsefulBots:get_reviving_unit(self._unit)
	if not reviving_bot then
		return
	end

	local internal_data = reviving_bot:brain()._logic_data.internal_data
	local revive_complete_clbk_id = internal_data and internal_data.revive_complete_clbk_id
	local revive_complete_t = revive_complete_clbk_id and managers.enemy:get_delayed_clbk_exec_t(revive_complete_clbk_id)
	if revive_complete_t and revive_complete_t - TimerManager:game():time() < 2 then
		return
	end

	reviving_bot:brain():set_objective(nil)
	reviving_bot:movement():action_request({
		body_part = 4,
		type = "stand"
	})

	if UsefulBots.settings.defend_reviving then
		reviving_bot:brain():set_objective(UsefulBots:get_assist_objective(self._unit, reviving_bot))
	else
		reviving_bot:brain():set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(reviving_bot))
	end
end)
