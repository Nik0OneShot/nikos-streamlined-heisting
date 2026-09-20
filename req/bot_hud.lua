-- claude code

-- Team a.i HUD core: shared logic, loaded once by the hook scripts that use it (StreamHeist:require("bot_hud")).
-- Hook scripts: hudteammate, hudmanager, criminalsmanager, newnpcraycastweaponbase, unitnetworkhandler.
-- ---------------------------------------------------------------------------------------------------------------
-- Team a.i HUD: health radial, armor radial as a regen timer, and a magazine count on the bot's teammate panel.
--
-- Host:   reads the real state (TeamAIDamage health/regen timers, the weapon's real clip) every frame, updates its
--         own HUD and sends health + regen timing (only on change + a heartbeat) through LuaNetworking, but only to
--         peers that said hello, i.e. that run this mod. Everyone else is left alone.
-- Client: says hello to the host, renders from the host's messages and counts bot shots locally (see
--         newnpcraycastweaponbase.lua), correcting the count on every reload. Without the mod on the host there is no
--         health/regen data, so bots keep vanilla's full ring; ammo and colours don't need the host.
-- ---------------------------------------------------------------------------------------------------------------
StreamHeist.bot_hud = StreamHeist.bot_hud or {}

local BotHUD = StreamHeist.bot_hud

-- use the mod's logger, logging is on when mods/developer.txt exists
BotHUD.logging = StreamHeist.logging

function BotHUD:log(str, ...)
	StreamHeist:log("[BotHUD] " .. str, ...)
end

function BotHUD:warn(str, ...)
	StreamHeist:warn("[BotHUD] " .. str, ...)
end

function BotHUD:error(str, ...)
	StreamHeist:error("[BotHUD] " .. str, ...)
end

-- ---------------------------------------------------------------------------------------------------------------
-- HUD mod compatibility (see compat.lua)
-- ---------------------------------------------------------------------------------------------------------------
BotHUD.active = true
BotHUD.GLOBAL_CHECK_INTERVAL = 5

local ok, rules = pcall(StreamHeist.require, StreamHeist, "bot_hud_compat")
BotHUD.compat_rules = ok and type(rules) == "table" and rules.disable and rules or { disable = {} }

if not (ok and type(rules) == "table") then
	BotHUD:warn("couldn't load req/bot_hud_compat.lua: %s", tostring(rules))
end

-- stop everything: hooks that are already installed check `active`, scripts that load later return right away
function BotHUD:deactivate(reason)
	if self.active then
		self.active = false
		self.inactive_reason = reason

		self:warn("switched off: %s", reason)
	end
end

