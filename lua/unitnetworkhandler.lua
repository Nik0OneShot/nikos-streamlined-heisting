-- Team a.i HUD (see req/bot_hud.lua)
if not StreamHeist.bot_hud then
	StreamHeist:require("bot_hud")
end

-- Properly sync reload
function UnitNetworkHandler:reload_weapon_cop(cop, sender)
	if not self._verify_gamestate(self._gamestate_filter.any_ingame) or not self._verify_character_and_sender(cop, sender) then
		return
	end

	if not alive(cop) then
		return
	end

	local current_action = cop:movement():get_action(3)
	if current_action and current_action:type() == "shoot" then
		-- If we are currently in shoot action, set the mag to empty
		cop:inventory():equipped_unit():base():ammo_base():set_ammo_remaining_in_clip(0)
	else
		-- Otherwise request an actual reload action
		cop:movement():action_request({
			body_part = 3,
			type = "reload"
		})
	end

	-- Team a.i HUD: the host's mag is empty now, correct the client-side count
	local bot_hud = StreamHeist.bot_hud

	if bot_hud and bot_hud.active then
		bot_hud:on_reload_start(cop)
	end
end
