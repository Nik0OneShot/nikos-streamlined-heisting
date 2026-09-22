UsefulBots.nav = UsefulBots.nav or {}
local Nav = UsefulBots.nav

Nav.BAN_TIME = 90 
Nav.OBSTACLE_MARGIN = 60
Nav.LINE_MARGIN = 150
Nav.GLASS_HEIGHTS = { 100, 130, 160, 190, 220 }
Nav.MAX_ITERATIONS = 1500
Nav.SELF_CHECKS = 20

Nav.epoch = Nav.epoch or 0
Nav._bans = Nav._bans or {}
Nav._blocked = Nav._blocked or {}

local mvec3_dis = mvector3.distance

function Nav:doors_enabled()
	return UsefulBots.settings.stealth_doors ~= false and not self._failed
end

function Nav:no_smash_enabled()
	return UsefulBots.settings.stealth_no_smash ~= false
end

function Nav:now()
	return TimerManager:game():time()
end

function Nav:reset()
	self.epoch = 0
	self._bans = {}
	self._blocked = {}
	self._obbs = nil
	self._obb_epoch = nil
	self._verdicts = nil
	self._reach = nil
	self._team_mask = nil
	self._obb_failed = nil
	self._obb_logged = nil
	self._failed = nil
	self._checks = 0
	self._recheck_scheduled = nil
	self.link_epoch = 0
	self._edges = nil
	self._humans = nil
	self._throw = nil
	self._wall_logs = 0
	self._human_logged = nil
	self._walls_failed = nil
	self._visited = nil
	self._visited_n = nil
	self._visited_logged = nil
	self._track_t = nil
end

function Nav:changed(what, unit, soft)
	if soft then
		self._reach = nil
		self.link_epoch = (self.link_epoch or 0) + 1

		return
	end

	self.epoch = self.epoch + 1
	self._edges = nil
	self._humans = nil
	self._throw = nil

	if what then
		StreamHeist:log("Stealth nav: %s%s (what bots learned about shut ways is forgotten)", what, unit and alive(unit) and (" " .. tostring(unit:name())) or "")
	end
end

function Nav:live_bans()
	local t = self:now()

	for i = #self._bans, 1, -1 do
		local ban = self._bans[i]

		if t > ban.t or ban.epoch ~= self.epoch then
			table.remove(self._bans, i)

			self._verdicts = nil
			self._reach = nil
		end
	end

	return self._bans
end

function Nav:ban(pos, why)
	self:live_bans()

	table.insert(self._bans, {
		pos = mvector3.copy(pos),
		t = self:now() + self.BAN_TIME,
		epoch = self.epoch,
		why = why
	})

	if #self._bans > 24 then
		table.remove(self._bans, 1)
	end

	self._verdicts = nil
	self._reach = nil
end

local function point_segment_dis(p, a, b)
	local dx, dy = b.x - a.x, b.y - a.y
	local len_sq = dx * dx + dy * dy
	local f = len_sq > 0 and math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len_sq, 0, 1) or 0
	local x, y = a.x + dx * f, a.y + dy * f

	return math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
end

local function box_of(unit, obj_name)
	local ok, box = pcall(function()
		return unit:get_object(obj_name):oobb()
	end)

	if ok and box then
		return box
	end

	ok, box = pcall(function()
		return unit:oobb()
	end)

	if ok and box then
		return box
	end
end

function Nav:obstacle_boxes()
	if self._obb_failed then
		return {}
	end

	if self._obbs and self._obb_epoch == self.epoch then
		return self._obbs
	end

	local list = {}

	for _, data in ipairs(managers.navigation._obstacles or {}) do
		local unit = data.unit

		if alive(unit) then
			local box = box_of(unit, data.obstacle_obj_name)

			if box then
				local radius = math.huge
				local ok, center, size = pcall(function()
					return box:center(), box:size()
				end)

				if ok and center and size then
					radius = mvector3.length(size) * 0.5
				end

				table.insert(list, { obb = box, unit = unit, center = ok and center or nil, radius = radius })
			elseif not self._obb_logged then
				self._obb_logged = true

				StreamHeist:log("Stealth nav: the bounds of an obstacle are not available, shut doorways are only learned from legs that fail")
			end
		end
	end

	self._obbs = list
	self._obb_epoch = self.epoch

	return list
end

function Nav:near_obstacle(pos, margin)
	for _, entry in ipairs(self:obstacle_boxes()) do
		local ok, dis = pcall(function()
			return entry.obb:distance_to_point(pos)
		end)

		if ok and dis and dis < margin then
			return entry.unit
		end
	end
