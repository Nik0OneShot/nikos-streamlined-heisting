UsefulBots = UsefulBots or {}
UsefulBots.mod_path = StreamHeist.mod_path
UsefulBots.NET_ID = "sh_useful_bots"

function UsefulBots.get_default_settings()
	return {
		no_crouch = false,
		dominate_enemies = 1,
		secure_loot = false,
		mark_specials = true,
		intimidate_civilians = true,
		announce_low_hp = true,
		hold_position = true,
		battle_cries = true,
		block_slow_vehicles = true,
		ammo_drops = 1,
		save_inspire = true,
		stop_at_player = false,
		defend_reviving = true,
		follow_behavior = 1,
		wait_tap_mode = 1,
		wait_release = true,
		wait_hold_time = 0.5,
		hold_radius = 10,
		withdraw_health = 0.5,
		reload_in_cover = true,
		stealth_bots = true,
		stealth_bag_dropoff_range = 12,
		stealth_bag_stash_range = 12,
		stealth_hold_time = 0.5,
		stealth_alert_count = 5,
		stealth_wait = true,
		stealth_civ_radius = 15,
		stealth_wander = true,
		stealth_routes = true,
		bot_interact = true,
		auto_orders = true,
		auto_pager = true,
		auto_bodybag = true,
		auto_tie = true,
		auto_guard = true,
		auto_seek = true,
		auto_range = 12,
		stealth_walls = true,
		stealth_doors = true,
		stealth_no_smash = true,
		stealth_civ_rush = true,
		stealth_follow = true,
		stealth_melee = true,
		stealth_flank = true,
		stealth_instant_melee = true,
		stealth_stay_hidden = true,
		stealth_call = true,
		stay_in_room = true,
		stealth_dash = true,
		stealth_dash_limit = 0.5,
		stealth_detection_mul = 0.5,
		revive_distance = 25,
		drop_bag_percentage = 0.25,
		targeting_priority = {
			base_priority = 1,
			player_aim = 1.5,
			critical = 2,
			marked = 1.5,
			defend = 1.5,
			domination = 2,
			enemies = {
				marshal_marksman = 1,
				marshal_shield = 1,
				medic = 2,
				phalanx_minion = 1,
				phalanx_vip = 1,
				shield = 1,
				sniper = 1.5,
				spooc = 2,
				tank = 1,
				tank_hw = 1,
				tank_medic = 2,
				tank_mini = 1,
				taser = 1.7,
				turret = 0.5
			}
		}
	}
end

StreamHeist.settings.useful_bots = StreamHeist.settings.useful_bots or UsefulBots.get_default_settings()
UsefulBots.settings = StreamHeist.settings.useful_bots

UsefulBots.peer_settings = setmetatable({
	[1] = UsefulBots.settings
}, {
	__index = function(t, k)
		t[k] = UsefulBots.get_default_settings()
		return t[k]
	end
})



function UsefulBots:get_assist_SO(unit)
	return {
		chance_inc = 0,
		base_chance = 1,
		usage_amount = 1,
		AI_group = "friendlies",
		search_pos = unit:position(),
		objective = self:get_assist_objective(unit)
	}
end

function UsefulBots:get_assist_objective(unit, receiver)
	local pos = mvector3.copy(math.UP)
	mvector3.random_orthogonal(pos)
	mvector3.multiply(pos, 50)
	mvector3.add(pos, unit:position())
	local nav_tracker = managers.navigation:create_nav_tracker(pos)
	local nav_seg = nav_tracker:nav_segment()
	pos = nav_tracker:field_position()
	managers.navigation:destroy_nav_tracker(nav_tracker)
	return {
		type = "defend_area",
		scan = true,
		assist_unit = unit,
		haste = "run",
		pose = "stand",
		nav_seg = nav_seg,
		pos = pos
	}
end

