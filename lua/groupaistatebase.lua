-- Set up needed variables
Hooks:PostHook(GroupAIStateBase, "init", "sh_init", function(self)
	self._next_police_upd_task = 0
	self._next_group_spawn_t = {}
end)


-- Restore scripted cloaker spawn noise
local _process_recurring_grp_SO_original = GroupAIStateBase._process_recurring_grp_SO
function GroupAIStateBase:_process_recurring_grp_SO(...)
	if _process_recurring_grp_SO_original(self, ...) then
		managers.network:session():send_to_peers_synched("group_ai_event", self:get_sync_event_id("cloaker_spawned"), 0)
		managers.hud:post_event("cloaker_spawn")
		return true
	end
end


-- Make difficulty progress smoother
function GroupAIStateBase:_update_difficulty_value()
	if self._target_difficulty and self._t >= self._next_difficulty_step_t then
		self._difficulty_value = math.min(self._difficulty_value + self._difficulty_step, self._target_difficulty)
		if self._difficulty_value >= self._target_difficulty then
			self._target_difficulty = nil
		else
			self._next_difficulty_step_t = self._t + 15
		end
		self:_calculate_difficulty_ratio()
	end
end

local set_difficulty_original = GroupAIStateBase.set_difficulty
function GroupAIStateBase:set_difficulty(value, ...)
	if not managers.game_play_central or managers.game_play_central:get_heist_timer() < 1 or value < self._difficulty_value then
		self._target_difficulty = nil

		return set_difficulty_original(self, value, ...)
	end

	self._difficulty_step = 0.05
	self._target_difficulty = value
	self._next_difficulty_step_t = self._next_difficulty_step_t or self._t

	self:_update_difficulty_value()
end

Hooks:PostHook(GroupAIStateBase, "update", "sh_update", GroupAIStateBase._update_difficulty_value)


-- Delay spawn points when enemies die close to them
Hooks:PostHook(GroupAIStateBase, "on_enemy_unregistered", "sh_on_enemy_unregistered", function(self, unit)
	if Network:is_client() or not unit:character_damage():dead() then
		return
	end

	local e_data = self._police[unit:key()]
	if not e_data.group or not e_data.group.has_spawned or not e_data.spawn_group then
		return
	end

	local dis = mvector3.distance(e_data.spawn_group.pos, e_data.m_pos)
	local max_dis = tweak_data.group_ai.spawn_kill_max_dis
	if dis > max_dis then
		return
	end

	local delay_t = self._t + math.map_range(dis, 0, max_dis, tweak_data.group_ai.spawn_kill_cooldown, 0)
	e_data.spawn_group.delay_t = math.max(e_data.spawn_group.delay_t, delay_t)
end)


-- Fix this function doing nothing
function GroupAIStateBase:_merge_coarse_path_by_area(coarse_path)
	local i_nav_seg = #coarse_path
	local area, last_area
	while i_nav_seg > 0 and #coarse_path > 2 do
		area = self:get_area_from_nav_seg_id(coarse_path[i_nav_seg][1])
		if last_area and last_area == area then
			table.remove(coarse_path, i_nav_seg)
		else
			last_area = area
		end
		i_nav_seg = i_nav_seg - 1
	end
end


-- Ignore disabled criminals for area safety checks
function GroupAIStateBase:is_area_safe(area)
	for _, u_data in pairs(self._criminals) do
		if u_data.status ~= "disabled" and u_data.status ~= "dead" and area.nav_segs[u_data.tracker:nav_segment()] then
			return
		end
	end
	return true
end

function GroupAIStateBase:is_area_safe_assault(area)
	for _, u_data in pairs(self._char_criminals) do
		if u_data.status ~= "disabled" and u_data.status ~= "dead" and area.nav_segs[u_data.tracker:nav_segment()] then
			return
		end
	end
	return true
end

function GroupAIStateBase:is_nav_seg_safe(nav_seg)
	for _, u_data in pairs(self._criminals) do
		if u_data.status ~= "disabled" and u_data.status ~= "dead" and u_data.tracker:nav_segment() == nav_seg then
			return
		end
	end
	return true
end

function GroupAIStateBase:is_nav_seg_area_safe(skip_areas, nav_seg)
	for _, area in pairs(skip_areas) do
		if area.nav_segs[nav_seg] then
			return true
		end
	end
	return self:is_area_safe(self:get_area_from_nav_seg_id(nav_seg))