end

function Nav:door_ok(pos)
	if self._verdict_epoch ~= self.epoch or not self._verdicts then
		self._verdicts = {}
		self._verdict_epoch = self.epoch
	end

	local key = math.floor(pos.x / 20 + 0.5) .. "," .. math.floor(pos.y / 20 + 0.5) .. "," .. math.floor(pos.z / 100 + 0.5)
	local verdict = self._verdicts[key]

	if verdict == nil then
		verdict = true

		for _, ban in ipairs(self._bans) do
			if mvec3_dis(ban.pos, pos) < 100 then
				verdict = false

				break
			end
		end

		if verdict and self:near_obstacle(pos, self.OBSTACLE_MARGIN) then
			verdict = false
		end

		self._verdicts[key] = verdict
	end

	return verdict
end

function Nav:line_shut(a, b)
	for _, ban in ipairs(self:live_bans()) do
		if point_segment_dis(ban.pos, a, b) < self.LINE_MARGIN then
			return true
		end
	end

	local boxes = self:obstacle_boxes()

	if #boxes == 0 then
		return false
	end

	local sample = Vector3()
	local steps = math.max(2, math.ceil(mvec3_dis(a, b) / 150))

	for _, entry in ipairs(boxes) do
		if not entry.center or point_segment_dis(entry.center, a, b) < entry.radius + self.OBSTACLE_MARGIN then
			for i = 0, steps do
				mvector3.lerp(sample, a, b, i / steps)

				local ok, dis = pcall(function()
					return entry.obb:distance_to_point(sample)
				end)

				if ok and dis and dis < self.OBSTACLE_MARGIN then
					return true
				end
			end
		end
	end

	return false
end