function UsefulBots:stop_assist_objective(unit)
	for _, c_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local brain = c_data.unit:brain()
		local objective = brain:objective()
		if objective and objective.assist_unit == unit then
			brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(c_data.unit))
		end
	end
end

function UsefulBots:get_reviving_unit(unit)
	for _, c_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local brain = c_data.unit:brain()
		local objective = brain:objective()
		if objective and objective.type == "revive" and objective.follow_unit == unit then
			return c_data.unit
		end
	end
end

function UsefulBots:force_attention(attention_unit)
	for _, c_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local logic_data = c_data.unit:brain()._logic_data
		TeamAILogicBase.force_attention(logic_data, logic_data.internal_data, attention_unit)
	end
end

function UsefulBots:unregister_unit(unit)
	for _, c_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local logic_data = c_data.unit:brain()._logic_data
		if logic_data._latest_follow_unit == unit then
			logic_data._latest_follow_unit = nil
		end
	end
end

function UsefulBots:player_settings(player_unit)
	local peer = alive(player_unit) and player_unit:network() and player_unit:network():peer()
	return self.peer_settings[peer and peer:id() or 1]
end


function UsefulBots:send_settings()
	if Network:is_server() or not LuaNetworking or not LuaNetworking.SendToPeer or not (managers.network and managers.network:session()) then
		return
	end

	LuaNetworking:SendToPeer(1, self.NET_ID, json.encode({
		stop_at_player = self.settings.stop_at_player,
		follow_behavior = self.settings.follow_behavior,
		wait_tap_mode = self.settings.wait_tap_mode
	}))

	StreamHeist:log("Sent Useful Bots settings to the host")
end

function UsefulBots:receive_settings(sender, data)
	if sender == 1 then
		return
	end

	local success, decoded = pcall(json.decode, data)
	if not success or type(decoded) ~= "table" then
		return
	end

	local peer_settings = self.peer_settings[sender]
	if type(decoded.stop_at_player) == "boolean" then
		peer_settings.stop_at_player = decoded.stop_at_player
	end
	if type(decoded.follow_behavior) == "number" and decoded.follow_behavior >= 1 and decoded.follow_behavior <= 4 then
		peer_settings.follow_behavior = math.floor(decoded.follow_behavior)
	end
	if type(decoded.wait_tap_mode) == "number" and decoded.wait_tap_mode >= 1 and decoded.wait_tap_mode <= 2 then
		peer_settings.wait_tap_mode = math.floor(decoded.wait_tap_mode)
	end

	StreamHeist:log("Received Useful Bots settings from peer %d (stop at player: %s, follow behavior: %d)", sender, tostring(peer_settings.stop_at_player), peer_settings.follow_behavior)
end

if not UsefulBots._net_hooked then
	UsefulBots._net_hooked = true

	Hooks:Add("BaseNetworkSessionOnLoadComplete", "BaseNetworkSessionOnLoadCompleteStreamHeistUsefulBots", function()
		UsefulBots:send_settings()
	end)

	Hooks:Add("NetworkReceivedData", "NetworkReceivedDataStreamHeistUsefulBots", function(sender, message_id, data)
		if message_id == UsefulBots.NET_ID and Network:is_server() then
			UsefulBots:receive_settings(sender, data)
		end
	end)
end



function UsefulBots:update_menu_state()
	local enabled = self.settings.targeting_priority.base_priority <= 2

	for _, item in pairs(self._priority_items or {}) do
		if item.set_enabled then
			item:set_enabled(enabled)
		end
	end

	local dominate = self._menu_items and self._menu_items.dominate_enemies
	if dominate and dominate.set_enabled then
		dominate:set_enabled(enabled)
	end
end

