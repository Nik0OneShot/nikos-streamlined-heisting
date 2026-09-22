-- Reduce damage taken while inside of vehicles
local damage_reduction_skill_multiplier_original = PlayerManager.damage_reduction_skill_multiplier
function PlayerManager:damage_reduction_skill_multiplier(...)
	local dmg_reduction = damage_reduction_skill_multiplier_original(self, ...)

	local player = self:player_unit()
	if player and player:movement()._current_state_name == "driving" then
		dmg_reduction = dmg_reduction * 0.01 -- 0.5 > 0.2, the car incident of 2024. | im actually considering setting this to 0.01, to basically remove any damage when in cars, but reduce car health to acceptable levels, forcing you to leave the car to repair it... that'd be interesting.
											 -- done, although you'll have to use my complements mod to make it properly work.
	end

	return dmg_reduction
end


-- Make cooldown for picking up bags consistent instead of random
local drop_carry_original = PlayerManager.drop_carry
function PlayerManager:drop_carry(...)
	local carry_data = self:get_my_carry_data()

	drop_carry_original(self, ...)

	if carry_data then
		self._carry_blocked_cooldown_t = Application:time() + 0.5
	end
end


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
-- everything below only runs on the host, keep it at the end of this file
if not Network:is_server() then
	return
end

Hooks:PostHook(PlayerManager, "sync_carry_data", "sync_carry_data_ub", function (self, unit, carry_id, carry_multiplier, dye_initiated, has_dye_pack, dye_value_multiplier, position, dir, throw_distance_multiplier_upgrade_level, zipline_unit, peer_id)
	if Monkeepers then
		return
	end

	local peer = managers.network:session():peer(peer_id)
	local peer_unit = peer and peer:unit()
	if not alive(peer_unit) then
		return
	end

	local throw_distance_multiplier = self:upgrade_value_by_level("carry", "throw_distance_multiplier", throw_distance_multiplier_upgrade_level, 1)
	throw_distance_multiplier = throw_distance_multiplier * tweak_data.carry.types[tweak_data.carry[carry_id].type].throw_distance_multiplier

	if managers.mutators:is_mutator_active(MutatorPiggyRevenge) then
		local mutator = managers.mutators:get_mutator(MutatorPiggyRevenge)
		if mutator.get_bag_throw_multiplier then
			throw_distance_multiplier = throw_distance_multiplier * mutator:get_bag_throw_multiplier(carry_id)
		end
	end

	unit:carry_data()._ub_throw_params = {
		expire_t = TimerManager:game():time() + (zipline_unit and 30 or 3),
		bag_pos = unit:position(),
		pos = mvector3.copy(peer_unit:movement():m_newest_pos()),
		dir = dir * 600 * throw_distance_multiplier,
		zipline_unit = zipline_unit
	}
end)
