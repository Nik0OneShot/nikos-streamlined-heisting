if not StreamHeist.bot_hud then
	StreamHeist:require("bot_hud")
end

-- a listed HUD mod that already shows bot health is enabled (or this was switched off earlier): nothing to do here
if not StreamHeist.bot_hud.active then
	return
end

-- Vanilla returns the team a.i colour for every bot here, which is what the in-world name label (and its bag icon and
-- "fixing" text) uses when it is created. Hand out the player colour StreamHeist.bot_hud (req/bot_hud.lua) assigned instead.
-- The original is stored once so a hot-reload doesn't wrap it again.
CriminalsManager._sh_bot_color_id_original = CriminalsManager._sh_bot_color_id_original or CriminalsManager.character_color_id_by_unit

function CriminalsManager:character_color_id_by_unit(unit)
	local color_id = CriminalsManager._sh_bot_color_id_original(self, unit)

	-- vanilla returns the last chat colour for bots, humans return their peer id
	if color_id and StreamHeist.bot_hud.active and color_id == #tweak_data.chat_colors and StreamHeist.bot_hud:is_bot(unit) then
		return StreamHeist.bot_hud:color_id_for_unit(unit) or color_id
	end

	return color_id
end
