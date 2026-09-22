UsefulBots.hold = UsefulBots.hold or {}

local Hold = UsefulBots.hold
Hold.NET_ID = "sh_wait_hold"
Hold.MODE_PATROL = "patrol"
Hold.MODE_STATIONARY = "stationary"

Hold.POST_SAMPLES = 14 
Hold.POST_GAP = 150 
Hold.POST_DOOR = 120 
Hold.REGION_MIN_POSTS = 5 
Hold.REGION_MAX_SEGS = 6
Hold.SPOT_TOLERANCE = 130 

local mvec3_dis_sq = mvector3.distance_sq
local mvec3_dis = mvector3.distance
local tmp_vec = Vector3()

function Hold:radius()
	return UsefulBots.settings.hold_radius * 100
end

function Hold:anchor_room(movement)
	return self:region(movement)
end

function Hold:in_room(room, pos)
	if not room then
		return true
	end

	local seg = managers.navigation:get_nav_seg_from_pos(pos, true)

	if type(room) == "table" then
		return room.segs[seg] == true
	end

	return seg == room
end

function Hold:check_caches()
	if self._nav_ref ~= managers.navigation then
		self._nav_ref = managers.navigation
		self._seg_posts = {}
	end
end

function Hold:enclosure(pos)
	local mask = managers.slot:get_mask("AI_visibility")
	local from = Vector3(pos.x, pos.y, pos.z + 100)
	local to = Vector3()
	local blocked = 0

	for i = 0, 7 do
		local angle = math.rad(i * 45)

		mvector3.set_static(to, pos.x + math.cos(angle) * 350, pos.y + math.sin(angle) * 350, pos.z + 100)

		if World:raycast("ray", from, to, "slot_mask", mask, "ray_type", "ai_vision", "report") then
			blocked = blocked + 1
		end
	end

	return blocked / 8
end

function Hold:seg_posts(seg)
	self:check_caches()

	local cached = self._seg_posts[seg]
	if cached then
		return cached
	end

	local navman = managers.navigation
	local doors = navman:find_segment_doors(seg)
	local candidates = {}

	for _ = 1, self.POST_SAMPLES do
		local sample = navman:find_random_position_in_segment(seg)

		if sample then
			local cover = navman:find_cover_near_pos_1(sample, nil, 150, 0, true)
			local is_cover = cover and navman:get_nav_seg_from_pos(cover[1], true) == seg
			local pos = mvector3.copy(is_cover and cover[1] or sample)
			local near_door = false

			for _, door in ipairs(doors) do
				if mvec3_dis(door, pos) < self.POST_DOOR then
					near_door = true

					break
				end
			end

			if not near_door then
				table.insert(candidates, {
					pos = pos,
					seg = seg,
					cover = is_cover and true or false,
					score = self:enclosure(pos) + (is_cover and 0.5 or 0)
				})
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	local posts = {}

	for _, candidate in ipairs(candidates) do
		local apart = true

		for _, post in ipairs(posts) do
			if mvec3_dis(post.pos, candidate.pos) < self.POST_GAP then
				apart = false

				break
			end
		end

		if apart then
			table.insert(posts, candidate)
		end
	end

	self._seg_posts[seg] = posts

	return posts
end

function Hold:build_region(anchor)
	local navman = managers.navigation
	local main = navman:get_nav_seg_from_pos(anchor, true)
	if not main then
		return nil
	end

	local region = { main = main, segs = { [main] = true }, list = { main } }
	local count = #self:seg_posts(main)
	local radius = self:radius()

	while count < self.REGION_MIN_POSTS and #region.list < self.REGION_MAX_SEGS do
		local best, best_dis

		for _, seg in ipairs(region.list) do
			for neighbour in pairs(navman:get_nav_seg_neighbours(seg) or {}) do
				local data = navman:get_nav_seg_metadata(neighbour)

				if not region.segs[neighbour] and data and not data.disabled and data.pos then
					local dis = mvec3_dis(data.pos, anchor)

					if dis <= radius and (not best_dis or dis < best_dis) then
						best, best_dis = neighbour, dis
					end
				end
			end
		end

		if not best then
			break
		end

		region.segs[best] = true
		table.insert(region.list, best)
		count = count + #self:seg_posts(best)
	end

	return region