-- returns the label of a listed HUD mod that is enabled, and what gave it away
function BotHUD:_find_listed_hud()
	local hud_like = {}

	if BLT and BLT.Mods then
		for _, mod in pairs(BLT.Mods:Mods()) do
			if mod:IsEnabled() then
				local name = tostring(mod:GetName())
				local id = tostring(mod.GetId and mod:GetId() or "")
				local text = (name .. " | " .. id):lower()

				if name:find("HUD") or name:find("UI") or text:find("hud", 1, true) then
					hud_like[#hud_like + 1] = name
				end

				for _, rule in ipairs(self.compat_rules.disable) do
					local matches = false

					if rule.exact then
						-- exact BLT name or id (for short names like "MUI" that would match half the mod list as a substring)
						for _, exact in ipairs(rule.exact) do
							matches = matches or name == exact or id == exact
						end
					elseif rule.all and #rule.all > 0 then
						matches = true

						for _, part in ipairs(rule.all) do
							if not text:find(part, 1, true) then
								matches = false

								break
							end
						end
					end

					if matches then
						return rule, "the enabled mod '" .. name .. "'"
					end
				end
			end
		end
	end

	for _, rule in ipairs(self.compat_rules.disable) do
		for _, global_name in ipairs(rule.globals or {}) do
			if rawget(_G, global_name) ~= nil then
				return rule, "the global '" .. global_name .. "'"
			end
		end
	end

	self:log("enabled mods that look like HUD/UI mods (add a rule to compat.lua if one of them already shows bot health): %s", #hud_like > 0 and table.concat(hud_like, ", ") or "none")
end

-- the global check again while playing, for HUD mods that define their globals late
function BotHUD:_recheck_globals(now)
	if self._globals_t and now - self._globals_t < self.GLOBAL_CHECK_INTERVAL then
		return
	end

	self._globals_t = now

	for _, rule in ipairs(self.compat_rules.disable) do
		for _, global_name in ipairs(rule.globals or {}) do
			if rawget(_G, global_name) ~= nil then
				self:deactivate(rule.label .. " is running (global '" .. global_name .. "'), " .. (rule.why or "it is not supported"))

				return
			end
		end
	end
end

-- says which known HUD is probably behind panels that aren't vanilla's
function BotHUD:hud_hint()
	if HUDManager and HUDManager.CUSTOM_TEAMMATE_PANELS then
		return ", VanillaHUD Plus' Custom HUD (HUDTYPE 3) builds its own panels"
	elseif rawget(_G, "MUITeammate") then
		return ", MUI builds its own panels (MUITeammate)"
	elseif rawget(_G, "HUDTeammateCustom") then
		return ", a custom HUD builds its own panels (HUDTeammateCustom)"
	end

	return ", another HUD mod probably replaced them"
end

-- does a teammate panel have the parts this mod changes? Other HUD mods rebuild HUDTeammate with a different layout
function BotHUD:check_panel(panel)
	local function child_of(parent, name)
		if parent and alive(parent) then
			return parent:child(name)
		end
	end

	local player_panel = panel._player_panel
	local radial = panel._radial_health_panel
	local weapons = child_of(player_panel, "weapons_panel")
	local primary = child_of(weapons, "primary_weapon_panel")
	local missing

	local function need(value, what)
		if not value and not missing then
			missing = what
		end
	end

	need(player_panel and alive(player_panel), "_player_panel")
	need(child_of(radial, "radial_health"), "radial_health")
	need(child_of(radial, "radial_shield"), "radial_shield")
	need(child_of(primary, "ammo_total"), "primary_weapon_panel/ammo_total")
	need(child_of(panel._panel, "name") and child_of(panel._panel, "callsign"), "name/callsign")
	need(panel.set_health and panel.set_armor and panel.set_callsign, "set_health/set_armor/set_callsign")

	return not missing, missing
end

local listed_rule, listed_source = BotHUD:_find_listed_hud()

if listed_rule then
	BotHUD.active = false
	BotHUD.disabled_by_compat = true
	BotHUD.inactive_reason = listed_rule.label .. ": " .. (listed_rule.why or "not supported")

	-- always logged: this only switches off the bot HUD, everything else in Streamlined Heisting loads as usual
	log("[StreamlinedHeisting][BotHUD] not loading the team a.i HUD: " .. listed_rule.label .. " is enabled (" .. listed_source .. "), " .. (listed_rule.why or "it is not supported"))

	return
end

BotHUD.NET_ID = "sh_bot_state"
BotHUD.HELLO_ID = "sh_bot_hello"
BotHUD.HELLO_INTERVAL = 10 -- clients repeat their hello this often
BotHUD.PEER_TIMEOUT = 25 -- host forgets a peer that stopped saying hello (left, or another player took the slot)
BotHUD.NO_HOST_DATA_WARNING = 12
BotHUD.mod_peers = BotHUD.mod_peers or {}
BotHUD.HEARTBEAT = 5 -- host resends every bot's state this often (covers late joins and dropped messages)
BotHUD.RESYNC = 1 -- everything is re-pushed to the HUD this often (vanilla resets bot radials when a mugshot is re-added)
BotHUD.DEFAULT_INTERVAL = 2
BotHUD.ARMOR_EPSILON = 0.02
BotHUD.PRIMARY_SELECTION = 2 -- HUDManager:set_teammate_ammo_amount maps selection index 2 to the primary panel
BotHUD.states = BotHUD.states or {}
BotHUD._logged = BotHUD._logged or {}

function BotHUD:log_once(key, ...)
	if self.logging and not self._logged[key] then
		self._logged[key] = true
		self:log(...)
	end
end

function BotHUD:is_bot(unit)
	if not self.active then
		return false
	end

	local groupai = managers.groupai and managers.groupai:state()
	return alive(unit) and groupai and groupai:is_unit_team_AI(unit) or false
end

function BotHUD:_panel_id(name)
	local data = managers.criminals and managers.criminals:character_data_by_name(name)
	local panel_id = data and data.panel_id
	local panels = managers.hud and managers.hud._teammate_panels

	if panel_id and panels and panels[panel_id] then
		return panel_id
	end
end

function BotHUD:_weapon_base(unit)
	local inventory = alive(unit) and unit:inventory()
	local weapon = inventory and inventory.equipped_unit and inventory:equipped_unit()
	local base = alive(weapon) and weapon:base()

	return base and base.ammo_base and base or nil
end

-- host: the real clip. client: our own counter (clients never consume the real clip of a bot weapon)
function BotHUD:_read_clip(base)
	local ammo_base = base:ammo_base()
	local max_clip = ammo_base and ammo_base:get_ammo_max_per_clip()

	if not max_clip or max_clip <= 0 then
		return
	end

	if Network:is_server() then
		return ammo_base:get_ammo_remaining_in_clip() or max_clip, max_clip
	end

	return base._sh_bot_clip or max_clip, max_clip
end

-- client only: called from the NPC weapon's fire wrapper
function BotHUD:on_client_bot_fire(base)
	if not self.active then
		return
	end

	local unit = base._setup and base._setup.user_unit
	if not self:is_bot(unit) then
		return
	end

	local ammo_base = base:ammo_base()
	local max_clip = ammo_base and ammo_base:get_ammo_max_per_clip()
	if not max_clip or max_clip <= 0 then
		return
	end

	local clip = base._sh_bot_clip or max_clip
	if clip <= 0 then
		-- a bot can't shoot with an empty mag, so a reload finished without us seeing it
		clip = max_clip
	end

	base._sh_bot_clip = math.max(clip - (base.ammo_usage and base:ammo_usage() or 1), 0)

	self:log_once("client_fire", "client counted a bot shot (%d/%d)", base._sh_bot_clip, max_clip)
end

-- client only: the reload animation finished (NewNPCRaycastWeaponBase:on_reload)
function BotHUD:on_client_bot_reloaded(base)
	if not self.active then
		return
	end

	local unit = base._setup and base._setup.user_unit
	if not self:is_bot(unit) then
		return
	end

	local ammo_base = base:ammo_base()
	local max_clip = ammo_base and ammo_base:get_ammo_max_per_clip()
	if max_clip and max_clip > 0 then
		base._sh_bot_clip = max_clip

		self:log_once("client_reloaded", "client saw a bot reload finish (%d)", max_clip)
	end
end

-- client only: the host says this bot started a reload, so its real mag is empty (drift correction)
function BotHUD:on_reload_start(unit)
	if not self.active or Network:is_server() or not self:is_bot(unit) then
		return
	end

	local base = self:_weapon_base(unit)
	if base then
		base._sh_bot_clip = 0

		self:log_once("reload_start", "client got a bot reload start")
	end
end

local function fmt_remaining(value, t)
	return value and string.format("%+.2f", value - t) or "nil"
end

-- host: read the authoritative state of a bot
function BotHUD:_read_host_state(name, unit, s, t)
	local dmg = unit:character_damage()
	if not dmg then
		return
	end

	local ratio = dmg._health_ratio or 1
	local down = dmg._dead or dmg._bleed_out or dmg._fatal

	s.health = down and 0 or ratio
	s.regen_end = nil

	-- vanilla only has _regenerate_t (reset by hits). _sh_next_regen is an optional second timer some mods add (Streamlined
	-- Heisting's constant regen), the radial follows whichever pulse comes next
	local regen_t, sh_next = dmg._regenerate_t, dmg._sh_next_regen

	if not down and ratio < 1 then
		s.regen_end = (regen_t and sh_next) and math.min(regen_t, sh_next) or regen_t or sh_next

		if self.logging and (not s.log_t or t - s.log_t >= 1) then
			s.log_t = t

			self:log("%s hp=%.2f _regenerate_t=%s _sh_next_regen=%s -> next pulse=%s", name, ratio, fmt_remaining(regen_t, t), fmt_remaining(sh_next, t), fmt_remaining(s.regen_end, t))
		end
	elseif ratio >= 1 and regen_t and regen_t < t - 1 then
		self:log_once("stale_regen_t", "_regenerate_t is %.1fs in the past at full health, _regenerated() is probably running every frame", t - regen_t)
	end

	local char_tweak = dmg._char_dmg_tweak
	s.interval = math.max(char_tweak and char_tweak.REGENERATE_TIME or self.DEFAULT_INTERVAL, 0.01)
end

-- host: a client with the mod said hello
function BotHUD:_on_hello(peer_id)
	if not self.active then
		return
	end

	local is_new = not self.mod_peers[peer_id] or self.mod_peers[peer_id] < Application:time()

	self.mod_peers[peer_id] = Application:time() + self.PEER_TIMEOUT

	if is_new then
		self:log("peer %s runs the mod, sending it every bot's state", tostring(peer_id))

		-- force a full resend on the next tick
		for _, s in pairs(self.states) do
			s.sent_t = nil
		end
	end
end

-- host: tell clients about changes
function BotHUD:_send_state(name, s, t)
	if not next(self.mod_peers) or not LuaNetworking or not LuaNetworking.SendToPeer or not (managers.network and managers.network:session()) then
		return
	end

	local regen_changed = (s.regen_end == nil) ~= (s.sent_regen_end == nil) or (s.regen_end and s.sent_regen_end and math.abs(s.regen_end - s.sent_regen_end) > 0.1)
	local heartbeat = not s.sent_t or t - s.sent_t >= self.HEARTBEAT

	if s.health == s.sent_health and not regen_changed and not heartbeat then
		return
	end

	s.sent_health = s.health
	s.sent_regen_end = s.regen_end
	s.sent_t = t

	local remaining = s.regen_end and math.max(s.regen_end - t, 0) or -1
	local message = string.format("%s|%.3f|%.3f|%.3f", name, s.health, remaining, s.interval)
	local now = Application:time()

	for peer_id, expires in pairs(self.mod_peers) do
		if now > expires then
			self.mod_peers[peer_id] = nil
		else
			LuaNetworking:SendToPeer(peer_id, self.NET_ID, message)
		end
	end

	self:log_once("sent_" .. name, "host sent the first state message for %s", name)
end

-- client: let the host know this client runs the mod (the host only sends to peers that did)
function BotHUD:_say_hello()
	if Network:is_server() or not LuaNetworking or not LuaNetworking.SendToPeer or not (managers.network and managers.network:session()) then
		return
	end

	local now = Application:time()

	if self._hello_t and now - self._hello_t < self.HELLO_INTERVAL then
		return
	end

	self._hello_t = now

	LuaNetworking:SendToPeer(1, self.HELLO_ID, "1")

	self:log_once("hello", "sent hello to the host")
end

-- client: state message from the host
function BotHUD:_on_network_state(data)
	if not self.active then
		return
	end

	local name, health, remaining, interval = string.match(data or "", "^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
	health, remaining, interval = tonumber(health), tonumber(remaining), tonumber(interval)

	if not (name and health and remaining and interval) then
		self:warn("ignoring malformed state message: %s", tostring(data))

		return
	end

	local s = self.states[name]
	if not s then
		s = {}
		self.states[name] = s
	end

	s.host_data = true
	s.health = math.clamp(health, 0, 1)
	s.interval = math.max(interval, 0.01)
	s.regen_end = remaining >= 0 and TimerManager:game():time() + remaining or nil

	self:log_once("received_" .. name, "client received the first state message for %s", name)
end

-- both: push what changed to the bot's teammate panel
function BotHUD:_render(panel_id, unit, s, t)
	local hud = managers.hud
	local show_host_state = Network:is_server() or s.host_data

	-- a host without the mod never sends health/regen, so leave vanilla's full ring alone instead of showing a made-up value
	if not show_host_state and s.first_seen and t - s.first_seen > self.NO_HOST_DATA_WARNING then
		self:log_once("no_host_data", "no bot state received from the host after %ds, the host probably doesn't run this mod (health and regen stay at vanilla's full ring)", self.NO_HOST_DATA_WARNING)
	end

	if show_host_state and s.pushed_health ~= s.health then
		s.pushed_health = s.health

		hud:set_teammate_health(panel_id, { current = s.health, total = 1, max = 1 })
	end

	-- clients don't run the regen timers, so keep counting on the last known schedule until the next message
	if not Network:is_server() and s.regen_end and t > s.regen_end then
		s.regen_end = s.regen_end + s.interval * math.ceil((t - s.regen_end) / s.interval)
	end

	local progress = s.regen_end and math.clamp(1 - (s.regen_end - t) / s.interval, 0, 1) or 0

	if show_host_state and (not s.pushed_armor or math.abs(progress - s.pushed_armor) >= self.ARMOR_EPSILON or ((progress == 0 or progress == 1) and progress ~= s.pushed_armor)) then
		s.pushed_armor = progress

		hud:set_teammate_armor(panel_id, { current = progress, total = 1, max = 1 })
	end

	-- vanilla's add_teammate_panel gives bots the team a.i colour, so this also repaints after a panel is (re)created
	if s.color_id and s.pushed_color ~= s.color_id then
		s.pushed_color = s.color_id

		hud:set_teammate_callsign(panel_id, s.color_id)
	end

	-- the in-world name label and the outline are only coloured once by vanilla, so keep them in sync as well
	if s.color_id and s.pushed_world_color ~= s.color_id then
		s.pushed_world_color = s.color_id

		self:_recolor_world(unit, s.color_id)
	end

	local base = self:_weapon_base(unit)
	local clip, max_clip
	if base then
		clip, max_clip = self:_read_clip(base)
	end

	if clip and (s.pushed_clip ~= clip or s.pushed_max ~= max_clip) then
		s.pushed_clip, s.pushed_max = clip, max_clip

		-- the visible number on a teammate panel is the "total" field, so the mag count goes in there (no reserve shown)
		hud:set_teammate_ammo_amount(panel_id, self.PRIMARY_SELECTION, max_clip, clip, clip, max_clip)
	end
end

function BotHUD:_update_bot(name, unit, t, color_id)
	local panel_id = self:_panel_id(name)
	if not panel_id then
		return
	end

	local s = self.states[name]
	if not s then
		s = {}
		self.states[name] = s
	end

	s.health = s.health or 1
	s.interval = s.interval or self.DEFAULT_INTERVAL
	s.color_id = color_id
	s.first_seen = s.first_seen or t

	local unit_key = unit:key()
	local resync = not s.resync_t or t - s.resync_t >= self.RESYNC

	if s.panel_id ~= panel_id or s.unit_key ~= unit_key or resync then
		if s.panel_id ~= panel_id or s.unit_key ~= unit_key then
			self:log_once("bind_" .. name .. "_" .. tostring(panel_id), "bound %s to teammate panel %s", name, tostring(panel_id))
		end

		s.panel_id, s.unit_key, s.resync_t = panel_id, unit_key, t
		s.pushed_health, s.pushed_armor, s.pushed_clip, s.pushed_max, s.pushed_color, s.pushed_world_color = nil, nil, nil, nil, nil, nil
	end

	if Network:is_server() then
		self:_read_host_state(name, unit, s, t)
		self:_send_state(name, s, t)
	end

	self:_render(panel_id, unit, s, t)
end

-- player colours (tweak_data.chat_colors 1-4) that no human peer is using, in ascending order
function BotHUD:_free_color_ids()
	local used = {}
	local session = managers.network and managers.network:session()

	if session then
		local local_peer = session:local_peer()
		if local_peer then
			used[local_peer:id()] = true
		end

		for _, peer in pairs(session:all_peers() or {}) do
			used[peer:id()] = true
		end
	end

	local free = {}
	for id = 1, tweak_data.max_players do
		if not used[id] then
			free[#free + 1] = id
		end
	end

	return free
end

-- every bot with its assigned player colour, plus a name -> colour id map
function BotHUD:_collect_bots()
	local groupai = managers.groupai and managers.groupai:state()
	local bots, colors = {}, {}

	if not groupai or not managers.criminals then
		return bots, colors
	end

	for _, crim in pairs(groupai:all_AI_criminals()) do
		local unit = crim.unit

		if alive(unit) then
			local name = managers.criminals:character_name_by_unit(unit)

			if name then
				bots[#bots + 1] = { name = name, unit = unit }
			end
		end
	end

	-- every machine sorts the same way, so host and clients agree on who gets which colour
	table.sort(bots, function(a, b)
		return a.name < b.name
	end)

	local free_colors = self:_free_color_ids()
	local team_ai_color = #tweak_data.chat_colors -- only used if there are more bots than free colours

	for i, bot in ipairs(bots) do
		bot.color_id = free_colors[i] or team_ai_color
		colors[bot.name] = bot.color_id
	end

	return bots, colors
end

-- used by CriminalsManager:character_color_id_by_unit (see criminalsmanager.lua) so freshly created labels start out right
function BotHUD:color_id_for_unit(unit)
	if not self.active then
		return
	end

	local name = managers.criminals and managers.criminals:character_name_by_unit(unit)

	if name then
		local _, colors = self:_collect_bots()

		return colors[name]
	end
end

-- the label above a bot's head: vanilla colours the text, the carried-bag icon and the "fixing" text once at creation
function BotHUD:_recolor_name_label(unit, color)
	local unit_data = unit:unit_data()
	local label_id = unit_data and unit_data.name_label_id
	local labels = managers.hud and managers.hud._hud and managers.hud._hud.name_labels

	if not label_id or not labels then
		return
	end

	for _, label in ipairs(labels) do
		if label.id == label_id then
			local bright = (color * 1.1):with_alpha(1)

			if alive(label.text) then
				label.text:set_color(color)
			end

			if alive(label.bag) then
				label.bag:set_color(bright)
			end

			local action = alive(label.panel) and label.panel:child("action")
			if action then
				action:set_color(bright)
			end

			return
		end
	end
end

-- the outline: human teammates get a "teammate" contour with their peer colour. Which contour a bot has isn't visible
-- from the lua, so recolour "teammate"/"friendly" and log what the bot actually has (once) to find out
BotHUD.CONTOUR_TYPES = { teammate = true, friendly = true }

function BotHUD:_recolor_contour(name, unit, vector_color)
	local contour = unit:contour()

	if not contour or not vector_color then
		return
	end

	local found, changed = {}, false

	for _, setup in ipairs(contour:contour_list()) do
		found[#found + 1] = setup.type .. (setup.color and "(coloured)" or "")

		if self.CONTOUR_TYPES[setup.type] and setup.color ~= vector_color then
			setup.color = vector_color
			changed = true
		end
	end

	if changed then
		contour:_upd_color()
	end

	self:log_once("contour_" .. name, "%s contours: %s", name, #found > 0 and table.concat(found, ", ") or "none")
end

function BotHUD:_recolor_world(unit, color_id)
	local name = managers.criminals:character_name_by_unit(unit)
	local color = tweak_data.chat_colors[color_id] or tweak_data.chat_colors[#tweak_data.chat_colors]
	local vector_color = tweak_data.peer_vector_colors[color_id] or tweak_data.peer_vector_colors[#tweak_data.peer_vector_colors]

	self:_recolor_name_label(unit, color)
	self:_recolor_contour(name or "?", unit, vector_color)
end

-- Panels are checked once per HUD (every panel must have vanilla's parts), then bot panels are kept in the bot layout.
-- This doesn't depend on the set_state hook, some HUD mods redefine set_state after us and would drop the hook.
function BotHUD:_sweep_panels(t)
	local panels = managers.hud._teammate_panels

	if self._checked_panels ~= panels then
		self._checked_panels = panels

		if HUDManager.CUSTOM_TEAMMATE_PANELS then
			self:deactivate("the HUD replaces the teammate panels" .. self:hud_hint())

			return
		end

		for i, panel in ipairs(panels) do
			local vanilla_layout, missing = self:check_panel(panel)

			if not vanilla_layout then
				self:deactivate("teammate panel " .. i .. " doesn't look like vanilla's (missing " .. tostring(missing) .. ")" .. self:hud_hint())

				return
			end
		end

		self:log("all %d teammate panels look like vanilla's", #panels)
	end

	if self._sweep_t and t - self._sweep_t < 0.5 then
		return
	end

	self._sweep_t = t

	if not HUDTeammate._sh_bot_apply_layout then
		return
	end

	for _, panel in ipairs(panels) do
		if panel._player_panel and not panel._main_player then
			if panel._ai then
				if not panel._sh_bot_panel then
					HUDTeammate._sh_bot_apply_layout(panel)

					self:log_once("swept_" .. tostring(panel._id), "teammate panel %s was switched to the full layout by the sweep (the set_state hook didn't run)", tostring(panel._id))
				elseif panel._player_panel:alpha() < 0.5 then
					-- something hid it again (another mod's set_state)
					HUDTeammate.set_state(panel, "player")
				end
			elseif panel._sh_bot_panel then
				-- the panel is no longer a bot's (removed, or a human took it) and the set_state hook didn't give it back
				HUDTeammate._sh_bot_restore_layout(panel)

				self:log_once("restored_" .. tostring(panel._id), "teammate panel %s was restored by the sweep", tostring(panel._id))
			end
		end
	end
end

function BotHUD:update()
	if not self.active or not managers.hud or not managers.hud._teammate_panels then
		return
	end

	self:_recheck_globals(Application:time())

	if not self.active then
		return
	end

	local t = TimerManager:game():time()

	self:_sweep_panels(t)

	if not self.active then
		return
	end

	self:_say_hello()

	for _, bot in ipairs(self:_collect_bots()) do
		-- one broken bot must not spam the log every frame
		local ok, err = pcall(self._update_bot, self, bot.name, bot.unit, t, bot.color_id)

		if not ok and not self._logged.update_error then
			self._logged.update_error = true

			self:error("update failed for %s: %s", bot.name, tostring(err))
		end
	end
end