end


-- Don't count recon as assault force and vice versa
function GroupAIStateBase:_count_police_force(task_name)
	local amount = 0
	local objective_type = task_name .. "_area"
	for _, group in pairs(self._groups) do
		if group.objective.type == objective_type then
			amount = amount + (group.has_spawned and group.size or group.initial_size)
		end
	end
	return amount
end


-- Set accurate criminal position
Hooks:PostHook(GroupAIStateBase, "criminal_spotted", "sh_criminal_spotted", function(self, unit)
	local u_sighting = self._criminals[unit:key()]
	mvector3.set(u_sighting.pos, u_sighting.m_det_pos)
end)


-- Do not update detected position and time on nav segment change
-- Log time when criminals enter an area to use for the teargas check
Hooks:OverrideFunction(GroupAIStateBase, "on_criminal_nav_seg_change", function(self, unit, nav_seg_id)
	local u_key = unit:key()
	local u_sighting = self._criminals[u_key]
	if not u_sighting then
		return
	end

	u_sighting.seg = nav_seg_id

	local prev_area = u_sighting.area
	local area = self:get_area_from_nav_seg_id(nav_seg_id)
	if prev_area ~= area then
		if prev_area and not u_sighting.ai then
			if table.count(prev_area.criminal.units, function(c_data) return not c_data.ai end) <= 1 then
				prev_area.criminal_left_t = self._t
				prev_area.old_criminal_entered_t = prev_area.criminal_entered_t
				prev_area.criminal_entered_t = nil
			end

			if not area.criminal_entered_t then
				if area.criminal_left_t and area.old_criminal_entered_t then
					area.criminal_entered_t = math.lerp(area.old_criminal_entered_t, self._t, math.min((self._t - area.criminal_left_t) / 20, 1))
				else
					area.criminal_entered_t = self._t
				end
			end
		end

		if prev_area then
			prev_area.criminal.units[u_key] = nil
		end

		u_sighting.area = area
		area.criminal.units[u_key] = u_sighting
	end

	if area.is_safe then
		area.is_safe = nil
		self:_on_area_safety_status(area, {
			reason = "criminal",
			record = u_sighting
		})
	end
end)


-- Make jokers follow their actual owner instead of the closest player
local _determine_objective_for_criminal_AI_original = GroupAIStateBase._determine_objective_for_criminal_AI
function GroupAIStateBase:_determine_objective_for_criminal_AI(unit, ...)
	local logic_data = unit:brain()._logic_data
	if logic_data.is_converted and alive(logic_data.minion_owner) then
		return {
			type = "follow",
			scan = true,
			follow_unit = logic_data.minion_owner
		}
	end

	return _determine_objective_for_criminal_AI_original(self, unit, ...)
end


-- Adjust objective data for rescue and steal SOs
Hooks:PreHook(GroupAIStateBase, "add_special_objective", "sh_add_special_objective", function(self, id, objective_data)
	if type(id) ~= "string" or not id:match("^carrysteal") and not id:match("^rescue") then
		return
	end

	objective_data.interval = 4
	objective_data.search_dis_sq = 4000000
	objective_data.objective.interrupt_dis = 800
	objective_data.objective.interrupt_health = 0.8
	objective_data.objective.pose = nil
end)