end

function Hold:region(movement)
	local anchor = movement._should_stay_pos

	if not UsefulBots.settings.stay_in_room or not anchor then
		return nil
	end

	self:check_caches()

	if movement._sh_region_ref ~= anchor or movement._sh_region_nav ~= self._nav_ref then
		movement._sh_region_ref = anchor
		movement._sh_region_nav = self._nav_ref

		local success, region = pcall(self.build_region, self, anchor)

		if not success then
			StreamHeist:error("Could not work out the room of a bot, it is one nav segment: %s", tostring(region))

			local main = managers.navigation:get_nav_seg_from_pos(anchor, true)
			region = main and { main = main, segs = { [main] = true }, list = { main } } or nil
		end

		movement._sh_region = region
	end

	return movement._sh_region
end

function Hold:area(movement)
	local region = self:region(movement)
	if region then
		return region
	end

	local anchor = movement._should_stay_pos
	if not anchor then
		return nil
	end

	self:check_caches()

	if movement._sh_area_ref ~= anchor or movement._sh_area_nav ~= self._nav_ref then
		movement._sh_area_ref = anchor
		movement._sh_area_nav = self._nav_ref

		local navman = managers.navigation
		local main = navman:get_nav_seg_from_pos(anchor, true)
		if not main then
			movement._sh_area = nil

			return nil
		end

		local area = { main = main, segs = { [main] = true }, list = { main } }
		local reach = self:radius() + 500
		local i = 1

		while i <= #area.list and #area.list < 10 do
			for neighbour in pairs(navman:get_nav_seg_neighbours(area.list[i]) or {}) do
				local data = navman:get_nav_seg_metadata(neighbour)

				if not area.segs[neighbour] and data and not data.disabled and data.pos and mvec3_dis(data.pos, anchor) <= reach and #area.list < 10 then
					area.segs[neighbour] = true
					table.insert(area.list, neighbour)
				end
			end

			i = i + 1
		end

		movement._sh_area = area
	end

	return movement._sh_area
end

function Hold:area_posts(movement)
	local area = self:area(movement)
	if not area then
		return {}
	end

	local anchor = movement._should_stay_pos
	local radius_sq = self:radius() ^ 2
	local posts = {}

	for _, seg in ipairs(area.list) do
		for _, post in ipairs(self:seg_posts(seg)) do
			if not anchor or mvec3_dis_sq(post.pos, anchor) <= radius_sq then
				table.insert(posts, post)
			end
		end
	end

	return posts
end

function Hold:safe_area_posts(movement)
	if self._posts_failed then
		return {}
	end

	local success, posts = pcall(self.area_posts, self, movement)

	if success then
		return posts
	end

	self._posts_failed = true
	StreamHeist:error("Posts of bots disabled until the next restart: %s", tostring(posts))

	return {}
end

function Hold:safe_seg_posts(seg)
	if self._posts_failed then
		return {}
	end

	local success, posts = pcall(self.seg_posts, self, seg)

	if success then
		return posts
	end

	self._posts_failed = true
	StreamHeist:error("Posts of bots disabled until the next restart: %s", tostring(posts))

	return {}
end

function Hold:is_taken(unit, pos)
	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local other = u_data.unit

		if other ~= unit and alive(other) then
			local other_movement = other:movement()

			if other_movement._sh_spot and mvec3_dis(other_movement._sh_spot, pos) < 150 or mvec3_dis(other_movement:m_pos(), pos) < 120 then
				return true
			end
		end
	end

	return false
end

function Hold:mark_bad_spot(movement, pos, t)
	movement._sh_bad = movement._sh_bad or {}

	table.insert(movement._sh_bad, { pos = mvector3.copy(pos), t = t + 30 })

	while #movement._sh_bad > 8 do
		table.remove(movement._sh_bad, 1)
	end
end

function Hold:is_bad_spot(movement, pos)
	local t = TimerManager:game():time()

	for _, bad in ipairs(movement._sh_bad or {}) do
		if bad.t > t and mvec3_dis(bad.pos, pos) < 150 then
			return true
		end
	end

	return false
end


function Hold:bot_name(unit)
	return managers.criminals:character_name_by_unit(unit) or "?"
