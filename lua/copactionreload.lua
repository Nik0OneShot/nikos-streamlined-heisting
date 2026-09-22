-- Reload in cover (see req/bot_reload.lua): every reload of the enemies and team ai goes through here,
-- the shoot action calls this function directly with itself as "self" when the magazine is empty.
-- Only bots in a fight are affected, everything else reloads as usual.
local _play_reload_original = CopActionReload._play_reload
function CopActionReload:_play_reload(...)
	if UsefulBots.reload:chk_delay(self._unit) then
		return
	end

	return _play_reload_original(self, ...)
end
