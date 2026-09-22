UsefulBots.bag = UsefulBots.bag or {}
local Bag = UsefulBots.bag

Bag.STASH_SAMPLES = 72
Bag.STASH_MIN_MOVE = 800
Bag.STASH_GUARD_DISTANCE = 1500
Bag.STASH_CIV_DISTANCE = 800
Bag.ROUTE_SAMPLE_DISTANCE = 250
Bag.ROUTE_TIME_MARGIN = 1.5
Bag.ROUTE_BLOCK_TIME = 6
Bag.ROUTE_OBSTRUCTION_TIME = 30
Bag.ROUTE_STALL_TIME = 4
Bag.ROUTE_PROGRESS_DISTANCE = 75
Bag.ROUTE_GUARD_CLEARANCE = 1200
Bag.ROUTE_CIV_CLEARANCE = 700
Bag.ROUTE_CHECK_INTERVAL = 0.5

Bag.STALL_HINT_DELAY = 7

function Bag:stall_hint(unit, text)
	local ok, err = pcall(function()
		managers.hud:show_hint({ text = text, time = 3 })
	end)

	if not ok and not self._stall_hint_failed then
		self._stall_hint_failed = true

		StreamHeist:error("Interactions of bots: a stash hint could not be shown, this is not tried again until the next restart: %s", tostring(err))
	end
end

function Bag:request_body(unit, carry_unit, requester)
	local movement = unit:movement()

	if not alive(carry_unit) or movement._carry_unit ~= carry_unit then
		return false
	end

	self:request(unit, requester)

	local order = movement._sh_bag_order

	if not order then
		return false
	end

	order.dropoff_range = 0
	order.body = true

	if order.stash_range == 0 then
		self:drop(unit, order)
	end

	return true
end

function Bag:active(unit)
	return alive(unit) and unit:movement()._sh_bag_order ~= nil
end

function Bag:safe_update(data)
	local ok, result = pcall(self.update, self, data)
	if ok then
		return result
	end

	StreamHeist:error("Stealth bag delivery stopped for %s: %s", UsefulBots.hold:bot_name(data.unit), tostring(result))
	self:cancel(data.unit)
	return true
end

function Bag:request(unit, requester)
	local movement = unit:movement()
	local carry_unit = movement._carry_unit
	if not alive(carry_unit) then
		return
	end

	self:cancel(unit)
	local dropoff_count = ElementAreaTrigger.sh_refresh_loot_secure_triggers()
	local requester_movement = alive(requester) and requester:movement()
	local requester_tracker = requester_movement and requester_movement:nav_tracker()
	movement._sh_bag_order = {
		carry_unit = carry_unit,
		origin = mvector3.copy(movement:m_pos()),
		player_anchor = requester_tracker and mvector3.copy(requester_tracker:lost() and requester_tracker:field_position() or requester_tracker:position()) or mvector3.copy(movement:m_pos()),
		player_anchor_seg = requester_tracker and requester_tracker:nav_segment(),
		dropoff_range = UsefulBots.settings.stealth_bag_dropoff_range or 12,
		stash_range = UsefulBots.settings.stealth_bag_stash_range or 12
	}
	StreamHeist:log("Stealth bag: %s was ordered to deliver a bag (drop-off range %s, stash range %s, %d mission drop-off triggers found)", UsefulBots.hold:bot_name(unit), movement._sh_bag_order.dropoff_range == 101 and "mapwide" or tostring(movement._sh_bag_order.dropoff_range), movement._sh_bag_order.stash_range == 101 and "mapwide" or tostring(movement._sh_bag_order.stash_range), dropoff_count)
end

function Bag:cancel(unit, reason)
	if not alive(unit) then
		return
	end

	local movement = unit:movement()
	local order = movement._sh_bag_order
	if not order then
		return
	end

	movement._sh_bag_order = nil
	if reason then
		StreamHeist:log("Stealth bag: %s cancels the bag order (%s)", UsefulBots.hold:bot_name(unit), reason)
	end
	UsefulBots.sneak:release(unit)
	local brain = unit:brain()
	local objective = brain and brain:objective()
	if objective and (objective.sh_bag_order or objective.sh_bag_followup or objective.sh_route or objective.sh_evade) then
		brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(unit))
	end
end

function Bag:human_info(trigger, info)
	local nav = UsefulBots.nav

	if not nav or not info.pos or not info.bag_pos or not nav:walls_enabled() or nav:human_ok(info.pos) then
		return info
	end

	self._zone_logs = self._zone_logs or {}

	local spot = nav:throw_spot(info.bag_pos)
	local state = spot and "throw" or "none"

	if self._zone_logs[trigger] ~= state then
		self._zone_logs[trigger] = state

		if spot then
			StreamHeist:log("Stealth walls: a secure zone at %d %d %d is beyond an invisible wall, a bag is thrown into it from %d %d %d (%.1f m)", info.bag_pos.x, info.bag_pos.y, info.bag_pos.z, spot.x, spot.y, spot.z, mvector3.distance(spot, info.bag_pos) / 100)
		else
			StreamHeist:log("Stealth walls: a secure zone at %d %d %d is out of reach of the players and no spot a player has been at is within %.0f m of it, the bot goes there itself", info.bag_pos.x, info.bag_pos.y, info.bag_pos.z, nav.THROW_RANGE / 100)
		end
	end

	if not spot then
		return info
	end

	local copy = {}

	for key, value in pairs(info) do
		copy[key] = value
	end

	copy.pos = spot
	copy.thrown = true

	return copy