end

function Hold:set_mode(movement, mode)
	movement._sh_hold_mode = mode
	movement._sh_spot = nil
	movement._sh_next_patrol_t = nil
	movement._sh_withdrawing = nil
	movement._sh_bad = nil
	movement._sh_go_count = nil
end

function Hold:reset(movement)
	self:set_mode(movement, nil)
end

function Hold:is_patrolling(data)
	if not data.is_team_ai then
		return false
	end

	if UsefulBots.sneak and UsefulBots.sneak:active_for(data.unit) then
		return false
	end

	local movement = data.unit:movement()
	return movement._should_stay and movement._should_stay_pos and movement._sh_hold_mode == self.MODE_PATROL and true or false
end

function Hold:is_withdrawing(data)
	return self:is_patrolling(data) and data.unit:character_damage():health_ratio() < UsefulBots.settings.withdraw_health
end

function Hold:on_wait_tap(unit, tap_mode)
	local mode = tap_mode == 2 and self.MODE_STATIONARY or self.MODE_PATROL

	self:set_mode(unit:movement(), mode)

	StreamHeist:log("Wait tap: %s goes into %s mode", self:bot_name(unit), mode)
end

function Hold:set_stationary(unit, commander_unit)
	if not alive(unit) then
		return
	end

	local movement = unit:movement()
	local brain = unit:brain()
	if not movement or not movement.set_should_stay or not brain then
		return
	end

	local objective = brain:objective()
	local pos

	if movement._should_stay then
		pos = objective and objective.type == "defend_area" and objective.pos or movement._should_stay_pos
	elseif alive(commander_unit) and UsefulBots:player_settings(commander_unit).stop_at_player then
		local tracker = commander_unit:movement():nav_tracker()
		pos = tracker:lost() and tracker:field_position() or tracker:position()
	end

	pos = pos or movement:m_pos()

	self:set_mode(movement, self.MODE_STATIONARY)

	movement:set_should_stay(true, pos)

	StreamHeist:log("Wait hold: %s stays at its spot", self:bot_name(unit))
end

function Hold:unhold(unit)
	if UsefulBots.settings.wait_release == false or not alive(unit) then
		return false
	end

	local movement = unit:movement()

	if not movement or not movement.should_stay or not movement:should_stay() or movement:downed() then
		return false
	end

	movement:set_should_stay(false)

	StreamHeist:log("Wait tap: %s is released and follows again", self:bot_name(unit))

	return true
end

function Hold:request_stationary(unit)
	if Network:is_server() then
		self:set_stationary(unit, managers.player:player_unit())
		return
	end

	if not LuaNetworking or not LuaNetworking.SendToPeer or not (managers.network and managers.network:session()) then
		return
	end

	local name = managers.criminals:character_name_by_unit(unit)
	if name then
		LuaNetworking:SendToPeer(1, self.NET_ID, json.encode({ name = name }))
	end
end

function Hold:receive_request(sender, data)
	local success, decoded = pcall(json.decode, data)
	if not success or type(decoded) ~= "table" or type(decoded.name) ~= "string" then
		return
	end

	local unit = managers.criminals:character_unit_by_name(decoded.name)
	if not alive(unit) then
		return
	end

	local record = managers.groupai:state():all_criminals()[unit:key()]
	if not record or not record.ai then
		return
	end

	local session = managers.network:session()
	local peer = session and session:peer(sender)
	local peer_unit = peer and peer:unit()
	if not alive(peer_unit) or mvector3.distance(peer_unit:position(), unit:position()) > 5000 then
		return
	end

	self:set_stationary(unit, peer_unit)
end

if not Hold._net_hooked then
	Hold._net_hooked = true

	Hooks:Add("NetworkReceivedData", "NetworkReceivedDataStreamHeistWaitHold", function(sender, message_id, data)
		if message_id == Hold.NET_ID and Network:is_server() then
			Hold:receive_request(sender, data)
		end
	end)
end