-- Fully count all criminals for the balancing multiplier
function GroupAIStateBase:_get_balancing_multiplier(balance_multipliers)
	return balance_multipliers[math.clamp(table.size(self._char_criminals), 1, #balance_multipliers)]
end


-- Disable drama zones to prevent skipping of anticipation, build and regroup phases
-- The zones are only used for that, which makes the phases inconsistent for no real reason
function GroupAIStateBase:_add_drama(amount)
	self._drama_data.amount = math.clamp(self._drama_data.amount + amount, 0, 1)
	self._drama_data.zone = nil
end


-- Set a minimum gunshot and bullet impact alert range in loud
Hooks:PreHook(GroupAIStateBase, "propagate_alert", "sh_propagate_alert", function(self, alert_data)
	if alert_data[1] == "bullet" and alert_data[3] and self:enemy_weapons_hot() then
		alert_data[3] = math.max(alert_data[3], 800)
	end
end)


-- Spawn events are probably not used anywhere, but for the sake of correctness, fix this function
-- All the functions that call this expect it to return true when it's used
function GroupAIStateBase:_try_use_task_spawn_event(t, target_area, task_type, target_pos, force)
	target_pos = target_pos or target_area.pos

	local max_dis_sq = 3000 ^ 2
	for _, event_data in pairs(self._spawn_events) do
		if (event_data.task_type == task_type or event_data.task_type == "any") and mvector3.distance_sq(target_pos, event_data.pos) < max_dis_sq then
			if force or math.random() < event_data.chance then
				self._anticipated_police_force = self._anticipated_police_force + event_data.amount
				self._police_force = self._police_force + event_data.amount
				self:_use_spawn_event(event_data)
				return true
			else
				event_data.chance = math.min(1, event_data.chance + event_data.chance_inc)
			end
		end
	end
end


-- Make this function properly set rescue state again for checking if recon tasks are allowed
Hooks:OverrideFunction(GroupAIStateBase, "_set_rescue_state", function(self, state)
	self._rescue_allowed = state
end)


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
-- everything after the first "is_server" check only runs on the host, keep it at the end of this file
local upd_team_AI_distance_original = GroupAIStateBase.upd_team_AI_distance
function GroupAIStateBase:upd_team_AI_distance(...)
	if not UsefulBots.settings.hold_position and Network:is_server() then
		return upd_team_AI_distance_original(self, ...)
	end
end

if not Network:is_server() then
	return
end

local chk_say_teamAI_combat_chatter_original = GroupAIStateBase.chk_say_teamAI_combat_chatter
function GroupAIStateBase:chk_say_teamAI_combat_chatter(...)
	if UsefulBots.settings.battle_cries then
		return chk_say_teamAI_combat_chatter_original(self, ...)
	end
end

-- more accurate distance check for team ai revive SO
local _execute_so_original = GroupAIStateBase._execute_so
function GroupAIStateBase:_execute_so(so_data, so_rooms, so_administered, ...)
	local so_objective = so_data.objective
	if so_data.AI_group ~= "friendlies" then
		return _execute_so_original(self, so_data, so_rooms, so_administered, ...)
	end

	-- If someone else is reviving, ignore SO
	if so_objective.type == "revive" and alive(so_objective.follow_unit) then
		local unit = so_objective.follow_unit
		if unit:interaction() and unit:interaction()._block_revive_SO then
			return
		elseif unit:character_damage() and unit:character_damage()._downed_paused_counter and unit:character_damage()._downed_paused_counter ~= 0 then
			return
		end
	end

	local mvec_dis = mvector3.distance
	local mvec_dis_sq = mvector3.distance_sq
	local pos = so_data.search_pos
	local nav_seg = so_objective.nav_seg
	local so_access = so_data.access
	local max_dis = so_data.search_dis_sq or math.huge
	local closest_u_data, closest_dis, closest_dis_sq = nil, math.huge, math.huge
	local nav_manager = managers.navigation
	local access_f = nav_manager.check_access
	local inspire_available = so_objective.type == "revive" and managers.player:is_custom_cooldown_not_active("team", "crew_inspire")
	local inspire_u_data

	local function check_allowed(u_key, u_unit_dat)
		return (not so_administered or not so_administered[u_key]) and (so_objective.forced or u_unit_dat.unit:brain():is_available_for_assignment(so_objective)) and (not so_data.verification_clbk or so_data.verification_clbk(u_unit_dat.unit)) and access_f(nav_manager, so_access, u_unit_dat.so_access, 0)
	end

	local function get_distance(u_key, u_unit_data)
		local path = nav_manager:search_coarse({
			access_pos = u_unit_data.so_access,
			from_seg = u_unit_data.seg,
			to_seg = nav_seg,
			id = u_key
		})

		if not path or #path < 2 then
			return math.huge
		end

		local dis = 0
		local current = u_unit_data.m_pos
		for i = 2, #path do
			local nxt = path[i][2]
			if current and nxt then
				dis = dis + mvec_dis(current, nxt)
			end
			current = nxt
		end

		return dis
	end

	for u_key, u_unit_data in pairs(self._ai_criminals) do
		if check_allowed(u_key, u_unit_data) then
			local dis_sq = mvec_dis_sq(pos, u_unit_data.m_pos)
			if dis_sq < max_dis then
				if inspire_available and not inspire_u_data and dis_sq < 810000 then
					inspire_u_data = u_unit_data
				end

				local dis = get_distance(u_key, u_unit_data)
				if dis < closest_dis or dis == closest_dis and dis_sq < closest_dis_sq then
					closest_u_data = u_unit_data
					closest_dis = dis
					closest_dis_sq = dis_sq
				end
			end
		end
	end

	if closest_dis > 1000 and inspire_u_data then
		closest_u_data = inspire_u_data
	end

	if not closest_u_data then
		return
	end

	closest_u_data.unit:brain():set_objective(self.clone_objective(so_objective))
	if so_data.admin_clbk then
		so_data.admin_clbk(closest_u_data.unit)
	end

	return closest_u_data
end

-- Increase bot revive distance
Hooks:PreHook(GroupAIStateBase, "add_special_objective", "add_special_objective_ub", function(self, id, objective_data)
	if type(id) ~= "string" then
		return
	end

	local player_assist = id:match("^Playerrevive") or id:match("^PlayerHusk_revive")
	local bot_assist = id:match("^TeamAIrevive") or id:match("^TeamAIDamage_assistance")
	if not player_assist and not bot_assist then
		return
	end

	if bot_assist then
		objective_data.search_dis_sq = (UsefulBots.settings.revive_distance * 100) ^ 2
	end

	if objective_data.interval then
		objective_data.interval = math.min(4, objective_data.interval)
	end
end)

Hooks:PreHook(GroupAIStateBase, "unregister_criminal", "unregister_criminal_ub", function(self, unit)
	UsefulBots:unregister_unit(unit)
end)

if Keepers then
	return
end

-- Make bots return to their previous objective
local _determine_objective_for_criminal_AI_original = GroupAIStateBase._determine_objective_for_criminal_AI
function GroupAIStateBase:_determine_objective_for_criminal_AI(unit, ...)
	local brain = unit:brain()
	local movement = unit:movement()
	if movement._should_stay and movement._should_stay_pos then
		local pos = movement._sh_spot or movement._should_stay_pos -- patrolling bots stand at their current spot
		return {
			type = "defend_area",
			scan = true,
			pos = pos,
			nav_seg = managers.navigation:get_nav_seg_from_pos(pos)
		}
	elseif alive(brain._logic_data._latest_follow_unit) then
		return {
			type = "follow",
			scan = true,
			is_default = true,
			follow_unit = brain._logic_data._latest_follow_unit
		}
	end

	return _determine_objective_for_criminal_AI_original(self, unit, ...)
end

Hooks:PostHook(GroupAIStateBase, "unregister_criminal", "unregister_criminal_ub", function(self)
	if self:num_alive_players() == 0 then
		for _, u_data in pairs(self._ai_criminals) do
			u_data.unit:movement():set_should_stay(false)
		end
	end
end)


-- Awake bots in stealth are noticed like they normally are again once the heist goes loud (req/bot_stealth.lua)
Hooks:PostHook(GroupAIStateBase, "set_whisper_mode", "set_whisper_mode_stealth_sh", function (self, enabled)
	if enabled then
		UsefulBots.stealth:on_whisper_mode_started()
	else
		UsefulBots.stealth:on_whisper_mode_ended()
	end
end)


-- Why the heist goes loud: the reason the police is called with (camera, pager, a guard or civilian that radios it in, ...)
Hooks:PostHook(GroupAIStateBase, "on_police_called", "on_police_called_log_sh", function(self, called_reason)
	if self._sh_police_logged then
		return
	end

	self._sh_police_logged = true

	StreamHeist:log("The police was called (reason: %s)", tostring(self._called_reason or called_reason))
end)


-- Bots that do interactions: the errands, what they do on their own (req/bot_interact.lua)
Hooks:PostHook(GroupAIStateBase, "update", "sh_interact_update", function(self, t)
	if UsefulBots and UsefulBots.interact then
		UsefulBots.interact:update(t)
	end

	-- where the players have been (req/bot_nav.lua)
	if UsefulBots and UsefulBots.nav and Network:is_server() then
		pcall(UsefulBots.nav.track_humans, UsefulBots.nav, t)
	end
end)