end

function Bag:secure_point(data, carry_unit, range_meters)
	if range_meters == 0 then
		return
	end

	local best_trigger, best_info, best_dis
	local carry_id = carry_unit:carry_data():carry_id()
	local carry_tweak = tweak_data.carry[carry_id]
	local type_tweak = carry_tweak and tweak_data.carry.types[carry_tweak.type]
	local multiplier = type_tweak and type_tweak.throw_distance_multiplier or 1
	local max_dis_sq = range_meters and range_meters < 101 and (range_meters * 100) ^ 2

	for trigger in pairs(ElementAreaTrigger.sh_loot_secure_triggers or {}) do
		local info = trigger:sh_manual_secure_info(carry_unit, data.m_pos)
		info = info and self:human_info(trigger, info)
		if info then
			local dis = mvector3.distance_sq(data.m_pos, info.pos)
			if (not max_dis_sq or dis <= max_dis_sq) and (not best_dis or dis < best_dis) then
				best_trigger, best_info, best_dis = trigger, info, dis
			end
		end
	end

	for _, points in pairs(data.secure_bag_data or {}) do
		for trigger, variants in pairs(points) do
			local info = variants[multiplier] or variants[next(variants)]
			info = info and self:human_info(trigger, info)
			if info and info.pos and info.bag_pos and info.dir and trigger:ub_can_secure_loot(carry_unit, true) and (not info.zipline_unit or alive(info.zipline_unit) and not info.zipline_unit:zipline():is_interact_blocked()) then
				local dis = mvector3.distance_sq(data.m_pos, info.pos)
				if (not max_dis_sq or dis <= max_dis_sq) and (not best_dis or dis < best_dis) then
					best_trigger, best_info, best_dis = trigger, info, dis
				end
			end
		end
	end

	return best_trigger, best_info
end

function Bag:route_observers()
	local result, seen = {}, {}
	local function add(obs)
		local key = alive(obs.unit) and obs.unit:key()
		if not key or not seen[key] then
			if key then
				seen[key] = true
			end
			table.insert(result, obs)
		end
	end

	for _, obs in ipairs(UsefulBots.sneak:observers()) do
		add(obs)
	end
	for _, obs in ipairs(UsefulBots.sneak:alerted_observers()) do
		add(obs)
	end
	return result
end