function UsefulBots:create_menu(parent_menu_id, nodes, priority)
	local loc = managers.localization
	local settings = self.settings
	local priority_settings = settings.targeting_priority
	local defaults = self.get_default_settings()

	local function mod_enabled(name)
		local mod = BLT and BLT.Mods and BLT.Mods:GetModByName(name)
		return mod and mod:IsEnabled() or false
	end

	local keepers = mod_enabled("Keepers")
	local monkeepers = mod_enabled("Monkeepers")

	local menu_id = "sh_menu_useful_bots"
	local menu_id_targeting = "sh_menu_useful_bots_targeting"
	local menu_id_enemies = "sh_menu_useful_bots_enemies"

	MenuHelper:NewMenu(menu_id)
	MenuHelper:NewMenu(menu_id_targeting)
	MenuHelper:NewMenu(menu_id_enemies)

	local function round(value, decimals)
		local mul = 10 ^ (decimals or 0)
		return math.floor(value * mul + 0.5) / mul
	end

	function MenuCallbackHandler:sh_ub_toggle(item)
		UsefulBots.settings[item:name()] = (item:value() == "on")
	end

	function MenuCallbackHandler:sh_ub_choice(item)
		UsefulBots.settings[item:name()] = item:value()
	end

	function MenuCallbackHandler:sh_ub_slider(item)
		UsefulBots.settings[item:name()] = round(item:value(), 2)
	end

	function MenuCallbackHandler:sh_ub_slider_percent(item)
		UsefulBots.settings[item:name()] = round(item:value() / 100, 2)
	end

	function MenuCallbackHandler:sh_ub_priority(item)
		UsefulBots.settings.targeting_priority[item:name()] = round(item:value(), 2)
	end

	function MenuCallbackHandler:sh_ub_enemy(item)
		UsefulBots.settings.targeting_priority.enemies[item:name()] = round(item:value(), 2)
	end

	function MenuCallbackHandler:sh_ub_base_priority(item)
		UsefulBots.settings.targeting_priority.base_priority = item:value()
		UsefulBots:update_menu_state()
	end

	self._menu_items = {}
	self._priority_items = {}

	local function add_toggle(id, prio, disabled)
		self._menu_items[id] = MenuHelper:AddToggle({
			id = id,
			title = "sh_ub_" .. id,
			desc = "sh_ub_" .. id .. "_desc",
			callback = "sh_ub_toggle",
			value = settings[id],
			disabled = disabled,
			menu_id = menu_id,
			priority = prio
		})
	end

	local function add_choice(menu, id, items, prio, value, callback, disabled)
		return MenuHelper:AddMultipleChoice({
			id = id,
			title = "sh_ub_" .. id,
			desc = "sh_ub_" .. id .. "_desc",
			callback = callback,
			items = items,
			value = value,
			disabled = disabled,
			menu_id = menu,
			priority = prio
		})
	end

	local function add_slider(menu, id, prio, callback, value, min, max, step, disabled)
		return MenuHelper:AddSlider({
			id = id,
			title = "sh_ub_" .. id,
			desc = "sh_ub_" .. id .. "_desc",
			callback = callback,
			value = value,
			min = min,
			max = max,
			step = step,
			show_value = true,
			disabled = disabled,
			menu_id = menu,
			priority = prio
		})
	end

	local function add_divider(menu, prio)
		MenuHelper:AddDivider({
			menu_id = menu,
			size = 16,
			priority = prio
		})
	end

	local vanilla_targeting = priority_settings.base_priority > 2

	local enemies = {
		{ "marshal_marksman", "ene_male_marshal_marksman" },
		{ "marshal_shield", "ene_male_marshal_shield" },
		{ "medic", "ene_medic" },
		{ "phalanx_minion", "ene_phalanx" },
		{ "phalanx_vip", "ene_vip" },
		{ "shield", "ene_shield" },
		{ "sniper", "ene_sniper" },
		{ "spooc", "ene_spook" },
		{ "tank", "ene_bulldozer_1" },
		{ "tank_hw", "ene_bulldozer_4" },
		{ "tank_medic", "ene_bulldozer_medic" },
		{ "tank_mini", "ene_bulldozer_minigun" },
		{ "taser", "ene_tazer" },
		{ "turret", "tweak_swat_van_turret_module" }
	}

	for i, enemy in ipairs(enemies) do
		local id = enemy[1]
		local value = priority_settings.enemies[id]
		if type(value) ~= "number" then
			value = defaults.targeting_priority.enemies[id]
		end
		self._priority_items["enemy_" .. id] = MenuHelper:AddSlider({
			id = id,
			localized = false,
			title = loc:exists(enemy[2]) and loc:text(enemy[2]) or id,
			callback = "sh_ub_enemy",
			value = value,
			min = 0,
			max = 5,
			step = 0.1,
			show_value = true,
			disabled = vanilla_targeting,
			menu_id = menu_id_enemies,
			priority = 100 - i
		})
	end

	add_choice(menu_id_targeting, "base_priority", { "sh_ub_weapon_stats", "sh_ub_distance", "sh_ub_no_changes" }, 100, priority_settings.base_priority, "sh_ub_base_priority")
	add_divider(menu_id_targeting, 99)

	for i, id in ipairs({ "player_aim", "critical", "marked", "defend", "domination" }) do
		self._priority_items[id] = add_slider(menu_id_targeting, id, 98 - i, "sh_ub_priority", priority_settings[id], 0, 5, 0.1, vanilla_targeting)
	end

	add_divider(menu_id_targeting, 90)

	MenuHelper:AddButton({
		id = "enemies",
		title = "sh_ub_enemies",
		desc = "sh_ub_enemies_desc",
		next_node = menu_id_enemies,
		menu_id = menu_id_targeting,
		priority = 89
	})

	self._menu_items.dominate_enemies = add_choice(menu_id, "dominate_enemies", { "dialog_yes", "sh_ub_assist_only", "dialog_no" }, 99, settings.dominate_enemies, "sh_ub_choice", vanilla_targeting)
	add_toggle("secure_loot", 98, monkeepers)
	add_toggle("mark_specials", 97)
	add_toggle("intimidate_civilians", 96)
	add_divider(menu_id, 95)

	add_choice(menu_id, "wait_tap_mode", { "sh_ub_wait_patrol", "sh_ub_wait_stationary" }, 94, settings.wait_tap_mode, "sh_ub_choice", keepers)
	add_toggle("wait_release", 93.5, keepers)
	add_slider(menu_id, "wait_hold_time", 93, "sh_ub_slider", settings.wait_hold_time, 0.2, 1.5, 0.1, keepers)
	add_slider(menu_id, "hold_radius", 92, "sh_ub_slider", settings.hold_radius, 3, 30, 1, keepers)
	add_toggle("stay_in_room", 91.5)
	add_slider(menu_id, "withdraw_health", 91, "sh_ub_slider_percent", round(settings.withdraw_health * 100), 10, 90, 5, keepers)
	add_toggle("reload_in_cover", 90.5)
	add_toggle("stealth_bots", 90.4)
	add_slider(menu_id, "stealth_bag_dropoff_range", 90.35, "sh_ub_slider", settings.stealth_bag_dropoff_range, 0, 101, 1)
	add_slider(menu_id, "stealth_bag_stash_range", 90.34, "sh_ub_slider", settings.stealth_bag_stash_range, 0, 101, 1)
	add_slider(menu_id, "stealth_hold_time", 90.3, "sh_ub_slider", settings.stealth_hold_time, 0.3, 1.5, 0.1)
	add_slider(menu_id, "stealth_alert_count", 90.2, "sh_ub_slider", settings.stealth_alert_count, 2, 15, 1)
	add_toggle("stealth_wait", 90.1)
	add_slider(menu_id, "stealth_civ_radius", 90.05, "sh_ub_slider", settings.stealth_civ_radius, 5, 30, 1)
	add_toggle("stealth_wander", 90.04)
	add_toggle("stealth_routes", 90.045)
	add_toggle("stealth_doors", 90.044)
	add_toggle("stealth_walls", 90.042)
	add_toggle("stealth_no_smash", 90.043)
	add_toggle("stealth_civ_rush", 90.03)
	add_toggle("stealth_follow", 90.03)
	add_toggle("stealth_melee", 90.02)
	add_toggle("stealth_flank", 90.018)
	add_toggle("stealth_instant_melee", 90.016)
	add_toggle("stealth_stay_hidden", 90.014)
	add_toggle("stealth_call", 90.01)
	add_toggle("stealth_dash", 90.005)
	add_slider(menu_id, "stealth_dash_limit", 90.004, "sh_ub_slider_percent", round(settings.stealth_dash_limit * 100), 20, 80, 5)
	add_slider(menu_id, "stealth_detection_mul", 90.003, "sh_ub_slider_percent", round(settings.stealth_detection_mul * 100), 10, 100, 5)
	add_toggle("bot_interact", 89.95)
	add_toggle("auto_orders", 89.94)
	add_toggle("auto_pager", 89.93)
	add_toggle("auto_bodybag", 89.92)
	add_toggle("auto_seek", 89.91)
	add_toggle("auto_tie", 89.915)
	add_toggle("auto_guard", 89.912)
	add_slider(menu_id, "auto_range", 89.9, "sh_ub_slider", settings.auto_range, 5, 30, 1)
	add_divider(menu_id, 90)


	add_choice(menu_id, "follow_behavior", { "sh_ub_follow_default", "sh_ub_follow_close", "sh_ub_follow_medium", "sh_ub_follow_far" }, 89, settings.follow_behavior, "sh_ub_choice")
	add_toggle("hold_position", 88, keepers)
	add_toggle("stop_at_player", 87, keepers)
	add_toggle("block_slow_vehicles", 86)
	add_toggle("no_crouch", 85)
	add_toggle("defend_reviving", 84)
	add_toggle("save_inspire", 83)
	add_slider(menu_id, "revive_distance", 82, "sh_ub_slider", settings.revive_distance, 0, 50, 1)
	add_slider(menu_id, "drop_bag_percentage", 81, "sh_ub_slider_percent", round(settings.drop_bag_percentage * 100), 0, 100, 5)
	add_divider(menu_id, 80)

	add_toggle("announce_low_hp", 79)
	add_toggle("battle_cries", 78)
	add_slider(menu_id, "ammo_drops", 77, "sh_ub_slider_percent", round(settings.ammo_drops * 100), 0, 100, 5)
	add_divider(menu_id, 76)

	MenuHelper:AddButton({
		id = "targeting_priority",
		title = "sh_ub_targeting_priority",
		desc = "sh_ub_targeting_priority_desc",
		next_node = menu_id_targeting,
		menu_id = menu_id,
		priority = 75
	})

	nodes[menu_id_enemies] = MenuHelper:BuildMenu(menu_id_enemies, { back_callback = "sh_save" })
	nodes[menu_id_targeting] = MenuHelper:BuildMenu(menu_id_targeting, { back_callback = "sh_save" })
	nodes[menu_id] = MenuHelper:BuildMenu(menu_id, { back_callback = "sh_save" })

	MenuHelper:AddButton({
		id = "useful_bots",
		title = "sh_ub_menu",
		desc = "sh_ub_menu_desc",
		next_node = menu_id,
		menu_id = parent_menu_id,
		priority = priority
	})

	StreamHeist:log("Useful Bots menu created (base targeting: %d, hold position: %s, follow behavior: %d)", priority_settings.base_priority, tostring(settings.hold_position), settings.follow_behavior)
end


StreamHeist:require("bot_hold")

StreamHeist:require("bot_reload")

StreamHeist:require("bot_stealth")

StreamHeist:require("bot_nav")

StreamHeist:require("bot_sneak")

StreamHeist:require("bot_bag")

StreamHeist:require("bot_melee")

StreamHeist:require("bot_interact")
