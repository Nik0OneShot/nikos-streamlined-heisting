-- taken from useful bots

-- adjust slotmask to allow attacking turrets
Hooks:PostHook(TeamAIBrain, "_reset_logic_data", "_reset_logic_data_ub", function (self)
	self._logic_data.is_team_ai = true
	self._logic_data.secure_bag_data = {}
	if UsefulBots.settings.targeting_priority.enemies.turret > 0 then
		self._logic_data.enemy_slotmask = self._logic_data.enemy_slotmask + World:make_slot_mask(25)
	end
end)


-- Awake bots in stealth are noticed like a player with a mask on, not like an enemy in combat (req/bot_stealth.lua)
Hooks:PostHook(TeamAIBrain, "on_cool_state_changed", "on_cool_state_changed_stealth_sh", function (self, state)
	if state or not self._attention_handler or not self._unit:base()._sh_stealth_awake then
		return
	end

	if managers.groupai:state():whisper_mode() then
		PlayerMovement.set_attention_settings(self, {
			"pl_mask_on_foe_non_combatant_whisper_mode_stand",
			"pl_mask_on_foe_combatant_whisper_mode_stand"
		}, "team_AI")
	end
end)


-- Calling an awake bot in stealth sends it to where you stand, without hiding on the way (req/bot_sneak.lua)
Hooks:PostHook(TeamAIBrain, "on_long_dis_interacted", "on_long_dis_interacted_call_sh", function (self, amount, other_unit, secondary)
	if not secondary then
		UsefulBots.bag:cancel(self._unit, "called by a player")
		UsefulBots.interact:on_called(self._unit, "called by a player")
		UsefulBots.sneak:on_called(self, other_unit)
	end
end)


-- Tapping the wait key on a bot that waits releases it: it follows again without being called (req/bot_hold.lua). Vanilla leaves waiting bots
-- out of the targets of that key, lua/playerstandard.lua puts them back. This is the host side of the command, clients get here too
local on_long_dis_interacted_original = TeamAIBrain.on_long_dis_interacted
function TeamAIBrain:on_long_dis_interacted(amount, other_unit, secondary, ...)
	if secondary and UsefulBots.hold:unhold(self._unit) then
		return
	end

	return on_long_dis_interacted_original(self, amount, other_unit, secondary, ...)
end
