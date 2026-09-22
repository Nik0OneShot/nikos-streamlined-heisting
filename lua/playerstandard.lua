-- Wait command: tapping the wait key works as before (Useful Bots + hold mode setting), holding it makes the bot
-- you are looking at stay exactly where it is, even if it was already waiting and patrolling or using cover.
-- In stealth holding the wait key sends an awake bot back to sleep instead (see req/bot_stealth.lua).
--
-- The vanilla HoldButtonMetaInput takes over the press event of the key: while the key is held nothing is reported,
-- a tap is reported when the key is released (so the command is a moment late) and a hold is reported once as
-- btn_sh_wait_hold_press after the hold time.
--
-- Stealth: vanilla does not let you command bots in stealth. Bots that are awake are added to the targets so tapping
-- follow/wait works on them, and holding the follow key on a sleeping bot wakes it.

if Keepers then
	return
end

Hooks:PostHook(PlayerStandard, "init", "sh_init_wait_hold", function(self)
	self._input = self._input or {}
	table.insert(self._input, HoldButtonMetaInput:new("sh_wait_hold", "interact_secondary", nil, UsefulBots.settings.wait_hold_time))
end)

Hooks:PostHook(PlayerStandard, "_check_action_interact", "sh_check_action_wait_hold", function(self, t, input)
	if input.btn_sh_wait_hold_press and not self:_action_interact_forbidden() then
		self:sh_wait_hold(t)
	end

	self:sh_check_wake_hold(t, input)
end)


-- Targets

local _get_unit_intimidation_action_original = PlayerStandard._get_unit_intimidation_action
function PlayerStandard:_get_unit_intimidation_action(intimidate_enemies, intimidate_civilians, intimidate_teammates, ...)
	self._sh_teammates = intimidate_teammates

	return _get_unit_intimidation_action_original(self, intimidate_enemies, intimidate_civilians, intimidate_teammates, ...)
end

-- Vanilla only adds bots to the targets outside of stealth, add the awake ones in stealth
local _get_interaction_target_original = PlayerStandard._get_interaction_target
function PlayerStandard:_get_interaction_target(char_table, my_head_pos, cam_fwd, secondary, ...)
	if self._sh_teammates and UsefulBots.stealth:enabled() and managers.groupai:state():whisper_mode() then
		local range = tweak_data.player.long_dis_interaction.intimidate_range_teammates

		for u_key, u_data in pairs(managers.groupai:state():all_char_criminals()) do
			local unit = u_data.unit

			if u_key ~= self._unit:key() and u_data.ai and alive(unit) then
				local movement = unit:movement()

				-- same rules as vanilla, waiting bots can not be told to wait again
				if not movement:cool() and (not secondary or not movement:should_stay()) and not movement:downed() and not unit:anim_data().long_dis_interact_disabled then
					self:_add_unit_to_char_table(char_table, unit, 2, range, true, not secondary, 0.01, my_head_pos, cam_fwd)
				end
			end
		end
	end

	-- Vanilla leaves the bots that wait out of the targets of the wait key: a tap on one releases it (req/bot_hold.lua)
	if self._sh_teammates and secondary and UsefulBots.settings.wait_release ~= false then
		local range = tweak_data.player.long_dis_interaction.intimidate_range_teammates

		for u_key, u_data in pairs(managers.groupai:state():all_char_criminals()) do
			local unit = u_data.unit

			if u_key ~= self._unit:key() and u_data.ai and alive(unit) then
				local movement = unit:movement()

				-- awake bots only: a bot that sleeps in stealth is woken by holding the follow key
				if movement:should_stay() and not movement:cool() and not movement:downed() and not unit:anim_data().long_dis_interact_disabled then
					self:_add_unit_to_char_table(char_table, unit, 2, range, true, false, 0.01, my_head_pos, cam_fwd)
				end
			end
		end
	end

	return _get_interaction_target_original(self, char_table, my_head_pos, cam_fwd, secondary, ...)
end