function Hold:find_cover_within(data, threat_pos, center, radius, room)
	local radius_sq = radius * radius
	local max_dis = math.min(radius, 800)
	local navman = managers.navigation

	local function acceptable(cover)
		return cover and mvec3_dis_sq(cover[1], center) <= radius_sq and self:in_room(room, cover[1])
	end

	if type(room) == "table" and not self._room_cover_failed then
		local success, cover = pcall(navman.find_cover_in_nav_seg_3, navman, room.segs, radius, data.m_pos, threat_pos)

		if not success then
			self._room_cover_failed = true
			StreamHeist:error("Cover search of the whole room disabled until the next restart: %s", tostring(cover))
		elseif acceptable(cover) and (not threat_pos or CopLogicAttack._verify_cover(cover, threat_pos)) then
			return cover
		end
	end

	for _, from in ipairs(room and { data.m_pos, center } or { data.m_pos }) do
		local cover = navman:find_cover_near_pos_1(from, threat_pos, max_dis, 0, false)
		if acceptable(cover) then
			return cover
		end

		cover = navman:find_cover_near_pos_1(from, threat_pos, max_dis, 0, true)
		if acceptable(cover) and (not threat_pos or CopLogicAttack._verify_cover(cover, threat_pos)) then
			return cover
		end
	end
end

function Hold:find_cover(data, threat_pos)
	local movement = data.unit:movement()
	local anchor = movement._should_stay_pos

	if anchor then
		return self:find_cover_within(data, threat_pos, anchor, self:radius(), self:anchor_room(movement))
	end
end

function Hold:update_cover(data)
	local my_data = data.internal_data
	local focus_enemy = data.attention_obj

	if not focus_enemy or not focus_enemy.nav_tracker or focus_enemy.reaction < AIAttentionObject.REACT_COMBAT then
		return false
	end

	if my_data.moving_to_cover or my_data.walking_to_cover_shoot_pos or my_data.surprised or my_data.processing_cover_path or my_data.charge_path_search_id then
		return true
	end

	local threat_pos = focus_enemy.nav_tracker:field_position()
	local movement = data.unit:movement()
	local anchor = movement._should_stay_pos
	local radius = self:radius()
	local best_cover = my_data.best_cover

	if best_cover and mvec3_dis_sq(best_cover[1][1], anchor) <= radius * radius and self:in_room(self:anchor_room(movement), best_cover[1][1]) and CopLogicAttack._verify_cover(best_cover[1], threat_pos) then
		return true
	end

	local cover = self:find_cover(data, threat_pos)
	if cover then
		local better_cover = { cover }
		CopLogicAttack._set_best_cover(data, my_data, better_cover)

		local offset_pos, yaw = CopLogicAttack._get_cover_offset_pos(data, better_cover, threat_pos)
		if offset_pos then
			better_cover[5] = offset_pos
			better_cover[6] = yaw
		end

		StreamHeist:log("%s takes cover %.1f m from its anchor", self:bot_name(data.unit), mvector3.distance(cover[1], anchor) / 100)
	else
		local movement = data.unit:movement()
		if not movement._sh_no_cover_log_t or data.t > movement._sh_no_cover_log_t then
			movement._sh_no_cover_log_t = data.t + 10
			StreamHeist:log("%s found no cover inside its area", self:bot_name(data.unit))
		end
	end

	return true
end