function Bag:stash_point(data, order)
	local range_meters = order.stash_range
	if range_meters == 0 then
		return
	end

	local mapwide = range_meters >= 101
	local radius = range_meters * 100
	local min_move = mapwide and self.STASH_MIN_MOVE or math.min(self.STASH_MIN_MOVE, radius * 0.5)
	local sneak = UsefulBots.sneak
	local navman = managers.navigation
	local observers = self:route_observers()
	local speed = sneak:walk_speed(data, true)
	local best, best_score
	local nav = UsefulBots.nav
	local walls = 0
	local function exposed_at(pos, t)
		for _, obs in ipairs(observers) do
			if sneak:sees(sneak:predict(obs, t or 0), pos, true) then
				return true
			end
		end
		return false
	end
	local function path_clear(from, to)
		local dis = mvector3.distance(from, to)
		local steps = math.floor(dis / 300)
		local sample = Vector3()
		for i = 1, steps do
			local fraction = i / (steps + 1)
			mvector3.lerp(sample, from, to, fraction)
			if exposed_at(sample, dis * fraction / math.max(speed, 1)) then
				return false
			end
		end
		return true
	end

	local function consider(pos)
		if not nav:human_ok(pos) then
			walls = walls + 1

			return
		end

		local travel = mvector3.distance(data.m_pos, pos)
		local moved = mvector3.distance(order.origin, pos)
		local from_player = mvector3.distance(order.player_anchor, pos)
		if moved < min_move or math.abs(pos.z - data.m_pos.z) > 500 then
			return
		end
		if not mapwide and from_player > radius + 100 then
			return
		end

		if exposed_at(pos, 0) or exposed_at(pos, 2) or exposed_at(pos, 4) or not path_clear(data.m_pos, pos) then
			return
		end

		local guard_dis = 5000
		local civ_dis = 5000
		for _, obs in ipairs(observers) do
			if obs.kind ~= "camera" then
				for _, route_pos in ipairs(obs.motion and obs.motion.route or {}) do
					local dis = mvector3.distance(route_pos, pos)
					if obs.kind == "guard" then
						guard_dis = math.min(guard_dis, dis)
					else
						civ_dis = math.min(civ_dis, dis)
					end
				end

				for _, future in ipairs({ 0, 2, 4 }) do
					local predicted = sneak:predict(obs, future)
					local dis = mvector3.distance(predicted.pos, pos)
					if obs.kind == "guard" then
						guard_dis = math.min(guard_dis, dis)
					else
						civ_dis = math.min(civ_dis, dis)
					end
				end
			end
		end

		if guard_dis < self.STASH_GUARD_DISTANCE or civ_dis < self.STASH_CIV_DISTANCE then
			return
		end

		local score = guard_dis * 2 + civ_dis + math.min(moved, 2000) * 0.5 - travel * 0.15
		if not best_score or score > best_score then
			best = mvector3.copy(pos)
			best_score = score
		end
	end

	local nav_segments
	if mapwide then
		nav_segments = {}
		for seg_id, seg in pairs(navman:get_all_nav_segments()) do
			if not seg.disabled then
				table.insert(nav_segments, seg_id)
			end
		end
	end

	if mapwide then
		local visited = nav:visited_list()

		if visited and #visited > 0 then
			nav_segments = visited
		end
	end

	for _ = 1, self.STASH_SAMPLES do
		local sample
		if mapwide and #nav_segments > 0 then
			sample = navman:find_random_position_in_segment(nav_segments[math.random(#nav_segments)])
		else
			sample = Vector3(math.random() * 2 - 1, math.random() * 2 - 1, 0)
		end
		if sample and mvector3.length(sample) > 0.01 then
			if not mapwide then
				mvector3.normalize(sample)
				mvector3.multiply(sample, radius * math.sqrt(math.random()))
				mvector3.add(sample, order.player_anchor)
			end

			local tracker = navman:create_nav_tracker(sample)
			if not tracker:lost() then
				local target_seg = tracker:nav_segment()
				local reachable

				if UsefulBots.nav:doors_enabled() then
					local ok, result = pcall(UsefulBots.nav.reachable, UsefulBots.nav, data, tracker:position())

					reachable = not ok or result
				else
					reachable = not order.player_anchor_seg or target_seg == order.player_anchor_seg or navman:search_coarse({
						from_seg = order.player_anchor_seg,
						to_seg = target_seg,
						to_pos = tracker:position(),
						access_pos = data.SO_access,
						id = "sh_bag_stash_" .. tostring(data.key)
					})
				end
				if reachable then
					consider(tracker:position())
				end
			end
			navman:destroy_nav_tracker(tracker)
		end
	end

	if walls > 0 and (not order.wall_log_t or data.t > order.wall_log_t) then
		order.wall_log_t = data.t + 10

		StreamHeist:log("Stealth bag: %s left out %d stash spots where no player has been (out of bounds)", UsefulBots.hold:bot_name(data.unit), walls)
	end

	return best
end

function Bag:route_point_safe(pos, arrival, observers)
	local sneak = UsefulBots.sneak
	observers = observers or self:route_observers()
	local times = {
		math.max(0, arrival - self.ROUTE_TIME_MARGIN),
		arrival,
		arrival + self.ROUTE_TIME_MARGIN,
		0,
		2,
		4
	}
	for _, t in ipairs(times) do
		for _, obs in ipairs(observers) do
			if sneak:sees(sneak:predict(obs, t), pos, true) then
				return false
			end
		end
	end

	local head = mvector3.copy(pos)
	mvector3.set_z(head, head.z + sneak:head_height(true))
	local visibility = managers.slot:get_mask("AI_visibility")
	for _, obs in ipairs(observers) do
		if obs.kind ~= "camera" then
			local clearance = obs.kind == "guard" and self.ROUTE_GUARD_CLEARANCE or self.ROUTE_CIV_CLEARANCE
			local positions = { obs.pos }
			for _, route_pos in ipairs(obs.motion and obs.motion.route or {}) do
				local patrol_pos = mvector3.copy(route_pos)
				mvector3.set_z(patrol_pos, patrol_pos.z + (obs.head_off or 150))
				table.insert(positions, patrol_pos)
			end

			for _, observer_pos in ipairs(positions) do
				if mvector3.distance(observer_pos, head) < clearance and not World:raycast("ray", observer_pos, head, "slot_mask", visibility, "ray_type", "ai_vision", "report") then
					return false
				end
			end
		end
	end

	return true
end

local function bag_nav_point_pos(point)
	if not point then
		return
	end
	if point.x then
		return point
	end
	if point.element then
		if point.element.nav_link_end_pos then
			return point.element:nav_link_end_pos()
		end
		return point.element:value("position")
	end
	if alive(point) and point:script_data() and point:script_data().element then
		local element = point:script_data().element
		return element.nav_link_end_pos and element:nav_link_end_pos() or element:value("position")
	end
end

function Bag:route_clear(data, target, speed)
	local objective = data.objective
	if not objective or not objective.sh_bag_order or not objective.pos or mvector3.distance_sq(objective.pos, target) > 180 ^ 2 then
		return true
	end

	local path = data.internal_data.coarse_path
	local path_i = data.internal_data.coarse_path_index
	if not path or not path_i then
		return true
	end

	local current_seg = data.unit:movement():nav_tracker():nav_segment()
	local observers = self:route_observers()
	local points = { { pos = data.m_pos, seg = current_seg } }
	local detailed = data.internal_data.advance_path
	local advancing = data.internal_data.advancing
	if advancing then
		detailed = advancing._simplified_path or advancing._nav_path or detailed
	end
	for i = 2, #(detailed or {}) do
		local point = bag_nav_point_pos(detailed[i])
		if point and mvector3.distance_sq(points[#points].pos, point) > 50 ^ 2 then
			table.insert(points, { pos = point, seg = managers.navigation:get_nav_seg_from_pos(point, true) })
		end
	end
	for i = path_i + 1, #path do
		local point = path[i] and path[i][2]
		if point and mvector3.distance_sq(points[#points].pos, point) > 50 ^ 2 then
			table.insert(points, { pos = point, seg = path[i][1] })
		end
	end
	if #points == 1 or mvector3.distance_sq(points[#points].pos, target) > 100 ^ 2 then
		table.insert(points, { pos = target, seg = objective.nav_seg })
	end

	local elapsed = 0
	local sample = Vector3()
	for i = 2, #points do
		local from = points[i - 1].pos
		local to = points[i].pos
		local distance = mvector3.distance(from, to)
		local steps = math.max(1, math.ceil(distance / self.ROUTE_SAMPLE_DISTANCE))
		for step_i = 1, steps do
			local fraction = step_i / steps
			mvector3.lerp(sample, from, to, fraction)
			local arrival = elapsed + distance * fraction / math.max(speed, 1)
			if not self:route_point_safe(sample, arrival, observers) then
				return false, mvector3.copy(sample), points[i].seg
			end
		end
		elapsed = elapsed + distance / math.max(speed, 1)
	end

	return true
end

function Bag:check_nav_seg_safe(data, nav_seg, target_seg)
	local order = data.unit:movement()._sh_bag_order
	if not order then
		return true
	end

	local current_seg = data.unit:movement():nav_tracker():nav_segment()
	if nav_seg == current_seg or nav_seg == target_seg then
		return true
	end

	local blocked_until = order.unsafe_nav_segs and order.unsafe_nav_segs[nav_seg]
	if blocked_until and data.t < blocked_until then
		return false
	end

	local segment = managers.navigation._nav_segments[nav_seg]
	if not segment then
		return false
	end
	local observers = self:route_observers()
	if segment.pos and not self:route_point_safe(segment.pos, 0, observers) then
		return false
	end

	for _, door_list in pairs(segment.neighbours or {}) do
		for _, door in ipairs(door_list) do
			local pos
			if door.x then
				pos = door
			elseif alive(door) and not door:is_obstructed() and door:script_data() and door:script_data().element then
				pos = door:script_data().element:nav_link_end_pos()
			end
			if pos then
				if not self:route_point_safe(pos, 0, observers) then
					return false
				end
			end
		end
	end

	return true
end

function Bag:nav_seg_safe(data, nav_seg, target_seg)
	local success, result = pcall(self.check_nav_seg_safe, self, data, nav_seg, target_seg)

	if success then
		return result
	end

	if not self._nav_seg_error_logged then
		self._nav_seg_error_logged = true
		StreamHeist:error("Stealth bag: the route filter failed, routes are not filtered until the next restart: %s", tostring(result))
	end

	return true
end

function Bag:stalled_segment(data, order)
	if not data.internal_data.advancing then
		order.progress_pos, order.progress_t = nil, nil
		return
	end

	if not order.progress_pos or mvector3.distance(order.progress_pos, data.m_pos) >= self.ROUTE_PROGRESS_DISTANCE then
		order.progress_pos = mvector3.copy(data.m_pos)
		order.progress_t = data.t
		return
	end
	if not order.progress_t or data.t < order.progress_t + self.ROUTE_STALL_TIME then
		return
	end

	local path = data.internal_data.coarse_path
	local path_i = data.internal_data.coarse_path_index
	local next_seg = path and path_i and path[path_i + 1] and path[path_i + 1][1]
	order.progress_pos = mvector3.copy(data.m_pos)
	order.progress_t = data.t
	return next_seg
end

function Bag:drop(unit, order)
	local movement = unit:movement()
	local carry_unit = movement._carry_unit
	if not alive(carry_unit) or carry_unit ~= order.carry_unit then
		self:cancel(unit)
		return
	end

	local info = order.info
	if order.trigger and order.trigger:ub_can_secure_loot(carry_unit, true) and info then
		local carry_data = carry_unit:carry_data()
		local zipline = info.zipline_unit
		if zipline and (not alive(zipline) or zipline:zipline():is_interact_blocked()) then
			return
		end

		order.finishing = true
		CarryData.ub_loot[carry_unit:key()] = nil
		movement._was_carrying = { unit = carry_unit }
		carry_data:unlink()
		if zipline then
			managers.network:session():send_to_peers_synched("sync_carry_data", carry_unit, carry_data:carry_id(), carry_data:multiplier(), carry_data:dye_initiated(), carry_data:has_dye_pack(), carry_data:dye_value_multiplier(), info.bag_pos, info.dir, 0, zipline, 0)
			zipline:zipline():attach_bag(carry_unit)
		else
			carry_data:set_position_and_throw(info.bag_pos, info.dir, 100)
		end
		StreamHeist:log("Stealth bag: %s delivered a bag to a loot secure point", UsefulBots.hold:bot_name(unit))
	else
		order.finishing = true
		movement:throw_bag()
		CarryData.ub_loot[carry_unit:key()] = nil
		StreamHeist:log("Stealth bag: %s left a bag in cover", UsefulBots.hold:bot_name(unit))
	end

	self:cancel(unit)
end

function Bag:note_state(data, order, state, dis, exposed, noticed)
	if order.state == state and data.t < (order.state_t or 0) + 3 then
		return
	end

	order.state, order.state_t = state, data.t

	local objective = data.objective
	local kind = objective and (objective.sh_route and "route leg" or objective.sh_evade and "evade" or (objective.sh_bag_order or objective.sh_bag_followup) and "delivery" or objective.type) or "none"
	local coarse = data.internal_data and data.internal_data.coarse_path

	StreamHeist:log((order.tag or "Stealth bag") .. ": %s: %s (%.1f m from the delivery, %s, noticed %d%%, objective: %s, coarse path: %s)", UsefulBots.hold:bot_name(data.unit), state, (dis or 0) / 100, exposed and "seen" or "not seen", (noticed or 0) * 100, kind, coarse and (#coarse .. " segments") or "none")
end

function Bag:followup_objective(data, target)
	return {
		type = "free",
		sh_bag_followup = true,
		pos = mvector3.copy(target),
		nav_seg = managers.navigation:get_nav_seg_from_pos(target, true),
		path_ahead = true,
		pose = "crouch"
	}
end

function Bag:evade(data, order, spot, target, crouch)
	local sneak = UsefulBots.sneak

	sneak:hold_still(data, false)
	sneak:set_crouch_walk(data, crouch and true or false)

	order.hide_spot = mvector3.copy(spot)
	order.wait_until = nil

	data.brain:set_objective({
		type = "free",
		pos = mvector3.copy(spot),
		nav_seg = managers.navigation:get_nav_seg_from_pos(spot, true),
		haste = crouch and nil or "run",
		pose = crouch and "crouch" or "stand",
		sh_evade = true,
		followup_objective = self:followup_objective(data, target)
	})
end

function Bag:update_routed(data, order, target, dis, exposed)
	local unit = data.unit
	local sneak = UsefulBots.sneak
	local st = unit:movement()._sh_sneak
	local name = UsefulBots.hold:bot_name(unit)
	local objective = data.objective

	local was_stalled = order.stall_kind

	order.stall_kind = nil

	if sneak._routes_failed or order.legacy_until and data.t < order.legacy_until then
		return nil
	end

	if not order.noticed_t or data.t >= order.noticed_t then
		order.noticed_t = data.t + 0.1
		order.noticed = sneak:notice_progress(unit)
	end

	local noticed = order.noticed

	local rising = order.previous_noticed and noticed > order.previous_noticed + 0.005

	order.previous_noticed = noticed

	if st.route and not st.route.forced and noticed > 0.01 then
		local expected = st.route.expected[math.min(st.route.i, #st.route.expected)] or 0

		if noticed > expected + sneak.BAG_ROUTE_TOLERANCE and (rising or sneak:exposed(data.m_pos, unit:anim_data().crouch and true or false)) then
			sneak:abort_route(data, st, string.format("noticed %d%%, the plan said %d%% at most, a bag carrier gives up at %d points more", noticed * 100, expected * 100, sneak.BAG_ROUTE_TOLERANCE * 100))

			objective = data.objective
			exposed = true
			order.next_hide_t = nil
		end
	end

	local function delivery_objective()
		local current = data.objective

		if current and (current.sh_bag_followup or current.sh_bag_order) then
			return current
		end

		return self:followup_objective(data, target)
	end

	if objective and objective.sh_route then
		sneak:watch_route(data)

		if st.route then
			self:note_state(data, order, string.format("walking leg %d of %d of a route", st.route.i, #st.route.pts), dis, exposed, noticed)

			return false
		end

		objective = data.objective

		if st.retreat_to then
			exposed = true
			order.next_hide_t = nil
		end
	end

	if objective and objective.sh_evade then
		self:note_state(data, order, "sprinting to a hiding place", dis, exposed, noticed)

		return false
	end

	if order.hide_spot then
		local arrived = mvector3.distance(data.m_pos, order.hide_spot) < 250

		order.hide_spot = nil

		if arrived then
			order.wait_until = data.t + sneak.HIDE_MIN_T

			StreamHeist:log((order.tag or "Stealth bag") .. ": %s is in its hiding place, it waits %d s before it looks for a way again", name, sneak.HIDE_MIN_T)
		end
	end

	if st.route then
		local reason

		if not order.deviation_t or data.t >= order.deviation_t then
			order.deviation_t = data.t + 0.3
			reason = sneak:route_deviation(st, noticed, data.t)
		end

		if reason then
			sneak:abort_route(data, st, reason)

			exposed = true
			order.next_hide_t = nil
		else
			if sneak:drive_route(data, st, delivery_objective()) ~= nil then
				return true
			end

			dis = mvector3.distance(data.m_pos, target)

			if dis < 180 and not exposed then
				return true
			end
		end
	end

	if not exposed then
		st.pushed = nil
	end

	if exposed and (not order.next_hide_t or data.t >= order.next_hide_t) then
		order.next_hide_t = data.t + 1

		if not st.pushed and sneak:try_routes(data, st, target, sneak.NOTICE_CUTOFF, delivery_objective(), false, true) then
			StreamHeist:log((order.tag or "Stealth bag") .. ": %s is seen, takes a route on to the delivery instead of hiding", name)

			return true
		end

		local retreat = st.retreat_to
		st.retreat_to = nil

		local spot, hidden, retreating

		if retreat and mvector3.distance(data.m_pos, retreat) >= 180 and sneak:retreat_ok(data, retreat) then
			spot, hidden, retreating = retreat, false, true
		end

		if not spot then
			local force = noticed > 0.05 and not sneak:exposed(data.m_pos, true)

			if force then
				st.bad_spots = st.bad_spots or {}
				table.insert(st.bad_spots, mvector3.copy(data.m_pos))

				if #st.bad_spots > 6 then
					table.remove(st.bad_spots, 1)
				end
			end

			spot, hidden = sneak:find_hidden_spot(data, false, force, st.bad_spots, not retreat and target or nil)
		end

		if spot and not hidden then
			StreamHeist:log((order.tag or "Stealth bag") .. ": %s is seen (noticed %d%%), sprints to %s %.1f m away", name, noticed * 100, retreating and "the spot it left" or "a hiding place", mvector3.distance(spot, data.m_pos) / 100)

			self:evade(data, order, spot, target)

			return true
		end

		if not spot then
			st.plan_t = data.t + sneak.PLAN_COOLDOWN

			local started = sneak:try_routes(data, st, target, 1, delivery_objective(), true)

			if started then
				StreamHeist:log((order.tag or "Stealth bag") .. ": %s is being noticed and has nowhere to hide, it goes on to the delivery", name)

				return true
			end
		end
	end

	if order.wait_until and data.t < order.wait_until then
		sneak:set_pose(data, true)
		sneak:sync_attention(data)
		sneak:hold_still(data, true)
		self:note_state(data, order, "waiting in its hiding place", dis, exposed, noticed)

		return true
	end

	if not st.plan_t or data.t >= st.plan_t then
		st.plan_t = data.t + sneak.PLAN_COOLDOWN
		st.blocked_t = st.blocked_t or data.t

		local started, why = sneak:try_routes(data, st, target, UsefulBots.settings.stealth_dash_limit or sneak.DASH_LIMIT, delivery_objective())

		if started then
			st.blocked_t = nil
			order.nopath_hinted = false

			return true
		end

		if why == "nopath" then
			if not order.nopath_hinted then
				order.nopath_hinted = true

				self:stall_hint(unit, "NO PLACE TO STASH BAG - MAP GEOMETRY IN THE WAY")
			end

			if order.trigger and UsefulBots.nav:doors_enabled() then
				order.unreachable_epoch = UsefulBots.nav.epoch
				order.trigger, order.info, order.target = nil, nil, nil
				order.hide_spot, order.wait_until, order.next_stash_search_t = nil, nil, nil

				StreamHeist:log((order.tag or "Stealth bag") .. ": %s has no way to the drop-off that it may take (a shut door, or nothing that does not smash glass), it leaves the bag in cover instead", name)

				return true
			end

			order.legacy_until = data.t + 5

			StreamHeist:log((order.tag or "Stealth bag") .. ": %s could not plan a route (the nav mesh has no way to the delivery from here), it goes on the old way for a while", name)

			return nil
		end
	end

	if st.last_hide and mvector3.distance(data.m_pos, st.last_hide) > 300 and (not st.retreat_t or data.t > st.retreat_t) then
		st.retreat_t = data.t + 3

		if sneak:retreat_ok(data, st.last_hide) then
			StreamHeist:log((order.tag or "Stealth bag") .. ": %s has no route it can take unseen, it goes back to the spot it left (%.1f m)", name, mvector3.distance(data.m_pos, st.last_hide) / 100)

			self:evade(data, order, st.last_hide, target)

			return true
		end
	end

	order.stall_kind = "no_safe_route"

	if was_stalled ~= "no_safe_route" then
		order.stall_since = data.t
		order.stall_hinted = false
	end

	if not order.stall_hinted and data.t - order.stall_since >= self.STALL_HINT_DELAY then
		order.stall_hinted = true

		self:stall_hint(unit, "NO PLACE TO STASH BAG - ALL ROUTES ARE UNSAFE")
	end

	sneak:set_pose(data, true)
	sneak:sync_attention(data)
	sneak:hold_still(data, true)
	self:note_state(data, order, st.last_plan and string.format("waiting, no route is safe enough (the best: %s, %d%%)", st.last_plan.label, st.last_plan.peak * 100) or "waiting for the next plan", dis, exposed, noticed)

	return true
end

function Bag:update(data)
	local unit = data.unit
	local movement = unit:movement()
	local order = movement._sh_bag_order
	if not order then
		return
	end

	if not UsefulBots.stealth:holds_fire(unit) or movement._carry_unit ~= order.carry_unit or not alive(order.carry_unit) then
		self:cancel(unit)
		return
	end

	if order.trigger and not order.trigger:ub_can_secure_loot(order.carry_unit, true) then
		order.trigger, order.info, order.target = nil, nil, nil
	end

	if data.objective and (data.objective.forced or data.objective.type == "revive") then
		return false
	end

	local defense_changed = UsefulBots.melee:update(data)
	local defense_objective = data.objective
	if defense_changed then
		return true
	end
	if movement._sh_engaged and data.t < movement._sh_engaged or defense_objective and (defense_objective.sh_charge or defense_objective.sh_flank) then
		return false
	end

	local sneak = UsefulBots.sneak
	if not movement._sh_sneak or movement._sh_sneak.kind ~= "bag" then
		sneak:release(unit)
		movement._sh_sneak = { kind = "bag" }
	end

	if not order.next_secure_t or data.t >= order.next_secure_t then
		order.next_secure_t = data.t + 0.5

		local secure_trigger, secure_info

		if order.unreachable_epoch ~= UsefulBots.nav.epoch then
			order.unreachable_epoch = nil
			secure_trigger, secure_info = self:secure_point(data, order.carry_unit, order.dropoff_range)
		end
		if secure_trigger and (order.trigger ~= secure_trigger or not order.info or mvector3.distance_sq(order.info.pos, secure_info.pos) > 100 ^ 2) then
			order.trigger = secure_trigger
			order.info = secure_info
			order.target = mvector3.copy(secure_info.pos)
			order.detour = nil
			order.wait_until = nil
			StreamHeist:log("Stealth bag: %s prioritizes a loot secure point", UsefulBots.hold:bot_name(unit))
		end
	end

	if not order.target then
		if order.next_stash_search_t and data.t < order.next_stash_search_t then
			sneak:hold_still(data, true)
			return true
		end

		order.next_stash_search_t = data.t + 2
		order.target = self:stash_point(data, order)
		if not order.target then
			if not order.no_stash_logged then
				order.no_stash_logged = true
				StreamHeist:log("Stealth bag: %s found no stash away from patrols and waits", UsefulBots.hold:bot_name(unit))
			end

			order.stall_kind = "no_spot"

			if was_stalled ~= "no_spot" then
				order.stall_since = data.t
				order.stall_hinted = false
			end

			if not order.stall_hinted and data.t - order.stall_since >= self.STALL_HINT_DELAY then
				order.stall_hinted = true

				self:stall_hint(unit, "NO PLACE TO STASH BAG - NO VALID SPOT FOUND")
			end

			sneak:hold_still(data, true)
			return true
		end
	end

	local target = order.detour or order.target
	local dis = mvector3.distance(data.m_pos, target)

	if not order.check_t or data.t >= order.check_t then
		order.check_t = data.t + 0.2
		order.exposed = sneak:exposed(data.m_pos, true) or sneak:notice_progress(unit) > 0.01
		order.crouch = sneak:observer_near(data.m_pos, sneak.CROUCH_RANGE) or sneak:guard_close(data)
	end

	local exposed = order.exposed

	if dis < 180 then
		if order.detour then
			order.detour = nil
			order.wait_until = data.t + sneak.HIDE_MIN_T
		elseif not exposed and (not order.wait_until or data.t >= order.wait_until) then
			self:drop(unit, order)
			return true
		end
	end

	if UsefulBots.settings.stealth_routes and not sneak._routes_failed then
		local routed = sneak:safe_route("bag delivery", function(_, ...)
			return self:update_routed(...)
		end, data, order, target, dis, exposed)

		if routed ~= nil then
			return routed
		end
	end

	local dashing = order.dash_until and data.t < order.dash_until
	local walking_on = order.walk_ok_until and data.t < order.walk_ok_until

	if exposed and not order.detour and not dashing and not walking_on then
		local noticed = sneak:notice_progress(unit)
		local searching = not order.next_hide_t or data.t >= order.next_hide_t
		local spot

		if searching then
			order.next_hide_t = data.t + 1

			spot = sneak:find_hidden_spot(data, false, true, nil, target)
		end

		if spot and mvector3.distance_sq(spot, data.m_pos) > 180 ^ 2 then
			order.detour = spot
			order.blocked_t = nil
			target = spot
			dis = mvector3.distance(data.m_pos, target)

			if noticed > 0.05 then
				order.dash_until = data.t + dis / sneak:run_speed(data) + 0.5
				dashing = true
			end

			StreamHeist:log("Stealth bag: %s is seen and goes to a hidden spot %.1f m away%s", UsefulBots.hold:bot_name(unit), dis / 100, dashing and " at a run, it is being noticed" or "")
		elseif searching then
			order.blocked_t = order.blocked_t or data.t

			local waited = data.t - order.blocked_t
			local limit = math.min(sneak.LIMIT_MAX, (UsefulBots.settings.stealth_dash_limit or sneak.DASH_LIMIT) + math.min(sneak.PATIENCE_MAX, waited * sneak.PATIENCE_RATE))
			local way, hop = sneak:safe_hop(data, target, limit, 2500)

			if way == "walk" then
				order.walk_ok_until = data.t + 1.2
				walking_on = true
			elseif way == "dash" then
				order.dash_until = data.t + hop / sneak:run_speed(data) + 0.5
				order.blocked_t = nil
				dashing = true
			elseif noticed > 0.05 then
				order.dash_until = data.t + 2
				dashing = true

				StreamHeist:log("Stealth bag: %s is being noticed and has nowhere to hide, it runs on to the delivery", UsefulBots.hold:bot_name(unit))
			elseif hop and hop.obs and (not order.wait_log_t or data.t > order.wait_log_t) then
				order.wait_log_t = data.t + 3

				StreamHeist:log("Stealth bag: %s waits (%.0f s), %s %.1f m away would get to %d%% with noticing it during a dash of %.1f m (limit %d%%)", UsefulBots.hold:bot_name(unit), waited, hop.obs.kind, mvector3.distance(hop.obs.pos, data.m_pos) / 100, hop.peak * 100, hop.dis / 100, limit * 100)
			end
		end

		if not order.detour and not dashing and not walking_on then
			self:note_state(data, order, "seen, no hiding place and no safe move, standing still", dis, exposed, noticed)
			sneak:set_pose(data, true)
			sneak:sync_attention(data)
			sneak:hold_still(data, true)
			return true
		end
	end

	local crouch = order.crouch and not dashing
	sneak:set_pose(data, crouch)
	sneak:sync_attention(data)
	sneak:set_crouch_walk(data, crouch)

	if dis < 180 or order.wait_until and data.t < order.wait_until then
		self:note_state(data, order, dis < 180 and "at the delivery, waiting until it is not seen" or "waiting in its hiding place", dis, exposed)
		sneak:hold_still(data, true)
		return true
	end

	local stalled_seg = self:stalled_segment(data, order)
	if stalled_seg and data.objective and stalled_seg ~= data.objective.nav_seg then
		order.unsafe_nav_segs = order.unsafe_nav_segs or {}
		order.unsafe_nav_segs[stalled_seg] = data.t + self.ROUTE_OBSTRUCTION_TIME
		sneak:hold_still(data, true)
		data.brain:set_objective({
			type = "free",
			sh_bag_order = true,
			pos = mvector3.copy(target),
			nav_seg = managers.navigation:get_nav_seg_from_pos(target, true),
			path_ahead = true,
			haste = not crouch and "run" or nil,
			pose = crouch and "crouch" or "stand"
		})
		StreamHeist:log("Stealth bag: %s could not traverse its route and searches around the obstruction", UsefulBots.hold:bot_name(unit))
		return true
	end

	local speed = sneak:walk_speed(data, true)
	local route_clear, unsafe_seg = true
	local checked = false
	if not order.next_route_check_t or data.t >= order.next_route_check_t then
		checked = true
		order.next_route_check_t = data.t + self.ROUTE_CHECK_INTERVAL
		local unsafe_pos
		route_clear, unsafe_pos, unsafe_seg = self:route_clear(data, target, speed)
	end

	if checked then
		if route_clear then
			order.route_reject_since = nil
		else
			order.route_reject_since = order.route_reject_since or data.t

			local waited = data.t - order.route_reject_since - 6

			if waited > 0 and not dashing then
				local limit = math.min(sneak.LIMIT_MAX, (UsefulBots.settings.stealth_dash_limit or sneak.DASH_LIMIT) + math.min(sneak.PATIENCE_MAX, waited * sneak.PATIENCE_RATE))
				local way, hop = sneak:safe_hop(data, target, limit, 2500)

				if way then
					order.dash_until = data.t + (way == "dash" and hop / sneak:run_speed(data) + 0.5 or 1.2)
					order.route_reject_since = nil
					route_clear = true
					dashing = way == "dash"

					StreamHeist:log("Stealth bag: %s goes on, no other route (%s)", UsefulBots.hold:bot_name(unit), way)
				end
			end
		end
	end

	if dashing then
		crouch = false
		sneak:set_pose(data, false)
		sneak:sync_attention(data)
		sneak:set_crouch_walk(data, false)
	end

	if not route_clear and not dashing then
		order.unsafe_nav_segs = order.unsafe_nav_segs or {}
		if unsafe_seg and unsafe_seg ~= data.objective.nav_seg then
			order.unsafe_nav_segs[unsafe_seg] = data.t + self.ROUTE_BLOCK_TIME
		end

		sneak:hold_still(data, true)
		data.brain:set_objective({
			type = "free",
			sh_bag_order = true,
			pos = mvector3.copy(target),
			nav_seg = managers.navigation:get_nav_seg_from_pos(target, true),
			path_ahead = true,
			haste = not crouch and "run" or nil,
			pose = crouch and "crouch" or "stand"
		})
		if not order.route_blocked_t or data.t > order.route_blocked_t + 2 then
			order.route_blocked_t = data.t
			StreamHeist:log("Stealth bag: %s rejects an observed route and searches for another", UsefulBots.hold:bot_name(unit))
		end
		return true
	end

	sneak:hold_still(data, false)
	local objective = data.objective
	if not objective or not objective.sh_bag_order or mvector3.distance_sq(objective.pos, target) > 180 ^ 2 then
		order.objective_sets = (order.objective_sets or 0) + 1

		if order.objective_sets >= 3 and (not order.set_log_t or data.t > order.set_log_t) then
			order.set_log_t = data.t + 3

			StreamHeist:log("Stealth bag: %s had its delivery objective set %d times, the game may keep dropping it (no path through the segments the route filter allows?)", UsefulBots.hold:bot_name(unit), order.objective_sets)
		end

		data.brain:set_objective({
			type = "free",
			sh_bag_order = true,
			pos = mvector3.copy(target),
			nav_seg = managers.navigation:get_nav_seg_from_pos(target, true),
			path_ahead = true,
			haste = not crouch and "run" or nil,
			pose = crouch and "crouch" or "stand"
		})
		return true
	end

	objective.haste = not crouch and "run" or nil
	objective.pose = crouch and "crouch" or "stand"
	order.objective_sets = 0
	self:note_state(data, order, not crouch and "running to the delivery (old way)" or "walking to the delivery (old way)", dis, exposed)
	return false
end