-- The bot the player is looking at. Vanilla leaves out bots that already wait when looking for a target for the wait
-- command, this does not. want_awake: nil = any bot, true = only awake bots, false = only sleeping bots
function PlayerStandard:sh_get_bot_target(want_awake)
	local char_table = {}
	local cam_fwd = self._ext_camera:forward()
	local my_head_pos = self._ext_movement:m_head_pos()
	local range = tweak_data.player.long_dis_interaction.intimidate_range_teammates

	for u_key, u_data in pairs(managers.groupai:state():all_char_criminals()) do
		local unit = u_data.unit

		if u_key ~= self._unit:key() and u_data.ai and alive(unit) and not unit:movement():downed() and not unit:anim_data().long_dis_interact_disabled then
			local awake = not unit:movement():cool()

			if want_awake == nil or want_awake == awake then
				self:_add_unit_to_char_table(char_table, unit, 2, range, true, false, 0.01, my_head_pos, cam_fwd)
			end
		end
	end

	-- the targets are chosen here, do not add the stealth ones on top
	self._sh_teammates = false

	return self:_get_interaction_target(char_table, my_head_pos, cam_fwd, true)
end


-- Holding the wait key

function PlayerStandard:sh_wait_hold(t)
	local whisper = managers.groupai:state():whisper_mode()
	if whisper and not UsefulBots.stealth:enabled() then
		return
	end

	local prime_target = self:sh_get_bot_target(whisper and true or nil)
	local unit = prime_target and prime_target.unit
	if not alive(unit) then
		return
	end

	local damage_ext = unit:character_damage()
	if damage_ext:need_revive() or damage_ext:arrested() then
		return
	end

	-- play the wait gesture and voice line again, as for a normal wait command
	self:_do_action_intimidate(t, "cmd_stop", "f48x_any", whisper)

	if whisper then
		UsefulBots.stealth:request(unit, "sleep")
	else
		UsefulBots.hold:request_stationary(unit)
	end
end


-- Holding the follow key in stealth

function PlayerStandard:sh_check_wake_hold(t, input)
	if input.btn_interact_press then
		self._sh_wake_done = nil
	end

	-- _start_intimidate is set by vanilla while the key is down and nothing else is being interacted with
	if not self._start_intimidate or self._sh_wake_done or not input.btn_interact_state then
		return
	end

	if not self._start_intimidate_t or t < self._start_intimidate_t + UsefulBots.settings.stealth_hold_time then
		return
	end

	if not UsefulBots.stealth:enabled() or not managers.groupai:state():whisper_mode() or self:_action_interact_forbidden() then
		return
	end

	local prime_target = self:sh_get_bot_target(true)
	local bag_unit = prime_target and prime_target.unit
	local bag_command = alive(bag_unit) and alive(bag_unit:movement()._carry_unit)
	if alive(bag_unit) and not bag_command then
		return
	elseif not bag_command then
		prime_target = self:sh_get_bot_target(false)
	end
	local unit = prime_target and prime_target.unit
	if not alive(unit) then
		return
	end

	-- do not let the release of the key count as a normal follow command
	self._sh_wake_done = true
	self._start_intimidate = false

	local static_data = managers.criminals:character_static_data_by_unit(unit)
	self:_do_action_intimidate(t, "cmd_come", static_data and "f21" .. static_data.ssuffix .. "_sin" or "f38_any", true)

	UsefulBots.stealth:request(unit, bag_command and "stash" or "wake")
end


-- The pointer: holding the melee key on a bot brings up a line, tapping the key sends the bot to what the line points at
-- (req/bot_interact.lua). Before the melee input is handled, so that the melee key can be taken from the melee while the pointer is up
Hooks:PreHook(PlayerStandard, "_check_action_melee", "sh_pointer_input", function(self, t, input)
	UsefulBots.interact:pointer_input(self, t, input)
end)

Hooks:PostHook(PlayerStandard, "_update_check_actions", "sh_pointer_update", function(self, t)
	UsefulBots.interact:pointer_update(self, t)
end)