function Nav:coarse_path(data, from_seg, to_seg, from_pos, to_pos, banned, plain)
	local navman = managers.navigation
	local segs = navman._nav_segments

	if not segs[from_seg] or not segs[to_seg] then
		return nil
	end

	if from_seg == to_seg then
		return { { from_seg }, { to_seg, mvector3.copy(to_pos), mvector3.copy(from_pos) } }
	end

	if not plain then
		self:live_bans()
	end

	local access = data.SO_access
	local field = navman._quad_field
	local t = self:now()

	local open = { { seg = from_seg, g = 0, f = mvec3_dis(from_pos, to_pos), pos = from_pos } }
	local best_g = { [from_seg] = 0 }
	local came = {}
	local closed = {}
	local iterations = 0

	while #open > 0 and iterations < self.MAX_ITERATIONS do
		iterations = iterations + 1

		local index = 1
		for i = 2, #open do
			if open[i].f < open[index].f then
				index = i
			end
		end

		local node = table.remove(open, index)

		if not closed[node.seg] then
			closed[node.seg] = true

			if node.seg == to_seg then
				local chain = {}
				local seg = to_seg

				while seg do
					chain[#chain + 1] = seg
					seg = came[seg] and came[seg].from
				end

				local path = { { from_seg } }

				for i = #chain - 1, 1, -1 do
					local s = chain[i]
					local entry = came[s].pos

					path[#path + 1] = { s, i == 1 and mvector3.copy(to_pos) or mvector3.copy(entry), mvector3.copy(entry) }
				end

				return path
			end

			for neighbour, doors in pairs(segs[node.seg].neighbours or {}) do
				local n_seg = segs[neighbour]

				if not closed[neighbour] and n_seg and not n_seg.disabled and (not banned or not banned[neighbour] or neighbour == to_seg) and not (access and field:is_nav_segment_blocked(neighbour, access)) then
					local entry, cost

					for _, door in ipairs(doors) do
						if type(door) ~= "number" then
							local start_pos, end_pos

							if door.x then
								start_pos, end_pos = door, door
							elseif alive(door) and not door:is_obstructed() and t > door:delay_time() and (not access or door:check_access(access, 0)) then
								local script_data = door:script_data()
								local element = script_data and script_data.element

								if element then
									start_pos, end_pos = element:value("position"), element:nav_link_end_pos()
								end
							end

							if start_pos and end_pos and (plain or self:door_ok(start_pos) and (end_pos == start_pos or self:door_ok(end_pos))) then
								local door_cost = mvec3_dis(node.pos, start_pos) + (end_pos == start_pos and 0 or mvec3_dis(start_pos, end_pos))

								if not cost or door_cost < cost then
									entry, cost = end_pos, door_cost
								end
							end
						end
					end

					if entry then
						local g = node.g + cost

						if not best_g[neighbour] or g < best_g[neighbour] then
							best_g[neighbour] = g
							came[neighbour] = { from = node.seg, pos = entry }

							table.insert(open, { seg = neighbour, g = g, f = g + mvec3_dis(entry, to_pos), pos = entry })
						end
					end
				end
			end
		end
	end

	return nil
end

function Nav:self_check(data, from_seg, to_seg, from_pos, to_pos)
	if (self._checks or 0) >= self.SELF_CHECKS then
		return
	end

	self._checks = (self._checks or 0) + 1

	if self:coarse_path(data, from_seg, to_seg, from_pos, to_pos, nil, true) then
		return
	end

	local theirs = managers.navigation:search_coarse({
		from_seg = from_seg,
		to_seg = to_seg,
		to_pos = to_pos,
		access_pos = data.SO_access,
		id = "sh_nav_check" .. tostring(data.key)
	})

	if theirs then
		self._failed = true

		StreamHeist:error("Doors and obstacles: the own route search finds no way where the game's search finds one, it is switched off until the next restart")
	end
end

function Nav:reachable(data, pos)
	local navman = managers.navigation
	local from_seg = data.unit:movement():nav_tracker():nav_segment()
	local to_seg = navman:get_nav_seg_from_pos(pos, true)

	if not from_seg or not to_seg or from_seg == to_seg then
		return true
	end

	self:live_bans()
	self._reach = self._reach or {}

	local key = from_seg .. ">" .. to_seg .. ":" .. self.epoch .. ":" .. (self.link_epoch or 0)
	local known = self._reach[key]

	if known ~= nil then
		return known
	end

	local path = self:coarse_path(data, from_seg, to_seg, data.m_pos, pos)

	if not path then
		self:self_check(data, from_seg, to_seg, data.m_pos, pos)
	end

	known = path and true or false
	self._reach[key] = known

	return known
end

function Nav:probe(pos)
	local navman = managers.navigation
	local parts = {}
	local shown = 0

	for _, entry in ipairs(navman._obstacles or {}) do
		if shown < 3 and alive(entry.unit) then
			local dis = mvec3_dis(entry.unit:position(), pos)

			if dis < 1500 then
				shown = shown + 1

				table.insert(parts, string.format("obstacle %s %.1f m", tostring(entry.unit:name()), dis / 100))
			end
		end
	end

	shown = 0

	for element in pairs(navman._nav_links or {}) do
		local start_pos = shown < 3 and element:value("position")

		if start_pos and mvec3_dis(start_pos, pos) < 600 then
			shown = shown + 1

			local link = element:nav_link()

			table.insert(parts, string.format("link %s %.1f m%s%s", tostring(element:value("so_action")), mvec3_dis(start_pos, pos) / 100, link and link:is_obstructed() and " (obstructed)" or "", self._blocked[element] and " (closed to bots: glass)" or ""))
		end
	end

	return #parts > 0 and table.concat(parts, "; ") or "nothing near"
end

function Nav:leg_failed(data, from_pos, to_pos, why)
	local navman = managers.navigation
	local pos = data.m_pos
	local from_seg = navman:get_nav_seg_from_pos(pos, true)
	local to_seg = navman:get_nav_seg_from_pos(to_pos, true)
	local path = from_seg and to_seg and from_seg ~= to_seg and self:coarse_path(data, from_seg, to_seg, pos, to_pos)
	local banned

	if path then
		local best, best_dis

		for i = 2, #path do
			local door = path[i][3]
			local dis = door and mvec3_dis(door, pos)

			if dis and (not best_dis or dis < best_dis) then
				best, best_dis = door, dis
			end
		end

		if best then
			banned = mvector3.copy(best)

			self:ban(best, why)
		end
	end

	StreamHeist:log("Stealth nav: %s did not get through (%s), at %d %d %d on the way to %d %d %d. %s. Near: %s", UsefulBots.hold:bot_name(data.unit), why, pos.x, pos.y, pos.z, to_pos.x, to_pos.y, to_pos.z, banned and string.format("The doorway at %d %d %d (%.1f m away) is left out for %d s or until a door or obstacle changes", banned.x, banned.y, banned.z, mvec3_dis(banned, pos) / 100, self.BAN_TIME) or "There is no doorway on that leg to leave out", self:probe(pos))
end

function Nav:team_mask()
	if not self._team_mask then
		local mask = 0

		for i = 1, 4 do
			mask = bit.bor(mask, managers.navigation:convert_access_flag("teamAI" .. i))
		end

		self._team_mask = mask
	end

	return self._team_mask
end

function Nav:link_glass(element)
	local from, to = element:value("position"), element:nav_link_end_pos()

	if not from or not to then
		return nil
	end

	local a, b = Vector3(), Vector3()
	local masks = { managers.slot:get_mask("bullet_impact_targets"), managers.slot:get_mask("world_geometry") }

	local heights = {}

	for _, height in ipairs(self.GLASS_HEIGHTS) do
		heights[#heights + 1] = height
	end

	local rise = to.z - from.z

	if math.abs(rise) > 250 then
		local steps = math.min(16, math.ceil(math.abs(rise) / 150))

		for step = 1, steps - 1 do
			heights[#heights + 1] = rise * step / steps
		end
	end

	for _, height in ipairs(heights) do
		mvector3.set_static(a, from.x, from.y, from.z + height)
		mvector3.set_static(b, to.x, to.y, to.z + height)

		for _, mask in ipairs(masks) do
			for _, hit in ipairs(World:raycast_all("ray", a, b, "slot_mask", mask) or {}) do
				local material = alive(hit.unit) and World:pick_decal_material(hit.unit, a, b, mask)
				local name = material and tweak_data.materials[material:key()]

				if name == "glass_breakable" then
					return string.format("%s at %d cm", tostring(hit.unit:name()), height)
				end
			end
		end
	end
end

function Nav:on_link_register(element)
	if self._restoring or not self:no_smash_enabled() then
		return
	end

	self:schedule_recheck()

	local state = managers.groupai and managers.groupai:state()

	if state and not state:whisper_mode() then
		return
	end

	local values = element._values
	local access = tonumber(values.SO_access)
	local mask = self:team_mask()

	if not access or bit.band(access, mask) == 0 then
		return
	end

	local action = tostring(values.so_action or "")
	local reason

	if action:find("window", 1, true) then
		reason = "it goes through a window (" .. action .. ")"
	end

	local glass = self:link_glass(element)

	if glass then
		reason = "glass on the way: " .. glass
	end

	if not reason then
		return
	end

	if self._blocked[element] == nil then
		self._blocked[element] = values.SO_access
	end

	local blocked = bit.band(access, bit.bnot(mask))

	values.SO_access = type(values.SO_access) == "number" and blocked or tostring(blocked)

	local start_pos = element:value("position")

	StreamHeist:log("Stealth nav: the link %s at %d %d %d is closed to the bots in stealth (%s)", action, start_pos.x, start_pos.y, start_pos.z, reason)
end

function Nav:recheck_links()
	if not self:no_smash_enabled() then
		return
	end

	local state = managers.groupai and managers.groupai:state()

	if state and not state:whisper_mode() then
		return
	end

	local navman = managers.navigation
	local closed = 0

	for element in pairs(clone(navman._nav_links or {})) do
		if self._blocked[element] == nil then
			local ok = pcall(function()
				self:on_link_register(element)

				if self._blocked[element] ~= nil and element:nav_link() then
					self._restoring = true
					navman:unregister_anim_nav_link(element)
					navman:register_anim_nav_link(element)
					self._restoring = false

					closed = closed + 1
				end
			end)

			self._restoring = false

			if not ok and not self._recheck_error_logged then
				self._recheck_error_logged = true

				StreamHeist:error("Stealth nav: a link could not be looked at again")
			end
		end
	end

	if closed > 0 then
		StreamHeist:log("Stealth nav: %d more links were closed to the bots when they were looked at again", closed)
	end
end

function Nav:schedule_recheck()
	if self._recheck_scheduled or not DelayedCalls then
		return
	end

	self._recheck_scheduled = true

	for i, delay in ipairs({ 8, 40 }) do
		DelayedCalls:Add("sh_nav_recheck_" .. i, delay, function()
			if UsefulBots and UsefulBots.nav then
				UsefulBots.nav:recheck_links()
			end
		end)
	end
end

function Nav:restore_links()
	if not next(self._blocked) then
		return
	end

	local navman = managers.navigation
	local restored = 0

	self._restoring = true

	for element, original in pairs(self._blocked) do
		local ok, err = pcall(function()
			element._values.SO_access = original

			if element:nav_link() then
				navman:unregister_anim_nav_link(element)
				navman:register_anim_nav_link(element)
			end
		end)

		if ok then
			restored = restored + 1
		else
			StreamHeist:error("Stealth nav: a link could not be given back to the bots: %s", tostring(err))
		end
	end

	self._restoring = false
	self._blocked = {}

	StreamHeist:log("Stealth nav: stealth is over, %d links are open to the bots again", restored)
end


Nav.WALL_HEIGHTS = { 30, 100, 170 }
Nav.THROW_RANGE = 1200
Nav.THROW_SEGMENT_SAMPLES = 4
Nav.VISITED_MIN = 6

function Nav:walls_enabled()
	return UsefulBots.settings.stealth_walls ~= false and not self._walls_failed
end

function Nav:track_humans(t)
	if not self:walls_enabled() then
		return
	end

	t = t or self:now()

	if self._track_t and t < self._track_t then
		return
	end

	self._track_t = t + 1
	self._visited = self._visited or {}
	self._visited_n = self._visited_n or 0

	local navman = managers.navigation

	for _, pos in ipairs(self:human_positions()) do
		local seg = navman:get_nav_seg_from_pos(pos, true)

		if seg and not self._visited[seg] then
			self._visited[seg] = true
			self._visited_n = self._visited_n + 1
		end
	end

	if self._visited_n >= (self._visited_logged or 0) + 3 or self._visited_n >= self.VISITED_MIN and not self._visited_ready then
		self._visited_logged = self._visited_n
		self._visited_ready = self._visited_n >= self.VISITED_MIN

		local total = 0

		for _ in pairs(navman._nav_segments) do
			total = total + 1
		end

		StreamHeist:log("Stealth walls: players have been in %d of %d nav segments so far%s", self._visited_n, total, self._visited_ready and ", bags are only kept in those" or "")
	end
end

function Nav:visited_list()
	if not self:walls_enabled() then
		return nil
	end

	self:track_humans()

	if (self._visited_n or 0) < self.VISITED_MIN then
		return nil
	end

	local list = {}

	for seg in pairs(self._visited) do
		local data = managers.navigation._nav_segments[seg]

		if data and not data.disabled then
			list[#list + 1] = seg
		end
	end

	return list
end

function Nav:wall_between(a, b)
	self._wall_mask = self._wall_mask or World:make_slot_mask(15)
	self._wall_from = self._wall_from or Vector3()
	self._wall_to = self._wall_to or Vector3()

	for _, height in ipairs(self.WALL_HEIGHTS) do
		mvector3.set_static(self._wall_from, a.x, a.y, a.z + height)
		mvector3.set_static(self._wall_to, b.x, b.y, b.z + height)

		local ray = World:raycast("ray", self._wall_from, self._wall_to, "slot_mask", self._wall_mask)

		if ray then
			return ray
		end
	end
end

function Nav:human_positions()
	local list = {}

	for _, u_data in pairs(managers.groupai:state():all_player_criminals()) do
		local unit = u_data.unit

		if alive(unit) and unit:movement() then
			table.insert(list, unit:movement():m_pos())
		end
	end

	return list
end

function Nav:edge_open(seg, neighbour, doors)
	self._edges = self._edges or {}

	local key = seg .. ">" .. neighbour
	local known = self._edges[key]

	if known ~= nil then
		return known
	end

	local segs = managers.navigation._nav_segments
	local from, to = segs[seg].pos, segs[neighbour].pos
	local open, blocker = false, nil

	for _, door in ipairs(doors) do
		if type(door) ~= "number" then
			local start_pos, end_pos

			if door.x then
				start_pos, end_pos = door, door
			elseif alive(door) and not door:is_obstructed() then
				local script_data = door:script_data()
				local element = script_data and script_data.element

				if element then
					start_pos, end_pos = element:value("position"), element:nav_link_end_pos()
				end
			end

			if start_pos and end_pos then
				local hit = self:wall_between(from, start_pos) or self:wall_between(end_pos, to) or start_pos ~= end_pos and self:wall_between(start_pos, end_pos)

				if not hit then
					open = true

					break
				end

				blocker = blocker or hit
			end
		end
	end

	if not open and blocker and self._wall_logs < 8 then
		self._wall_logs = self._wall_logs + 1

		local pos = blocker.position

		StreamHeist:log("Stealth walls: humans can not go from nav segment %s to %s, an invisible wall (%s) is in the way at %d %d %d", tostring(seg), tostring(neighbour), alive(blocker.unit) and tostring(blocker.unit:name()) or "?", pos.x, pos.y, pos.z)
	end

	self._edges[key] = open

	return open
end

function Nav:human_segments()
	local now = self:now()

	if self._humans and now < (self._humans_t or 0) + 1 then
		return self._humans
	end

	self._humans_t = now

	local navman = managers.navigation
	local segs = navman._nav_segments
	local anchors, parts = {}, {}

	for _, pos in ipairs(self:human_positions()) do
		local seg = navman:get_nav_seg_from_pos(pos, true)

		if seg and not anchors[seg] then
			anchors[seg] = mvector3.copy(pos)
			parts[#parts + 1] = tostring(seg)
		end
	end

	if #parts == 0 then
		return nil
	end

	table.sort(parts)

	local key = table.concat(parts, ",") .. ":" .. self.epoch
	local cache = self._humans

	if cache and cache.key == key then
		return cache
	end

	local reached, open = {}, {}

	for seg in pairs(anchors) do
		reached[seg] = true
		open[#open + 1] = seg
	end

	local head = 1

	while head <= #open do
		local seg = open[head]

		head = head + 1

		for neighbour, doors in pairs(segs[seg].neighbours or {}) do
			local n_seg = segs[neighbour]

			if not reached[neighbour] and n_seg and not n_seg.disabled and self:edge_open(seg, neighbour, doors) then
				reached[neighbour] = true
				open[#open + 1] = neighbour
			end
		end
	end

	cache = { key = key, reached = reached, anchors = anchors, count = #open }
	self._humans = cache

	if self._human_logged ~= #open then
		self._human_logged = #open

		local total = 0

		for _ in pairs(segs) do
			total = total + 1
		end

		StreamHeist:log("Stealth walls: humans can get to %d of %d nav segments from where they are (%s)", #open, total, #open < total and (total - #open) .. " are out of reach, beyond an invisible wall or closed" or "no invisible wall found, or none that the navigation goes through")
	end

	return cache
end

function Nav:human_ok(pos)
	if not self:walls_enabled() then
		return true
	end

	local ok, result = pcall(function()
		self:track_humans()

		local seg = managers.navigation:get_nav_seg_from_pos(pos, true)

		if not seg then
			return true
		end

		if (self._visited_n or 0) >= self.VISITED_MIN then
			return self._visited[seg] == true
		end

		local cache = self:human_segments()

		if not cache then
			return true
		end

		if not cache.reached[seg] then
			return false
		end

		local anchor = cache.anchors[seg]

		return not (anchor and self:wall_between(anchor, pos))
	end)

	if not ok then
		self._walls_failed = true

		StreamHeist:error("Stealth walls: the check for invisible walls failed, it is switched off until the next restart: %s", tostring(result))

		return true
	end

	return result
end

function Nav:throw_spot(bag_pos)
	if not self:walls_enabled() then
		return nil
	end

	local ok, result = pcall(function()
		self:track_humans()

		local pool

		if (self._visited_n or 0) >= self.VISITED_MIN then
			pool = self._visited
		else
			local cache = self:human_segments()

			if not cache then
				return nil
			end

			pool = cache.reached
		end

		self._throw = self._throw or {}

		local key = math.floor(bag_pos.x / 50) .. "," .. math.floor(bag_pos.y / 50) .. "," .. math.floor(bag_pos.z / 50)
		local known = self._throw[key]
		local now = self:now()

		if known then
			if known.spot and self:human_ok(known.spot) then
				return known.spot
			elseif not known.spot and now < known.t + 10 then
				return nil
			end
		end

		local navman = managers.navigation
		local segs = navman._nav_segments
		local best, best_dis

		for seg in pairs(pool) do
			if segs[seg] and mvector3.distance(segs[seg].pos, bag_pos) < self.THROW_RANGE + 2000 then
				for i = 0, self.THROW_SEGMENT_SAMPLES do
					local pos = i == 0 and segs[seg].pos or navman:find_random_position_in_segment(seg)
					local dis = pos and mvector3.distance(pos, bag_pos)

					if dis and dis <= self.THROW_RANGE and (not best_dis or dis < best_dis) and self:human_ok(pos) then
						best, best_dis = mvector3.copy(pos), dis
					end
				end
			end
		end

		self._throw[key] = { spot = best, t = now }

		return best
	end)

	if not ok then
		self._walls_failed = true

		StreamHeist:error("Stealth walls: a throw spot could not be looked for, the check is switched off until the next restart: %s", tostring(result))

		return nil
	end

	return result
end