function Hold:pick_patrol_spot(data)
	local movement = data.unit:movement()
	local anchor = movement._should_stay_pos
	local posts = self:area_posts(movement)

	if #posts == 0 then
		return nil, 0
	end

	local extent = 0
	for _, post in ipairs(posts) do
		extent = math.max(extent, mvec3_dis(post.pos, anchor))
	end

	local min_move = math.clamp(extent * 0.5, 100, 250)

	local function pick(min_dis)
		local list, total = {}, 0

		for _, post in ipairs(posts) do
			if math.abs(post.pos.z - anchor.z) < 200 and mvec3_dis(post.pos, data.m_pos) > min_dis and not self:is_bad_spot(movement, post.pos) and not self:is_taken(data.unit, post.pos) then
				local weight = 0.3 + post.score

				table.insert(list, { pos = post.pos, weight = weight })
				total = total + weight
			end
		end

		if total > 0 then
			local roll = math.random() * total

			for _, entry in ipairs(list) do
				roll = roll - entry.weight

				if roll <= 0 then
					return entry.pos
				end
			end

			return list[#list].pos
		end
	end

	local pos = pick(min_move) or pick(min_move * 0.5)

	return pos and mvector3.copy(pos), #posts
end

function Hold:go_to(data, pos, is_new_spot)
	local movement = data.unit:movement()
	local objective = data.objective

	if is_new_spot then
		movement._sh_spot = mvector3.copy(pos)
		movement._sh_next_patrol_t = nil
	end

	objective.pos = mvector3.copy(pos)
	objective.nav_seg = managers.navigation:get_nav_seg_from_pos(pos, true)
	objective.in_place = nil
	objective.path_data = nil

	TeamAILogicBase._exit(data.unit, "travel")
end

function Hold:update_idle(data)
	if self._patrol_failed then
		return
	end

	local success, result = pcall(self.update_idle_now, self, data)

	if success then
		return result
	end

	self._patrol_failed = true
	StreamHeist:error("Patrol of bots disabled until the next restart: %s", tostring(result))
end

function Hold:update_idle_now(data)
	if not self:is_patrolling(data) or data.cool then
		return
	end

	local unit = data.unit
	local movement = unit:movement()
	local objective = data.objective
	if not objective or objective.type ~= "defend_area" or objective.forced or not objective.in_place then
		return
	end

	if data.internal_data.acting or movement:chk_action_forbidden("walk") then
		return
	end

	if unit:character_damage():health_ratio() < UsefulBots.settings.withdraw_health then
		if not movement._sh_withdrawing then
			movement._sh_withdrawing = true
			StreamHeist:log("%s is hurt, waiting for its health to regenerate", self:bot_name(unit))
		end
		return
	elseif movement._sh_withdrawing then
		movement._sh_withdrawing = nil
		StreamHeist:log("%s has regenerated, going back to its spot", self:bot_name(unit))
	end

	local area = self:area(movement)
	if area and movement._sh_area_logged ~= area then
		movement._sh_area_logged = area
		StreamHeist:log("%s patrols %d nav segment(s) with %d posts", self:bot_name(unit), #area.list, #self:area_posts(movement))
	end

	if data.path_fail_t and data.t - data.path_fail_t < 6 then
		if movement._sh_spot then
			StreamHeist:log("%s can not get to its spot, it is not used for a while", self:bot_name(unit))
			self:mark_bad_spot(movement, movement._sh_spot, data.t)
		end

		movement._sh_spot = nil
		return
	end

	local spot = movement._sh_spot or movement._should_stay_pos
	if mvec3_dis_sq(data.m_pos, spot) > self.SPOT_TOLERANCE ^ 2 then
		if movement._sh_go_t and data.t < movement._sh_go_t + 3 then
			return
		end

		movement._sh_go_t = data.t
		movement._sh_go_count = (movement._sh_go_count or 0) + 1

		if movement._sh_go_count > 3 then
			StreamHeist:log("%s does not get to its spot (%.1f m away), it stays where it is", self:bot_name(unit), mvec3_dis(data.m_pos, spot) / 100)

			self:mark_bad_spot(movement, spot, data.t)

			movement._sh_spot = mvector3.copy(data.m_pos)
			movement._sh_go_count = nil
			movement._sh_next_patrol_t = data.t + 3

			return
		end

		self:go_to(data, spot)
		return true
	end

	movement._sh_go_count = nil

	if not movement._sh_next_patrol_t then
		movement._sh_next_patrol_t = data.t + math.lerp(3, 8, math.random())
		return
	end

	if data.t < movement._sh_next_patrol_t then
		return
	end

	local new_spot, posts = self:pick_patrol_spot(data)
	if not new_spot then
		movement._sh_next_patrol_t = data.t + 4

		if not movement._sh_no_post_log_t or data.t > movement._sh_no_post_log_t then
			movement._sh_no_post_log_t = data.t + 30
			StreamHeist:log("%s has nowhere to patrol to (%d posts in its area)", self:bot_name(unit), posts or 0)
		end

		return
	end

	StreamHeist:log("%s patrols to a new spot (%.1f m from its anchor, %.1f m from here, %d posts)", self:bot_name(unit), mvector3.distance(new_spot, movement._should_stay_pos) / 100, mvec3_dis(new_spot, data.m_pos) / 100, posts)

	self:go_to(data, new_spot, true)

	return true
end
