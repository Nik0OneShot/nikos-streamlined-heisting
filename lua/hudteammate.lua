-- claude code

if not StreamHeist.bot_hud then
	StreamHeist:require("bot_hud")
end

-- a listed HUD mod that already shows bot health is enabled (or this was switched off earlier): nothing to do here
if not StreamHeist.bot_hud.active then
	return
end

-- Team a.i HUD: show the full teammate panel (health + armor radials, ammo number) for bots.
-- Vanilla sets the whole "player" sub-panel (radials, weapons, equipment) to alpha 0 when the state is "ai",
-- so this only un-hides it and re-hides the parts bots have no use for. The data comes from StreamHeist.bot_hud (req/bot_hud.lua).
--
-- The layout is applied from the set_state hook below AND from a sweep in StreamHeist.bot_hud:update(), because some HUD mods
-- (Restoration HUD) redefine HUDTeammate:set_state outright, which can drop a hook depending on load order.

-- remember what an element looked like before we touched it, so a human who takes the panel later gets it back exactly
function HUDTeammate:_sh_bot_set_visible(id, element, visible)
	if not element or not alive(element) then
		return
	end

	self._sh_bot_saved = self._sh_bot_saved or {}

	if self._sh_bot_saved[id] == nil then
		self._sh_bot_saved[id] = { element = element, visible = element:visible() }
	end

	element:set_visible(visible)
end

-- callable on any panel table (the sweep uses HUDTeammate._sh_bot_apply_layout(panel))
function HUDTeammate:_sh_bot_apply_layout()
	self._sh_bot_panel = true

	-- vanilla's "player" branch un-hides the sub-panel (and moves the name back to the player layout)
	self._sh_bot_setting_state = true
	HUDTeammate.set_state(self, "player")
	self._sh_bot_setting_state = nil

	-- no meaning for bots: revive counter, deployables, cable ties, grenades
	self:_sh_bot_set_visible("revive_panel", self._player_panel:child("revive_panel"), false)

	for _, key in ipairs({ "_deployable_equipment_panel", "_cable_ties_panel", "_grenades_panel" }) do
		self:_sh_bot_set_visible(key, self[key], false)
	end

	-- the callsign circle in the name's colour: vanilla hides it for everyone, Restoration HUD shows it for everyone
	self:_sh_bot_set_visible("callsign_bg", self._panel:child("callsign_bg"), true)
	self:_sh_bot_set_visible("callsign", self._panel:child("callsign"), true)

	-- vanilla's teammate ammo tab only shows the "total" number, the mag count is fed into that. HUDs that also show the
	-- clip field for teammates (Restoration HUD) get the mag in the clip field, and the total (reserve) is hidden
	local weapons_panel = self._player_panel:child("weapons_panel")
	local primary = weapons_panel and weapons_panel:child("primary_weapon_panel")
	local clip_field = primary and primary:child("ammo_clip")

	if clip_field and alive(clip_field) and clip_field:visible() then
		self:_sh_bot_set_visible("ammo_total", primary:child("ammo_total"), false)
	end
end

function HUDTeammate:_sh_bot_restore_layout()
	self._sh_bot_panel = nil

	for _, data in pairs(self._sh_bot_saved or {}) do
		if alive(data.element) then
			data.element:set_visible(data.visible)
		end
	end

	self._sh_bot_saved = nil
end

-- the functions above are reloadable, the hooks are only installed once so hot-reloading doesn't stack them
if not HUDTeammate._sh_bot_hooked then
	HUDTeammate._sh_bot_hooked = true

	Hooks:PostHook(HUDTeammate, "set_state", "sh_bot_set_state", function(self, state)
		-- the local player's panel is untouched, and ignore the re-entrant call made by the layout function
		if not StreamHeist.bot_hud.active or self._main_player or self._sh_bot_setting_state or not self._player_panel then
			return
		end

		if state == "ai" then
			-- another HUD mod may have rebuilt the panel, then leave it alone and switch off
			local vanilla_layout, missing = StreamHeist.bot_hud:check_panel(self)

			if not vanilla_layout then
				StreamHeist.bot_hud:deactivate("the teammate panel doesn't look like vanilla's (missing " .. tostring(missing) .. ")" .. StreamHeist.bot_hud:hud_hint())

				return
			end

			self:_sh_bot_apply_layout()

			StreamHeist.bot_hud:log_once("panel_ai_" .. tostring(self._id), "teammate panel %s switched to the full layout (ai)", tostring(self._id))
		elseif self._sh_bot_panel then
			-- panel is being reused for a human, give back what we changed (vanilla's set_state already reset the name position)
			self:_sh_bot_restore_layout()
		end
	end)

	-- don't leave the regen indicator behind when a bot's panel is removed
	Hooks:PostHook(HUDTeammate, "remove_panel", "sh_bot_remove_panel", function(self)
		if StreamHeist.bot_hud.active and self._sh_bot_panel and self._radial_health_panel then
			self:set_armor({ current = 0, total = 1, max = 1 })
		end
	end)
end
