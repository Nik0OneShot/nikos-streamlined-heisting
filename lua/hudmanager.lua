-- Fix rare crash with anticipation voice
local check_anticipation_voice_original = HUDManager.check_anticipation_voice
function HUDManager:check_anticipation_voice(...)
	return self._anticipation_dialogs and check_anticipation_voice_original(self, ...)
end

-- Team a.i HUD: per-frame tick and network receiver (see req/bot_hud.lua). Thin dispatchers, only installed once.
if not StreamHeist.bot_hud then
	StreamHeist:require("bot_hud")
end

if StreamHeist.bot_hud.active and not StreamHeist.bot_hud._hud_hooked then
	StreamHeist.bot_hud._hud_hooked = true

	Hooks:PostHook(HUDManager, "update", "sh_bot_update", function()
		StreamHeist.bot_hud:update()
	end)

	Hooks:Add("NetworkReceivedData", "NetworkReceivedDataStreamHeistBotHUD", function(sender, message_type, data)
		local bot_hud = StreamHeist.bot_hud

		if not bot_hud.active then
			return
		end

		if message_type == bot_hud.NET_ID then
			-- state from the host (host is always peer 1)
			if sender == 1 and Network:is_client() then
				bot_hud:_on_network_state(data)
			end
		elseif message_type == bot_hud.HELLO_ID then
			-- a client telling the host it runs the mod
			if Network:is_server() then
				bot_hud:_on_hello(sender)
			end
		end
	end)
end
