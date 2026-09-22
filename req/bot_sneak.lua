UsefulBots.sneak = UsefulBots.sneak or {}

local Sneak = UsefulBots.sneak

Sneak.OBSERVER_RANGE = 4000
Sneak.GUARD_NEAR = 1200
Sneak.GUARD_FAR = 2500
Sneak.CROUCH_RANGE = 2500
Sneak.SAMPLES = 24
Sneak.SETTLE_T = 3
Sneak.DASH_STEP = 0.1
Sneak.DASH_TAIL = 1
Sneak.DASH_LIMIT = 0.5
Sneak.WALK_LIMIT = 0.25
Sneak.HOP_STEPS = { 1800, 1200, 800, 500 }
Sneak.PATIENCE_RATE = 0.04
Sneak.PATIENCE_MAX = 0.25
Sneak.LIMIT_MAX = 0.85
Sneak.PLAN_ROUTES = 5
Sneak.PLAN_STEP = 0.25
Sneak.PLAN_HORIZON = 3000
Sneak.PLAN_COOLDOWN = 2.5
Sneak.ROUTE_LIMIT = 0.35
Sneak.NOTICE_CUTOFF = 0.35
Sneak.ROUTE_TOLERANCE = 0.12
Sneak.BAG_ROUTE_TOLERANCE = 0.03
Sneak.SPRINT_LIMIT = 0.05
Sneak.ROUTE_HEAD_MARGIN = 15
Sneak.ROUTE_START_DELAY = 1.1
Sneak.ROUTE_STALL_TIME = 3.5
Sneak.ROUTE_TIME_MARGIN = { -1, 1.5 }
Sneak.PREDICT_MAX = 12
Sneak.LOOKAHEAD_T = 1
Sneak.HIDE_MIN_T = 3
Sneak.HIDE_ALERT_DIS = 2500
Sneak.HIDE_ROUTE = 1500
Sneak.HEAD_STAND = 160
Sneak.HEAD_CROUCH = 110

local mvec3_dis = mvector3.distance
local mvec3_dis_sq = mvector3.distance_sq
local tmp_vec1 = Vector3()
local tmp_vec2 = Vector3()
local tmp_vec3 = Vector3()

function Sneak:safe(name, func, ...)
	if self._failed then
		return
	end

	local success, result = pcall(func, self, ...)
	if not success then
		self._failed = true
		StreamHeist:error("Stealth behavior of bots disabled until the next restart, error in %s: %s", name, tostring(result))
		return
	end

	return result
end

function Sneak:bot_name(unit)
	return UsefulBots.hold:bot_name(unit)
end

function Sneak:active_for(unit)
	if self._failed or not UsefulBots.settings.stealth_wait then
		return false
	end

	local base = alive(unit) and unit:base()
	if not base or not base._sh_stealth_awake then
		return false
	end

	local movement = unit:movement()
	if not movement._should_stay or not movement._should_stay_pos or movement._sh_hold_mode ~= UsefulBots.hold.MODE_PATROL then
		return false
	end

	if not UsefulBots.stealth:enabled() or not managers.groupai:state():whisper_mode() then
		return false
	end

	return not UsefulBots.stealth:is_loud_bound()
end

function Sneak:detection_of(unit)
	local brain = unit:brain()
	local logic_data = brain and brain._logic_data
	if not logic_data then
		return
	end

	local detection = logic_data.internal_data and logic_data.internal_data.detection
	if detection and detection.dis_max then
		return detection
	end

	local tweak = logic_data.char_tweak and logic_data.char_tweak.detection
	detection = tweak and (tweak.idle or tweak.ntl)

	return detection and detection.dis_max and detection or nil
end

local pred = {}
local pred_pos = Vector3()
local pred_fwd = Vector3()

local function segment_dis_sq(p, a, b)
	local abx, aby = b.x - a.x, b.y - a.y
	local len_sq = abx * abx + aby * aby
	local f = len_sq > 0 and math.clamp(((p.x - a.x) * abx + (p.y - a.y) * aby) / len_sq, 0, 1) or 0
	local dx, dy = a.x + abx * f - p.x, a.y + aby * f - p.y

	return dx * dx + dy * dy
end

function Sneak:motion_of(unit)
	local movement = unit:movement()
	local walk = movement._active_actions and movement._active_actions[2]

	if not walk or not walk.type or walk:type() ~= "walk" or walk._expired then
		return nil
	end

	local path = walk._simplified_path
	if not path or #path < 2 then
		return nil
	end

	local points = {}
	for _, point in ipairs(path) do
		local pos = point.x and point or point.element and point.element:value("position")
		if not pos then
			return nil
		end

		table.insert(points, mvector3.copy(pos))
	end

	local pos = movement:m_pos()
	local best, best_dis_sq

	for i = 1, #points - 1 do
		local dis_sq = segment_dis_sq(pos, points[i], points[i + 1])

		if not best_dis_sq or dis_sq < best_dis_sq then
			best, best_dis_sq = i, dis_sq
		end
	end

	local route = { mvector3.copy(pos) }
	for i = best + 1, #points do
		table.insert(route, points[i])
	end

	local speed = walk._cur_vel
	if not speed or speed < 20 then
		speed = 150
	end

	return { route = route, speed = speed }
end

function Sneak:position_at(motion, t, out_pos, out_fwd, head_off)
	local route = motion.route
	local dis = motion.speed * t

	for i = 1, #route - 1 do
		local a, b = route[i], route[i + 1]
		local len = mvec3_dis(a, b)

		if dis <= len or i == #route - 1 then
			mvector3.lerp(out_pos, a, b, len > 0 and math.min(dis / len, 1) or 0)
			mvector3.set_z(out_pos, out_pos.z + head_off)

			mvector3.set(out_fwd, b)
			mvector3.subtract(out_fwd, a)
			mvector3.set_z(out_fwd, 0)

			if mvector3.length(out_fwd) > 0.01 then
				mvector3.normalize(out_fwd)
			end

			return
		end

		dis = dis - len
	end
end

function Sneak:predict(obs, t)
	if not obs.motion or t <= 0 then
		return obs
	end

	self:position_at(obs.motion, math.min(t, self.PREDICT_MAX), pred_pos, pred_fwd, obs.head_off)

	pred.kind, pred.det, pred.unit = obs.kind, obs.det, obs.unit
	pred.pos, pred.fwd = pred_pos, pred_fwd

	return pred
end

function Sneak:guard_observer(unit)
	local detection = self:detection_of(unit)
	if not detection then
		return
	end

	local movement = unit:movement()

	return {
		kind = "guard",
		unit = unit,
		pos = mvector3.copy(movement:m_head_pos()),
		fwd = movement:m_head_rot():z(),
		det = detection,
		motion = self:motion_of(unit),
		head_off = movement:m_head_pos().z - movement:m_pos().z
	}
end

function Sneak:with_extra_observers(extra, func)
	local list = {}

	for _, obs in ipairs(self:observers()) do
		table.insert(list, obs)
	end

	for _, obs in ipairs(extra) do
		table.insert(list, obs)
	end

	local previous = self._obs_override
	self._obs_override = list

	local success, result = pcall(func)
	self._obs_override = previous

	if not success then
		error(result, 0)
	end

	return result
end

function Sneak:camera_off_reason(unit, base, ecm)
	if not base or base.destroyed and base:destroyed() then
		return "destroyed"
	end

	if not unit:enabled() then
		return "switched off"
	end

	if base._alarm_sound then
		return "sounding its alarm"
	end

	if not (base._detection_delay and base._pos and base._look_fwd and base._range and base._cone_angle) then
		return "its detection is off"
	end

	if ecm then
		return "jammed by an ECM"
	end

	if base._tape_loop_expired_clbk_id or base._tape_loop_restarting_t then
		return "looped"
	end
end

function Sneak:note_camera(unit, off)
	if self._cam_nav ~= managers.navigation then
		self._cam_nav = managers.navigation
		self._cam_state = {}
	end

	local key = alive(unit) and unit:key() or unit
	local state = self._cam_state[key]

	if not off then
		if state == false then
			StreamHeist:log("Stealth: a camera watches again")
		end

		self._cam_state[key] = true
	elseif state == true then
		self._cam_state[key] = false

		StreamHeist:log("Stealth: a camera does not watch anymore (%s), the bots ignore it", off)
	end
end

function Sneak:camera_sweep(unit, fwd)
	self._sweeps = self._sweeps or {}

	local yaw = math.deg(math.atan2(fwd.y, fwd.x))
	local sweep = self._sweeps[unit:key()]

	if not sweep then
		sweep = { base = yaw, min = 0, max = 0, rel = 0 }
		self._sweeps[unit:key()] = sweep
	end

	local rel = (yaw - sweep.base + 180) % 360 - 180

	sweep.rel = rel
	sweep.min = math.min(sweep.min, rel)
	sweep.max = math.max(sweep.max, rel)

	return sweep
end

function Sneak:observers()
	if self._obs_override then
		return self._obs_override
	end

	local t = TimerManager:game():time()
	if self._obs and t < self._obs_t + 0.25 then
		local stale

		for _, obs in ipairs(self._obs) do
			if not alive(obs.unit) then
				stale = true

				break
			end
		end

		if not stale then
			return self._obs
		end
	end

	local list = {}

	for _, u_data in pairs(managers.enemy:all_enemies()) do
		local unit = u_data.unit

		if alive(unit) and unit:movement():cool() then
			local damage_ext = unit:character_damage()
			local detection = (not damage_ext or not damage_ext:dead()) and self:detection_of(unit)

			if detection then
				table.insert(list, {
					kind = "guard",
					unit = unit,
					pos = mvector3.copy(unit:movement():m_head_pos()),
					fwd = unit:movement():m_head_rot():z(),
					det = detection,
					motion = self:motion_of(unit),
					head_off = unit:movement():m_head_pos().z - unit:movement():m_pos().z
				})
			end
		end
	end

	for _, u_data in pairs(managers.enemy:all_civilians()) do
		local unit = u_data.unit

		if alive(unit) and unit:movement():cool() and not unit:anim_data().hands_tied then
			local damage_ext = unit:character_damage()
			local detection = (not damage_ext or not damage_ext:dead()) and self:detection_of(unit)

			if detection then
				table.insert(list, {
					kind = "civilian",
					unit = unit,
					pos = mvector3.copy(unit:movement():m_head_pos()),
					fwd = unit:movement():m_head_rot():z(),
					det = detection,
					motion = self:motion_of(unit),
					head_off = unit:movement():m_head_pos().z - unit:movement():m_pos().z
				})
			end
		end
	end

	local ecm = managers.groupai:state():is_ecm_jammer_active("camera")

	for _, unit in ipairs(SecurityCamera.cameras or {}) do
		local base = alive(unit) and unit:base()
		local off = self:camera_off_reason(unit, base, ecm)

		self:note_camera(unit, off)

		if not off then
			table.insert(list, {
				kind = "camera",
				unit = unit,
				pos = mvector3.copy(base._pos),
				fwd = mvector3.copy(base._look_fwd),
				range = base._range,
				cone = base._cone_angle,
				delay = base._detection_delay,
				sweep = self:camera_sweep(unit, base._look_fwd)
			})
		end
	end

	self._obs = list
	self._obs_t = t

	return list
end

function Sneak:notice_rate(obs, pos, crouched)
	mvector3.set(tmp_vec1, pos)
	mvector3.set_z(tmp_vec1, pos.z + self:head_height(crouched))

	local dis = mvec3_dis(obs.pos, tmp_vec1)
	if dis > self.OBSERVER_RANGE then
		return nil
	end

	local settings_name = (obs.kind == "civilian" and "pl_mask_on_foe_non_combatant_whisper_mode_" or "pl_mask_on_foe_combatant_whisper_mode_") .. (crouched and "crouch" or "stand")
	local settings = tweak_data.attention.settings[settings_name]
	if not settings then
		return nil
	end

	local rate
	local sweep_fraction

	if obs.kind == "camera" then
		local max_dis = math.min(obs.range, settings.max_range or obs.range)
		if settings.detection and settings.detection.range_mul then
			max_dis = max_dis * settings.detection.range_mul
		end

		if dis >= max_dis then
			return nil
		end

		local angle = 0
		if settings.notice_requires_FOV then
			mvector3.direction(tmp_vec2, obs.pos, tmp_vec1)
			angle = mvector3.angle(obs.fwd, tmp_vec2)

			if angle >= obs.cone * 0.5 then
				local sweep = obs.sweep
				local width = sweep and sweep.max - sweep.min or 0

				if width < 10 then
					return nil
				end

				local bot_yaw = math.deg(math.atan2(tmp_vec2.y, tmp_vec2.x))
				local cam_yaw = math.deg(math.atan2(obs.fwd.y, obs.fwd.x))
				local wanted = (sweep.rel + (bot_yaw - cam_yaw) + 180) % 360 - 180

				if wanted < sweep.min - obs.cone * 0.5 or wanted > sweep.max + obs.cone * 0.5 then
					return nil
				end

				sweep_fraction = obs.cone / (width + obs.cone)
				angle = obs.cone * 0.5
			end
		end

		rate = self:delay_to_rate(obs.delay, 0.85 * (dis / max_dis) + 0.15 * math.min(angle / obs.cone, 1), settings)

		if sweep_fraction then
			rate = rate * sweep_fraction
		end
	else
		local detection = obs.det
		local max_dis = math.min(detection.dis_max, settings.max_range or detection.dis_max)
		if settings.detection and settings.detection.range_mul then
			max_dis = max_dis * settings.detection.range_mul
		end

		if settings.uncover_range and detection.use_uncover_range and dis < settings.uncover_range then
			rate = math.huge
		elseif dis >= max_dis then
			return nil
		else
			local angle = 0
			local instant

			if settings.notice_requires_FOV then
				mvector3.direction(tmp_vec2, obs.pos, tmp_vec1)
				angle = mvector3.angle(obs.fwd, tmp_vec2)

				if angle < 55 and not detection.use_uncover_range and settings.uncover_range and dis < settings.uncover_range then
					instant = true
				else
					local angle_max = math.lerp(180, detection.angle_max or 120, math.clamp((dis - 150) / 700, 0, 1))
					if angle >= angle_max then
						return nil
					end
				end
			end

			if instant then
				rate = math.huge
			else
				rate = self:delay_to_rate(detection.delay or { 0, 0 }, 0.75 * (dis / max_dis) + 0.25 * math.min(angle / (detection.angle_max or 120), 1), settings)
			end
		end
	end

	local blocked

	if obs.kind == "camera" and alive(obs.unit) then
		blocked = World:raycast("ray", obs.pos, tmp_vec1, "slot_mask", managers.slot:get_mask("AI_visibility"), "ray_type", "ai_vision", "ignore_unit", obs.unit, "report")
	else
		blocked = World:raycast("ray", obs.pos, tmp_vec1, "slot_mask", managers.slot:get_mask("AI_visibility"), "ray_type", "ai_vision", "report")
	end

	if blocked then
		return nil
	end

	return rate
end

function Sneak:delay_to_rate(delay, mix, settings)
	local mul = settings.notice_delay_mul or 1
	if settings.detection and settings.detection.delay_mul then
		mul = mul * settings.detection.delay_mul
	end

	local seconds = math.lerp(delay[1] * mul, delay[2], mix)

	return seconds > 0 and 1 / seconds or math.huge
end

function Sneak:notice_rising(st, noticed, t)
	local rising = st.prev_noticed and t - st.prev_noticed_t < 1 and noticed > st.prev_noticed + 0.02

	st.prev_noticed = noticed
	st.prev_noticed_t = t

	return rising and true or false
end

function Sneak:notice_source(unit)
	local key = unit:key()
	local best, best_obs = 0

	for _, obs in ipairs(self:observers()) do
		local progress = self:observer_progress(obs, key)

		if progress > best then
			best, best_obs = progress, obs
		end
	end

	return best_obs, best
end

function Sneak:head_height(crouched)
	local head = self._head
	local measured = head and head[crouched and "crouch" or "stand"]

	return (measured or (crouched and self.HEAD_CROUCH or self.HEAD_STAND)) + (self._head_margin or 0)
end

function Sneak:measure_head(unit)
	local movement = unit:movement()
	local anim_data = unit:anim_data()
	local kind = anim_data.crouch and "crouch" or anim_data.stand and "stand"
	local t = TimerManager:game():time()

	if not kind or movement._sh_head_t and t < movement._sh_head_t then
		return
	end

	movement._sh_head_t = t + 0.5

	local height = movement:m_head_pos().z - movement:m_pos().z
	local low, high = kind == "crouch" and 50 or 120, kind == "crouch" and 150 or 200

	if height < low or height > high then
		return
	end

	local own = movement._sh_heads or {}
	movement._sh_heads = own

	local old = own[kind]
	own[kind] = old and (old + (height - old) * 0.3) or height

	self._head_units = self._head_units or {}
	self._head_units[unit:key()] = own

	local tallest = 0
	for _, heads in pairs(self._head_units) do
		tallest = math.max(tallest, heads[kind] or 0)
	end

	self._head = self._head or {}
	self._head[kind] = tallest

	self._head_logged = self._head_logged or {}

	local logged = self._head_logged[kind]
	if not logged or math.abs(tallest - logged) > 10 then
		self._head_logged[kind] = tallest

		StreamHeist:log("Stealth: the tallest bot %s has its head %d cm above its feet (the model assumed %d cm before it was measured)", kind == "crouch" and "kneeling" or "standing", tallest, kind == "crouch" and self.HEAD_CROUCH or self.HEAD_STAND)
	end
end

function Sneak:sees(obs, pos, crouched)
	return self:notice_rate(obs, pos, crouched) ~= nil
end

function Sneak:decay_rate(obs)
	if obs.kind == "camera" then
		return obs.delay[2] > 0 and 1 / obs.delay[2] or 1
	end

	return 0.125
end

function Sneak:camera_progress(obs, key)
	local base = alive(obs.unit) and obs.unit:base()
	local info = base and base._detected_attention_objects and base._detected_attention_objects[key]

	if not info then
		return 0
	end

	return info.identified and 1 or info.notice_progress or 0
end

function Sneak:observer_progress(obs, key)
	if obs.kind == "camera" then
		return self:camera_progress(obs, key)
	end

	if not alive(obs.unit) then
		return 0
	end

	local brain = obs.unit:brain()
	local logic_data = brain and brain._logic_data
	local info = logic_data and logic_data.detected_attention_objects and logic_data.detected_attention_objects[key]

	if not info then
		return 0
	end

	return info.identified and 1 or info.notice_progress or 0
end

function Sneak:walk_speed(data, crouched)
	local move_speed = data.char_tweak and data.char_tweak.move_speed
	local pose = move_speed and (crouched and move_speed.crouch or move_speed.stand)
	local speed = pose and pose.walk and pose.walk.cbt and pose.walk.cbt.fwd

	return speed or 160
end

function Sneak:run_speed(data)
	local move_speed = data.char_tweak and data.char_tweak.move_speed
	local speed = move_speed and move_speed.stand and move_speed.stand.run and move_speed.stand.run.cbt and move_speed.stand.run.cbt.fwd

	return speed or 450
end

function Sneak:simulate_move(data, to, speed, crouch_moving, tail, limit)
	local observers = self:observers()
	local key = data.unit:key()
	local progress = {}

	for i, obs in ipairs(observers) do
		progress[i] = self:observer_progress(obs, key)
	end

	local from = data.m_pos
	local travel_t = mvec3_dis(from, to) / math.max(speed, 1)
	local total_t = travel_t + tail
	local pos = Vector3()
	local t = 0
	local peak, peak_obs = 0, nil

	while t < total_t do
		t = t + self.DASH_STEP

		local crouched = crouch_moving or t >= travel_t
		if t >= travel_t then
			mvector3.set(pos, to)
		else
			mvector3.lerp(pos, from, to, t / travel_t)
		end

		for i, obs in ipairs(observers) do
			local rate = self:notice_rate(self:predict(obs, t), pos, crouched)

			if rate then
				if rate == math.huge then
					return false, 1, obs
				end

				progress[i] = progress[i] + rate * self.DASH_STEP

				if progress[i] > peak then
					peak, peak_obs = progress[i], obs
				end

				if progress[i] > limit then
					return false, progress[i], obs
				end
			else
				progress[i] = math.max(0, progress[i] - self:decay_rate(obs) * self.DASH_STEP)
			end
		end
	end

	return true, peak, peak_obs
end

function Sneak:dash_safe(data, to, force, limit)
	if not force and not UsefulBots.settings.stealth_dash then
		return false
	end

	return self:simulate_move(data, to, self:run_speed(data), false, self.DASH_TAIL, limit or UsefulBots.settings.stealth_dash_limit or self.DASH_LIMIT)
end

function Sneak:walk_safe(data, to, force, limit)
	if not force and not UsefulBots.settings.stealth_dash then
		return false
	end

	return self:simulate_move(data, to, self:walk_speed(data, true), true, 0, limit or self.WALK_LIMIT)
end

function Sneak:safe_hop(data, target, limit, max_dis, force)
	if not force and not UsefulBots.settings.stealth_dash then
		return nil
	end

	local dis = mvec3_dis(data.m_pos, target)
	local point = Vector3()

	local function point_at(d)
		if d >= dis then
			mvector3.set(point, target)
		else
			mvector3.lerp(point, data.m_pos, target, d / dis)
		end

		return point
	end

	if self:walk_safe(data, point_at(math.min(dis, 600)), force) then
		return "walk", math.min(dis, 600)
	end

	local list = {}
	if dis <= (max_dis or math.huge) then
		table.insert(list, dis)
	end

	for _, d in ipairs(self.HOP_STEPS) do
		if d < dis then
			table.insert(list, d)
		end
	end

	local closest_peak, closest_obs, closest_d

	for _, d in ipairs(list) do
		local ok, peak, obs = self:dash_safe(data, point_at(d), force, limit)

		if ok then
			return "dash", d
		end

		if not closest_peak or peak < closest_peak then
			closest_peak, closest_obs, closest_d = peak, obs, d
		end
	end

	return nil, { peak = closest_peak, obs = closest_obs, dis = closest_d }
end

function Sneak:exposed(pos, crouched, t)
	for _, obs in ipairs(self:observers()) do
		if self:sees(self:predict(obs, t or 0), pos, crouched) then
			return obs
		end
	end
end

function Sneak:path_clear(from, to, crouched, speed)
	local dis = mvec3_dis(from, to)
	local steps = math.floor(dis / 300)

	for i = 1, steps do
		local f = i / (steps + 1)
		mvector3.lerp(tmp_vec3, from, to, f)

		if self:exposed(tmp_vec3, crouched, speed and dis * f / speed or 0) then
			return false
		end
	end

	return true
end

function Sneak:observer_near(pos, dis)
	local dis_sq = dis * dis

	for _, obs in ipairs(self:observers()) do
		if mvec3_dis_sq(obs.pos, pos) < dis_sq then
			return true
		end
	end

	return false
end

function Sneak:notice_progress(unit)
	local key = unit:key()
	local best = 0

	for _, obs in ipairs(self:observers()) do
		best = math.max(best, self:observer_progress(obs, key))
	end

	return best
end

function Sneak:guard_close(data)
	for _, obs in ipairs(self:observers()) do
		if obs.kind == "guard" then
			local dis = mvec3_dis(obs.pos, data.m_pos)

			if dis < self.GUARD_NEAR or dis < self.GUARD_FAR and self:sees(obs, data.m_pos, false) then
				return true
			end
		end
	end

	return false
end

function Sneak:civ_in_reach(movement, civ)
	local anchor = movement._should_stay_pos
	if not anchor then
		return false
	end

	if mvec3_dis_sq(civ:movement():m_pos(), anchor) > (UsefulBots.settings.stealth_civ_radius * 100) ^ 2 then
		return false
	end

	local groupai = managers.groupai:state()
	local area = groupai:get_area_from_nav_seg_id(managers.navigation:get_nav_seg_from_pos(anchor, true))

	return not area or groupai:get_area_from_nav_seg_id(civ:movement():nav_tracker():nav_segment()) == area
end

function Sneak:can_keep_civs(unit, t)
	if not alive(unit) or not self:active_for(unit) then
		return false
	end

	local movement = unit:movement()
	if movement._sh_engaged and t < movement._sh_engaged then
		return false
	end

	local damage_ext = unit:character_damage()

	return not (damage_ext and (damage_ext:need_revive() or damage_ext:dead()))
end

function Sneak:civ_owner(civ, t)
	self._civ_owner = self._civ_owner or {}

	local key = civ:key()
	local record = self._civ_owner[key]

	if record and t < record.t + 0.5 then
		return record.bot
	end

	local civ_pos = civ:movement():m_pos()
	local best, best_unit, best_dis

	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit

		if self:can_keep_civs(unit, t) and self:civ_in_reach(unit:movement(), civ) then
			local dis = mvec3_dis(unit:movement():m_pos(), civ_pos)

			if record and unit:key() == record.bot then
				dis = dis - 300
			end

			if not best_dis or dis < best_dis then
				best, best_unit, best_dis = unit:key(), unit, dis
			end
		end
	end

	if best and (not record or record.bot ~= best) then
		StreamHeist:log("Stealth wait: %s looks after a civilian (%.1f m away)", self:bot_name(best_unit), mvec3_dis(best_unit:movement():m_pos(), civ_pos) / 100)
	end

	self._civ_owner[key] = { bot = best, t = t }

	return best
end

function Sneak:civs_in_reach(movement)
	local civs = {}

	for _, u_data in pairs(managers.enemy:all_civilians()) do
		local unit = u_data.unit

		if alive(unit) and not unit:anim_data().hands_tied and self:civ_in_reach(movement, unit) then
			local damage_ext = unit:character_damage()

			if not (damage_ext and damage_ext:dead()) then
				table.insert(civs, unit)
			end
		end
	end

	return civs
end

function Sneak:wander(data, st)
	if st.wander_t and data.t < st.wander_t then
		return false
	end

	st.wander_t = data.t + math.lerp(8, 16, math.random())

	local movement = data.unit:movement()
	local posts = UsefulBots.hold:safe_area_posts(movement)
	if #posts == 0 then
		return false
	end

	local civs = self:civs_in_reach(movement)
	local shout_range = UsefulBots.melee and UsefulBots.melee.CIV_SHOUT_RANGE or 900
	local mask = managers.slot:get_mask("AI_visibility")
	local from = Vector3()

	local function keeps_civs_down(pos)
		if #civs == 0 then
			return true
		end

		mvector3.set(from, pos)
		mvector3.set_z(from, pos.z + 100)

		for _, civ in ipairs(civs) do
			if mvec3_dis(pos, civ:movement():m_pos()) <= shout_range and not World:raycast("ray", from, civ:movement():m_head_pos(), "slot_mask", mask, "ray_type", "ai_vision", "report") then
				return true
			end
		end

		return false
	end

	local order = {}
	for _, post in ipairs(posts) do
		if keeps_civs_down(post.pos) then
			table.insert(order, post)
		end
	end

	if #order == 0 then
		return false
	end

	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end

	local speed = self:walk_speed(data, true)
	local room = UsefulBots.hold:anchor_room(movement)

	local target = self:with_extra_observers(self:alerted_observers(), function()
		local tested = 0

		for _, post in ipairs(order) do
			local dis = mvec3_dis(post.pos, data.m_pos)

			if dis >= 250 and UsefulBots.hold:in_room(room, post.pos) and not UsefulBots.hold:is_taken(data.unit, post.pos) then
				tested = tested + 1

				if not self:exposed(post.pos, true, dis / speed) and not self:exposed(post.pos, true, dis / speed + 3) and self:path_clear(data.m_pos, post.pos, true, speed) then
					return post.pos
				end

				if tested >= 6 then
					break
				end
			end
		end
	end)

	if not target then
		return false
	end

	StreamHeist:log("Stealth wait: %s moves on to another spot nobody sees (%.1f m, %d civilians around)", self:bot_name(data.unit), mvec3_dis(target, data.m_pos) / 100, #civs)

	self:move_to(data, target, "walk", true)

	return true
end

function Sneak:alerted_civilians(data)
	local movement = data.unit:movement()
	local my_key = data.unit:key()
	local civs = {}

	for _, u_data in pairs(managers.enemy:all_civilians()) do
		local unit = u_data.unit

		if alive(unit) and not unit:movement():cool() and not unit:anim_data().hands_tied then
			local damage_ext = unit:character_damage()

			if (not damage_ext or not damage_ext:dead()) and self:civ_in_reach(movement, unit) and self:civ_owner(unit, data.t) == my_key then
				table.insert(civs, unit)
			end
		end
	end

	return civs
end

function Sneak:build_perimeter(civs, anchor, room, movement)
	local centroid = Vector3()
	for _, civ in ipairs(civs) do
		mvector3.add(centroid, civ:movement():m_pos())
	end
	mvector3.multiply(centroid, 1 / #civs)

	local navman = managers.navigation
	local points = {}

	for _, civ in ipairs(civs) do
		local pos = civ:movement():m_pos()
		local dir = pos - centroid
		mvector3.set_z(dir, 0)

		if mvector3.length(dir) < 50 then
			dir = anchor - pos
			mvector3.set_z(dir, 0)
		end

		if mvector3.length(dir) > 1 then
			mvector3.set_length(dir, 250)

			local tracker = navman:create_nav_tracker(pos + dir)
			local point = mvector3.copy(tracker:field_position())
			navman:destroy_nav_tracker(tracker)

			if UsefulBots.hold:in_room(room, point) then
				table.insert(points, {
					pos = point,
					angle = math.atan2(dir.y, dir.x)
				})
			end
		end
	end

	if movement then
		local mask = managers.slot:get_mask("AI_visibility")
		local shout_range = UsefulBots.melee and UsefulBots.melee.CIV_SHOUT_RANGE or 900
		local from = Vector3()

		for _, post in ipairs(UsefulBots.hold:safe_area_posts(movement)) do
			if UsefulBots.hold:in_room(room, post.pos) then
				mvector3.set(from, post.pos)
				mvector3.set_z(from, post.pos.z + 100)

				for _, civ in ipairs(civs) do
					local dis = mvec3_dis(post.pos, civ:movement():m_pos())

					if dis >= 150 and dis <= shout_range and not World:raycast("ray", from, civ:movement():m_head_pos(), "slot_mask", mask, "ray_type", "ai_vision", "report") then
						table.insert(points, {
							pos = mvector3.copy(post.pos),
							angle = math.atan2(post.pos.y - centroid.y, post.pos.x - centroid.x)
						})

						break
					end
				end
			end
		end
	end

	table.sort(points, function(a, b)
		return a.angle < b.angle
	end)

	local result = {}
	for _, point in ipairs(points) do
		table.insert(result, point.pos)
	end

	return result
end

function Sneak:find_hidden_spot(data, check_path, force, avoid, toward)
	local result = self:with_extra_observers(self:alerted_observers(), function()
		return { self:search_hidden_spot(data, check_path, force, avoid, toward) }
	end)

	if not result[1] and (not self._nospot_t or data.t > self._nospot_t + 2) then
		self._nospot_t = data.t

		local counts = { guard = 0, civilian = 0, camera = 0 }
		for _, obs in ipairs(self:observers()) do
			counts[obs.kind] = (counts[obs.kind] or 0) + 1
		end

		StreamHeist:log("Stealth: %s found no hidden spot (guards %d, civilians %d, cameras %d, alerted guards %d)", self:bot_name(data.unit), counts.guard, counts.civilian, counts.camera, #self:alerted_observers())
	end

	return result[1], result[2]
end

function Sneak:search_hidden_spot(data, check_path, force, avoid, toward)
	local center = data.m_pos

	if not force and not self:exposed(center, true) and not self:exposed(center, true, self.LOOKAHEAD_T) then
		return mvector3.copy(center), true
	end

	local radius = UsefulBots.settings.stealth_civ_radius * 100
	local navman = managers.navigation
	local run_speed = self:run_speed(data)
	local walk_speed = self:walk_speed(data, true)
	local best, best_dis

	local movement = data.unit:movement()
	local room = movement._should_stay and UsefulBots.hold:anchor_room(movement) or nil

	local function allowed(pos)
		if force and mvec3_dis(pos, center) < 250 then
			return false
		end

		for _, bad in ipairs(avoid or {}) do
			if mvec3_dis(pos, bad) < 250 then
				return false
			end
		end

		return true
	end

	local function consider(pos)
		local dis = mvec3_dis(pos, center)
		local score = toward and dis - 0.6 * (mvec3_dis(center, toward) - mvec3_dis(pos, toward)) or dis

		if (not best_dis or score < best_dis) and math.abs(pos.z - center.z) < 250 and UsefulBots.hold:in_room(room, pos) and allowed(pos) and not self:exposed(pos, true, dis / run_speed) and (not check_path or self:path_clear(center, pos, true, walk_speed)) and self:spot_reachable(data, pos) then
			best = mvector3.copy(pos)
			best_dis = score
		end
	end

	for _ = 1, self.SAMPLES do
		mvector3.set(tmp_vec3, math.UP)
		mvector3.random_orthogonal(tmp_vec3)
		mvector3.multiply(tmp_vec3, radius * math.sqrt(math.random()))
		mvector3.add(tmp_vec3, center)

		local tracker = navman:create_nav_tracker(tmp_vec3)
		consider(tracker:field_position())
		navman:destroy_nav_tracker(tracker)
	end

	for _, pos in ipairs(self:camera_spots(center, radius)) do
		consider(pos)
	end

	return best, false
end

function Sneak:camera_spots(center, radius)
	local navman = managers.navigation
	local spots = {}

	for _, obs in ipairs(self:observers()) do
		if obs.kind == "camera" and mvec3_dis(obs.pos, center) <= radius + 500 then
			local fx, fy = obs.fwd.x, obs.fwd.y
			local len = math.sqrt(fx * fx + fy * fy)
			local offsets = { { 0, 0 } }

			for _, r in ipairs({ 100, 200 }) do
				for a = 0, 359, r == 100 and 90 or 45 do
					table.insert(offsets, { math.cos(math.rad(a)) * r, math.sin(math.rad(a)) * r })
				end
			end

			if len > 0.01 then
				for _, r in ipairs({ 100, 200, 300 }) do
					table.insert(offsets, { -fx / len * r, -fy / len * r })
				end
			end

			for _, offset in ipairs(offsets) do
				mvector3.set_static(tmp_vec3, obs.pos.x + offset[1], obs.pos.y + offset[2], center.z)

				local tracker = navman:create_nav_tracker(tmp_vec3)
				local pos = tracker:field_position()

				local dx, dy = pos.x - tmp_vec3.x, pos.y - tmp_vec3.y
				if dx * dx + dy * dy <= 350 * 350 then
					table.insert(spots, mvector3.copy(pos))
				end

				navman:destroy_nav_tracker(tracker)
			end
		end
	end

	return spots
end

function Sneak:alerted_observers()
	local t = TimerManager:game():time()
	if self._alerted and t < self._alerted_t + 0.25 then
		return self._alerted
	end

	local list = {}
	local melee = UsefulBots.melee

	if melee then
		for _, u_data in pairs(managers.enemy:all_enemies()) do
			local unit = u_data.unit

			if alive(unit) and melee:guard_state(unit) then
				local obs = self:guard_observer(unit)

				if obs then
					table.insert(list, obs)
				end
			end
		end
	end

	self._alerted = list
	self._alerted_t = t

	return list
end

function Sneak:begin_hiding(data, st, keep)
	if not UsefulBots.settings.stealth_stay_hidden or keep and st.hiding then
		return
	end

	st.hiding = { t = data.t }

	StreamHeist:log("Stealth: %s hides, it stays until it is safe to leave", self:bot_name(data.unit))
end

function Sneak:danger(data, st, crouched)
	local unit = data.unit

	if not st.hiding then
		return self:exposed(data.m_pos, crouched) or self:exposed(data.m_pos, crouched, self.LOOKAHEAD_T), self:notice_progress(unit)
	end

	local result = self:with_extra_observers(self:alerted_observers(), function()
		return { self:exposed(data.m_pos, crouched) or self:exposed(data.m_pos, crouched, self.LOOKAHEAD_T), self:notice_progress(unit) }
	end)

	return result[1], result[2]
end

local function copy_array(array)
	local result = {}

	for i = 1, #array do
		result[i] = array[i]
	end

	return result
end

function Sneak:coarse(data, from_seg, to_seg, from_pos, to_pos, banned)
	local nav = UsefulBots.nav

	if nav and nav:doors_enabled() then
		local ok, path = pcall(nav.coarse_path, nav, data, from_seg, to_seg, from_pos, to_pos, banned)

		if ok then
			if not path then
				pcall(nav.self_check, nav, data, from_seg, to_seg, from_pos, to_pos)
			end

			return path
		end

		nav._failed = true
		StreamHeist:error("Doors and obstacles: the route search failed, the game's own search is used until the next restart: %s", tostring(path))
	end

	local verify

	if banned and next(banned) then
		verify = function(seg)
			return not banned[seg] or seg == to_seg
		end
	end

	return managers.navigation:search_coarse({
		from_seg = from_seg,
		to_seg = to_seg,
		to_pos = to_pos,
		access_pos = data.SO_access,
		id = "sh_route" .. tostring(data.key),
		verify_clbk = verify
	})
end

function Sneak:line_shut(a, b)
	local nav = UsefulBots.nav

	if not nav or not nav:doors_enabled() then
		return false
	end

	local ok, shut = pcall(nav.line_shut, nav, a, b)

	return ok and shut
end

function Sneak:leg_failed(data, from_pos, to_pos, why)
	local nav = UsefulBots.nav

	if nav and nav:doors_enabled() then
		local ok, err = pcall(nav.leg_failed, nav, data, from_pos, to_pos, why)

		if not ok then
			StreamHeist:error("Doors and obstacles: a failed leg could not be looked at: %s", tostring(err))
		end
	end
end

function Sneak:spot_reachable(data, pos)
	local nav = UsefulBots.nav

	if not nav or not nav:doors_enabled() then
		return true
	end

	local ok, result = pcall(nav.reachable, nav, data, pos)

	return not ok or result
end

function Sneak:route_polyline(data, from_pos, to_pos, banned)
	local navman = managers.navigation
	local from_seg = navman:get_nav_seg_from_pos(from_pos, true)
	local to_seg = navman:get_nav_seg_from_pos(to_pos, true)

	if not from_seg or not to_seg then
		return nil
	end

	local pts = { mvector3.copy(from_pos) }

	if from_seg ~= to_seg then
		local path = self:coarse(data, from_seg, to_seg, from_pos, to_pos, banned)

		if not path then
			return nil
		end

		for i = 2, #path - 1 do
			table.insert(pts, mvector3.copy(path[i][2]))
		end
	end

	table.insert(pts, mvector3.copy(to_pos))

	local up = math.UP * 4
	local result = { pts[1] }
	local i = 1

	while i < #pts do
		local next_index = i + 1

		for j = i + 2, #pts do
			if not navman:raycast({ pos_from = pts[i] + up, pos_to = pts[j] + up }) and not self:line_shut(pts[i], pts[j]) then
				next_index = j
			end
		end

		table.insert(result, pts[next_index])
		i = next_index
	end

	return result
end

function Sneak:cut_polyline(pts, max_len)
	local result = { pts[1] }
	local total = 0

	for i = 2, #pts do
		local len = mvec3_dis(pts[i - 1], pts[i])

		if len > 0 and total + len >= max_len then
			local cut = Vector3()
			mvector3.lerp(cut, pts[i - 1], pts[i], (max_len - total) / len)
			table.insert(result, cut)

			return result
		end

		total = total + len
		table.insert(result, pts[i])
	end

	return result
end

function Sneak:plan_rate(obs, pos, crouched, t)
	local best = self:notice_rate(self:predict(obs, t), pos, crouched)

	if obs.motion then
		for _, offset in ipairs(self.ROUTE_TIME_MARGIN) do
			local rate = self:notice_rate(self:predict(obs, math.max(0, t + offset)), pos, crouched)

			if rate and (not best or rate > best) then
				best = rate
			end
		end
	end

	return best
end

function Sneak:advance_leg(observers, progress, from, to, speed, crouch_moving, t0)
	local travel_t = mvec3_dis(from, to) / math.max(speed, 1)
	local steps = math.max(1, math.ceil(travel_t / self.PLAN_STEP))
	local dt = travel_t / steps
	local pos = Vector3()
	local peak, peak_pos = 0, nil

	for k = 1, steps do
		mvector3.lerp(pos, from, to, k / steps)

		for i, obs in ipairs(observers) do
			local rate = self:plan_rate(obs, pos, crouch_moving or k == steps, t0 + k * dt)

			if rate then
				progress[i] = rate == math.huge and 1 or progress[i] + rate * dt

				if progress[i] > peak then
					peak = progress[i]
					peak_pos = mvector3.copy(pos)
				end
			else
				progress[i] = math.max(0, progress[i] - self:decay_rate(obs) * dt)
			end
		end
	end

	return travel_t, peak, peak_pos
end

function Sneak:advance_stand(observers, progress, pos, t0, duration)
	local steps = math.max(1, math.ceil(duration / self.PLAN_STEP))
	local dt = duration / steps
	local peak, peak_pos = 0, nil

	for k = 1, steps do
		for i, obs in ipairs(observers) do
			local rate = self:plan_rate(obs, pos, true, t0 + k * dt)

			if rate then
				progress[i] = rate == math.huge and 1 or progress[i] + rate * dt

				if progress[i] > peak then
					peak = progress[i]
					peak_pos = mvector3.copy(pos)
				end
			else
				progress[i] = math.max(0, progress[i] - self:decay_rate(obs) * dt)
			end
		end
	end

	return peak, peak_pos
end

function Sneak:evaluate_route(data, pts, via, sprint_limit)
	local observers = self:observers()
	local key = data.unit:key()
	local progress = {}

	for i, obs in ipairs(observers) do
		progress[i] = self:observer_progress(obs, key)
	end

	local run_speed = self:run_speed(data)
	local walk_speed = self:walk_speed(data, true)
	local pos = data.m_pos
	local t = self.ROUTE_START_DELAY
	local peak, peak_pos = self:advance_stand(observers, progress, pos, 0, self.ROUTE_START_DELAY)
	local modes, stops, leg_times, leg_peaks = {}, {}, {}, {}

	for leg, to in ipairs(pts) do
		local dash = copy_array(progress)
		local dash_t, dash_peak, dash_pos = self:advance_leg(observers, dash, pos, to, run_speed, false, t)
		local walk = copy_array(progress)
		local walk_t, walk_peak, walk_pos = self:advance_leg(observers, walk, pos, to, walk_speed, true, t)

		local mode, chosen, leg_t, leg_peak, leg_pos = "dash", dash, dash_t, dash_peak, dash_pos

		if (not sprint_limit or dash_peak > sprint_limit) and walk_peak < dash_peak - 0.03 then
			mode, chosen, leg_t, leg_peak, leg_pos = "walk", walk, walk_t, walk_peak, walk_pos
		end

		progress = chosen
		modes[leg] = mode
		stops[leg] = 0
		leg_times[leg] = leg_t
		leg_peaks[leg] = leg_peak
		t = t + leg_t

		if leg_peak > peak then
			peak, peak_pos = leg_peak, leg_pos
		end

		if via and via[leg] then
			local seen = false

			for _, obs in ipairs(observers) do
				if self:plan_rate(obs, to, true, t) then
					seen = true

					break
				end
			end

			if not seen then
				local wait = 0

				for i, obs in ipairs(observers) do
					if progress[i] > 0.01 then
						wait = math.max(wait, math.min(8, progress[i] / self:decay_rate(obs)))
					end
				end

				if wait > 0.5 then
					for i, obs in ipairs(observers) do
						progress[i] = math.max(0, progress[i] - self:decay_rate(obs) * wait)
					end

					stops[leg] = wait
					t = t + wait
				end
			end
		end

		pos = to
	end

	local tail_peak, tail_pos = self:advance_stand(observers, progress, pos, t, self.DASH_TAIL)
	if tail_peak > peak then
		peak, peak_pos = tail_peak, tail_pos
	end

	if sprint_limit and peak > sprint_limit then
		return self:evaluate_route(data, pts, via)
	end

	return { pts = pts, via = via, modes = modes, stops = stops, leg_times = leg_times, leg_peaks = leg_peaks, peak = peak, peak_pos = peak_pos, time = t + self.DASH_TAIL }
end

local function same_route(a, b)
	if #a ~= #b then
		return false
	end

	for i = 1, #a do
		if mvec3_dis(a[i], b[i]) > 150 then
			return false
		end
	end

	return true
end

function Sneak:route_vias(data, start, goal, segs, count)
	if count <= 0 then
		return {}
	end

	local navman = managers.navigation
	local dir = Vector3(goal.x - start.x, goal.y - start.y, 0)
	local len = mvector3.length(dir)

	if len < 1 then
		return {}
	end

	mvector3.normalize(dir)

	local all = {}
	for seg in pairs(segs) do
		all[seg] = true

		for neighbour in pairs(navman:get_nav_seg_neighbours(seg) or {}) do
			local meta = navman:get_nav_seg_metadata(neighbour)

			if meta and not meta.disabled then
				all[neighbour] = true
			end
		end
	end

	local speed = self:run_speed(data)
	local candidates = {}

	for seg in pairs(all) do
		for _, post in ipairs(UsefulBots.hold:safe_seg_posts(seg)) do
			local rx, ry = post.pos.x - start.x, post.pos.y - start.y
			local along = rx * dir.x + ry * dir.y
			local across = math.abs(rx * dir.y - ry * dir.x)

			if along > len * 0.1 and along < len * 0.9 and across <= 1500 and not self:exposed(post.pos, true, mvec3_dis(start, post.pos) / speed) then
				table.insert(candidates, { pos = post.pos, score = post.score - across / 3000 })
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	local result = {}

	for _, candidate in ipairs(candidates) do
		local apart = true

		for _, chosen in ipairs(result) do
			if mvec3_dis(chosen.pos, candidate.pos) < 500 then
				apart = false

				break
			end
		end

		if apart then
			table.insert(result, candidate)

			if #result >= count then
				break
			end
		end
	end

	return result
end

function Sneak:plan_routes(data, target, sprint_limit)
	local navman = managers.navigation
	local start = mvector3.copy(data.m_pos)
	local results = {}
	local polys = {}
	local segs = {}
	local cap = self.PLAN_ROUTES

	local base = self:route_polyline(data, start, target)
	if not base then
		return nil, results
	end

	base = self:cut_polyline(base, self.PLAN_HORIZON)

	local goal = base[#base]
	local start_seg = navman:get_nav_seg_from_pos(start, true)
	local goal_seg = navman:get_nav_seg_from_pos(goal, true)

	local function add(label, poly, via)
		if not poly or #poly < 2 or #results >= cap then
			return nil
		end

		for _, other in ipairs(polys) do
			if same_route(other, poly) then
				return nil
			end
		end

		local pts = {}
		for i = 2, #poly do
			pts[#pts + 1] = poly[i]

			local seg = navman:get_nav_seg_from_pos(poly[i], true)
			if seg then
				segs[seg] = true
			end
		end

		local result = self:evaluate_route(data, pts, via, sprint_limit)
		result.label = label

		table.insert(polys, poly)
		table.insert(results, result)

		return result
	end

	local last = add("shortest", base)

	local banned = {}
	for k = 1, 2 do
		if not last or not last.peak_pos or last.peak <= 0.02 then
			break
		end

		local seg = navman:get_nav_seg_from_pos(last.peak_pos, true)
		if not seg or seg == start_seg or seg == goal_seg or banned[seg] then
			break
		end

		banned[seg] = true
		last = add("around " .. k, self:route_polyline(data, start, goal, banned))
	end

	for _, via in ipairs(self:route_vias(data, start, goal, segs, self.PLAN_ROUTES - #results)) do
		local first = self:route_polyline(data, start, via.pos)
		local second = first and self:route_polyline(data, via.pos, goal)

		if second then
			local poly = copy_array(first)
			for i = 2, #second do
				poly[#poly + 1] = second[i]
			end

			add("over a stop", poly, { [#first - 1] = true })
		end
	end

	local rough_best

	for _, result in ipairs(results) do
		if not rough_best or result.peak < rough_best.peak then
			rough_best = result
		end
	end

	if rough_best and rough_best.peak > 0.5 then
		cap = cap + 1

		add("far", self:route_polyline(data, start, goal, segs))
	end

	local best

	for _, result in ipairs(results) do
		if not best or result.peak < best.peak - 0.02 or math.abs(result.peak - best.peak) <= 0.02 and result.time < best.time then
			best = result
		end
	end

	return best, results
end

function Sneak:route_tag(st)
	return st.tag or (st.kind == "bag" and "Stealth bag" or "Stealth follow")
end

function Sneak:try_routes(data, st, player_pos, limit, objective, force, exact)
	if self._routes_failed then
		return false
	end

	local waited = st.blocked_t and data.t - st.blocked_t or 0
	local bonus = math.min(0.2, math.max(0, waited - 20) * 0.01)
	local route_limit = force and 1 or exact and limit or math.min(limit, self.ROUTE_LIMIT + bonus)

	local sprint = st.kind == "bag" and (force and 1 or self.SPRINT_LIMIT) or nil

	self._head_margin = self.ROUTE_HEAD_MARGIN

	local success, packed = pcall(function()
		return self:with_extra_observers(self:alerted_observers(), function()
			local best, results = self:plan_routes(data, player_pos, sprint)

			return { best, results }
		end)
	end)

	self._head_margin = nil

	if not success then
		self._routes_failed = true
		StreamHeist:error("Route planning of bots disabled until the next restart: %s", tostring(packed))

		return false
	end

	local best, results = packed[1], packed[2]
	if not best then
		return false, "nopath"
	end

	local key = data.unit:key()
	local collected = {}

	for _, obs in ipairs(self:observers()) do
		local progress = self:observer_progress(obs, key)

		if progress > 0.02 then
			table.insert(collected, string.format("%s %d%% (%.1f m)", obs.kind, progress * 100, mvec3_dis(obs.pos, data.m_pos) / 100))
		end
	end

	local labels = {}
	for _, result in ipairs(results) do
		local modes = {}
		for i, mode in ipairs(result.modes) do
			modes[i] = mode == "dash" and "run" or "crouch"
		end

		table.insert(labels, string.format("%s %d%% in %.0f s (%s)", result.label, result.peak * 100, result.time, table.concat(modes, "+")))
	end

	if best.peak <= route_limit or not st.plan_log_t or data.t > st.plan_log_t then
		st.plan_log_t = data.t + 6

		StreamHeist:log(self:route_tag(st) .. ": %s looked at %d routes: %s. Best: %s (limit %d%%%s). Noticed so far: %s", self:bot_name(data.unit), #results, table.concat(labels, "; "), best.label, route_limit * 100, sprint and string.format(", runs a leg predicted at %d%% or less", sprint * 100) or "", #collected > 0 and table.concat(collected, ", ") or "by nobody")
	end

	if best.peak > route_limit then
		st.last_plan = { label = best.label, peak = best.peak, t = data.t }

		return false, "unsafe"
	end

	local legs = {}
	for i = 1, #best.pts do
		table.insert(legs, string.format("%s %.1f s%s", best.modes[i] == "dash" and "run" or "crouch", best.leg_times[i], best.stops[i] > 0 and string.format(", then waits %.0f s", best.stops[i]) or ""))
	end

	StreamHeist:log(self:route_tag(st) .. ": %s takes it, predicted %d%%: %s", self:bot_name(data.unit), best.peak * 100, table.concat(legs, " / "))

	local planned_times = copy_array(best.leg_times)
	planned_times[1] = (planned_times[1] or 0) + self.ROUTE_START_DELAY

	local expected, running = {}, 0
	for i, peak in ipairs(best.leg_peaks) do
		running = math.max(running, peak)
		expected[i] = running
	end

	st.route = {
		pts = best.pts,
		modes = best.modes,
		stops = best.stops,
		stopped = {},
		expected = expected,
		leg_times = planned_times,
		planned_t = best.time,
		i = 1,
		player = mvector3.copy(player_pos),
		origin = mvector3.copy(data.m_pos),
		limit = route_limit,
		forced = force and true or false,
		pushed = exact and true or false,
		t0 = data.t,
		retries = 0
	}

	st.last_hide = mvector3.copy(data.m_pos)

	self:issue_leg(data, st, objective or data.objective)

	return true
end

function Sneak:issue_leg(data, st, objective)
	local route = st.route
	local pt = route.pts[route.i]
	local dash = route.modes[route.i] == "dash"
	route.leg_t0 = data.t
	route.stall_pos = nil

	self:hold_still(data, false)
	self:set_crouch_walk(data, not dash)

	local followup = GroupAIStateBase.clone_objective(objective)
	followup.pose = nil

	data.brain:set_objective({
		type = "free",
		pos = mvector3.copy(pt),
		nav_seg = managers.navigation:get_nav_seg_from_pos(pt, true),
		haste = dash and "run" or "walk",
		pose = dash and "stand" or "crouch",
		sh_route = true,
		followup_objective = followup
	})
end

function Sneak:end_route(st, why)
	if st.route then
		StreamHeist:log(self:route_tag(st) .. ": a route ends (%s), it took %.1f s (planned %.1f s)", why, TimerManager:game():time() - st.route.t0, st.route.planned_t or 0)
	end

	if why == "it got there" then
		st.last_hide = nil
		st.plan_t = nil
	end

	st.route = nil
end

function Sneak:drive_route(data, st, objective)
	local route = st.route

	local moved = alive(objective.follow_unit) and mvec3_dis(objective.follow_unit:movement():m_pos(), route.player) > 1500

	if moved or data.t > route.t0 + 90 then
		self:end_route(st, moved and "the player moved on" or "it takes too long")

		return nil
	end

	if route.wait_until then
		if data.t < route.wait_until then
			self:set_pose(data, true)
			self:sync_attention(data)
			self:hold_still(data, true)

			return false
		end

		route.wait_until = nil
		route.i = route.i + 1
		route.retries = 0

		if not route.pts[route.i] then
			self:end_route(st, "it got there")

			return nil
		end

		self:issue_leg(data, st, objective)

		return true
	end

	local pt = route.pts[route.i]
	if not pt then
		self:end_route(st, "it got there")

		return nil
	end

	if mvec3_dis(data.m_pos, pt) < 250 then
		if route.arrival_logged ~= route.i then
			route.arrival_logged = route.i

			StreamHeist:log(self:route_tag(st) .. ": %s got to point %d of %d after %.1f s (planned %.1f s), noticed %d%% (the plan said %d%% at most)", self:bot_name(data.unit), route.i, #route.pts, data.t - (route.leg_t0 or data.t), route.leg_times[route.i] or 0, self:notice_progress(data.unit) * 100, (route.expected[route.i] or 0) * 100)
		end

		local stop = route.stops[route.i] or 0

		if stop > 0 and not route.stopped[route.i] then
			route.stopped[route.i] = true
			route.wait_until = data.t + stop

			StreamHeist:log(self:route_tag(st) .. ": %s waits %.0f s at a stop nobody sees", self:bot_name(data.unit), stop)

			self:set_pose(data, true)
			self:sync_attention(data)
			self:hold_still(data, true)

			return false
		end

		route.i = route.i + 1
		route.retries = 0

		if not route.pts[route.i] then
			self:end_route(st, "it got there")

			return nil
		end

		self:issue_leg(data, st, objective)

		return true
	end

	route.retries = route.retries + 1

	if route.retries > 3 then
		self:leg_failed(data, route.i > 1 and route.pts[route.i - 1] or route.origin, pt, "the leg was interrupted four times")
		self:end_route(st, "it did not get on")

		return nil
	end

	self:issue_leg(data, st, objective)

	return true
end

function Sneak:route_deviation(st, noticed, t)
	local route = st.route
	local expected = route.expected[math.min(route.i, #route.expected)] or 0
	local previous, previous_t = route.prev_noticed, route.prev_t

	route.prev_noticed, route.prev_t = noticed, t

	if noticed >= 0.95 then
		return "it is noticed"
	end

	if noticed > expected + (st.kind == "bag" and self.BAG_ROUTE_TOLERANCE or self.ROUTE_TOLERANCE) then
		return string.format("noticed %d%%, the plan said %d%% at most", noticed * 100, expected * 100)
	end

	if previous and t - previous_t < 1 then
		local rise_limit = route.pushed and 0.20 or 0.08

		if noticed - previous > rise_limit then
			return string.format("noticing goes up fast, %d%% to %d%%", previous * 100, noticed * 100)
		end
	end
end

function Sneak:describe_source(obs, pos)
	local dx, dy = pos.x - obs.pos.x, pos.y - obs.pos.y
	local dis = math.sqrt(dx * dx + dy * dy)
	local fx, fy = obs.fwd.x, obs.fwd.y
	local flen = math.sqrt(fx * fx + fy * fy)
	local facing = dis > 1 and flen > 0.01 and (fx * dx + fy * dy) / (flen * dis) or 0

	return string.format("%s %.1f m away (%s, %d%% facing the bot)", obs.kind, dis / 100, obs.motion and "walking" or "standing", math.max(0, facing) * 100)
end

function Sneak:retreat_ok(data, spot)
	local dis = mvec3_dis(data.m_pos, spot)

	if dis > 3000 then
		return false
	end

	local speed = self:run_speed(data)

	return self:with_extra_observers(self:alerted_observers(), function()
		return not self:exposed(spot, true, dis / speed) and not self:exposed(spot, true, dis / speed + 1)
	end) and true or false
end

function Sneak:abort_route(data, st, reason)
	local route = st.route
	if not route then
		return
	end

	local source, progress = self:notice_source(data.unit)
	local expected = route.expected[math.min(route.i, #route.expected)] or 0

	StreamHeist:log(self:route_tag(st) .. ": %s gives up its route (%s). Leg %d of %d, %.1f s in (planned %.1f s), the plan said %d%% at most, now %d%% by %s", self:bot_name(data.unit), reason, route.i, #route.pts, data.t - route.t0, route.planned_t or 0, expected * 100, progress * 100, source and self:describe_source(source, data.m_pos) or "nobody")

	st.retreat_to = route.origin
	st.route = nil

	if route.pushed then
		st.pushed = true
	end

	st.search_t = 0
	st.next_t = 0

	local objective = data.objective
	if objective and objective.sh_route and objective.followup_objective then
		data.brain:set_objective(objective.followup_objective)
	end
end

function Sneak:watch_route(data)
	local st = data.unit:movement()._sh_sneak

	if not st or not st.route then
		return
	end

	if st.watch_t and data.t < st.watch_t then
		return
	end

	st.watch_t = data.t + 0.3

	local reason = self:route_deviation(st, self:notice_progress(data.unit), data.t)

	if reason then
		self:abort_route(data, st, reason)

		return
	end

	local route = st.route

	if not route.stall_pos or mvec3_dis(route.stall_pos, data.m_pos) > 100 then
		route.stall_pos, route.stall_t = mvector3.copy(data.m_pos), data.t
	elseif data.t - route.stall_t > self.ROUTE_STALL_TIME then
		self:leg_failed(data, route.i > 1 and route.pts[route.i - 1] or route.origin, route.pts[route.i], "it stands still on the leg")
		self:end_route(st, "it is stuck")

		st.plan_t = nil

		local objective = data.objective
		if objective and objective.sh_route and objective.followup_objective then
			data.brain:set_objective(objective.followup_objective)
		end
	end
end

function Sneak:safe_route(name, func, ...)
	if self._routes_failed then
		return nil
	end

	local success, result, extra = pcall(func, self, ...)

	if success then
		return result, extra
	end

	self._routes_failed = true
	StreamHeist:error("Routes of bots disabled until the next restart, error in %s: %s", name, tostring(result))

	return nil
end

function Sneak:route_clear(data, target, limit)
	local dis = mvec3_dis(data.m_pos, target)
	local to = target

	if dis > self.HIDE_ROUTE then
		to = Vector3()
		mvector3.lerp(to, data.m_pos, target, self.HIDE_ROUTE / dis)
	end

	local speed = self:walk_speed(data, true)

	if not self:exposed(to, true, mvec3_dis(data.m_pos, to) / speed) and self:path_clear(data.m_pos, to, true, speed) then
		return true
	end

	return self:safe_hop(data, to, limit, math.huge, true) and true or false
end

function Sneak:safe_to_leave(data, st, target)
	local hiding = st.hiding
	hiding.t0 = hiding.t0 or data.t

	if data.t < hiding.t0 + self.HIDE_MIN_T or self:notice_progress(data.unit) > 0.01 then
		return false
	end

	local alerted = self:alerted_observers()

	for _, obs in ipairs(alerted) do
		if mvec3_dis(obs.pos, data.m_pos) < self.HIDE_ALERT_DIS then
			return false
		end
	end

	if not target then
		return true
	end

	local waited = math.max(0, data.t - hiding.t0 - self.HIDE_MIN_T)
	local limit = math.min(self.LIMIT_MAX, (UsefulBots.settings.stealth_dash_limit or self.DASH_LIMIT) + math.min(self.PATIENCE_MAX, waited * self.PATIENCE_RATE))

	return self:with_extra_observers(alerted, function()
		return self:route_clear(data, target, limit)
	end)
end

function Sneak:hold_still(data, state)
	local movement = data.unit:movement()

	if state then
		if not movement._sh_hold_still then
			movement._sh_hold_still = true

			if data.internal_data.advancing then
				data.brain:action_request({
					body_part = 2,
					type = "idle"
				})
			end
		end
	else
		movement._sh_hold_still = nil
	end
end

function Sneak:set_crouch_walk(data, state)
	local st = data.unit:movement()._sh_sneak
	local char_tweak = data.char_tweak

	if state then
		if st.prev_crouch_move == nil then
			st.prev_crouch_move = char_tweak.crouch_move or false
		end

		char_tweak.crouch_move = true
	elseif st.prev_crouch_move ~= nil then
		char_tweak.crouch_move = st.prev_crouch_move
		st.prev_crouch_move = nil
	end
end

function Sneak:set_pose(data, crouch)
	local anim_data = data.unit:anim_data()

	if crouch and not anim_data.crouch then
		if not data.unit:movement():chk_action_forbidden("crouch") then
			CopLogicAttack._chk_request_action_crouch(data)
		end
	elseif not crouch and not anim_data.stand then
		if not data.unit:movement():chk_action_forbidden("stand") then
			CopLogicAttack._chk_request_action_stand(data)
		end
	end
end

function Sneak:sync_attention(data)
	local unit = data.unit
	local st = unit:movement()._sh_sneak
	local crouched = unit:anim_data().crouch and true or false

	if st.attention_crouched == crouched then
		return
	end

	st.attention_crouched = crouched

	local brain = unit:brain()
	if brain and brain._attention_handler then
		local suffix = crouched and "crouch" or "stand"

		PlayerMovement.set_attention_settings(brain, {
			"pl_mask_on_foe_non_combatant_whisper_mode_" .. suffix,
			"pl_mask_on_foe_combatant_whisper_mode_" .. suffix
		}, "team_AI")
	end
end

function Sneak:move_to(data, pos, haste, crouch)
	local unit = data.unit
	local movement = unit:movement()
	local objective = data.objective

	self:hold_still(data, false)
	self:set_crouch_walk(data, crouch)

	movement._sh_spot = mvector3.copy(pos)

	objective.pos = mvector3.copy(pos)
	objective.nav_seg = managers.navigation:get_nav_seg_from_pos(pos, true)
	objective.haste = haste
	objective.pose = crouch and "crouch" or "stand"
	objective.in_place = nil
	objective.path_data = nil

	TeamAILogicBase._exit(unit, "travel")
end

function Sneak:release(unit)
	if not alive(unit) then
		return
	end

	local movement = unit:movement()
	local st = movement and movement._sh_sneak
	if not movement or not st and not movement._sh_hold_still then
		return
	end

	movement._sh_hold_still = nil
	movement._sh_sneak = nil

	local brain = unit:brain()
	local logic_data = brain and brain._logic_data

	if st and st.prev_crouch_move ~= nil and logic_data and logic_data.char_tweak then
		logic_data.char_tweak.crouch_move = st.prev_crouch_move
	end

	local objective = brain and brain:objective()
	if objective and (objective.type == "defend_area" or objective.type == "follow") then
		objective.haste = nil
		objective.pose = nil
	end

	if st and st.attention_crouched and unit:base()._sh_stealth_awake and managers.groupai:state():whisper_mode() and brain._attention_handler then
		PlayerMovement.set_attention_settings(brain, {
			"pl_mask_on_foe_non_combatant_whisper_mode_stand",
			"pl_mask_on_foe_combatant_whisper_mode_stand"
		}, "team_AI")
	end
end

function Sneak:explain_camera(obs, pos, crouched)
	local head = Vector3()
	mvector3.set(head, pos)
	mvector3.set_z(head, pos.z + self:head_height(crouched))

	local settings = tweak_data.attention.settings["pl_mask_on_foe_combatant_whisper_mode_" .. (crouched and "crouch" or "stand")]
	local max_dis = math.min(obs.range, settings and settings.max_range or obs.range)
	local dir = Vector3()
	mvector3.direction(dir, obs.pos, head)

	local mask = managers.slot:get_mask("AI_visibility")
	local plain = World:raycast("ray", obs.pos, head, "slot_mask", mask, "ray_type", "ai_vision", "report")
	local ignoring = alive(obs.unit) and World:raycast("ray", obs.pos, head, "slot_mask", mask, "ray_type", "ai_vision", "ignore_unit", obs.unit, "report")

	return string.format("distance %.1f m (limit %.1f m), angle %.0f (half cone %.0f), view blocked %s, blocked without the camera's own body %s",
		mvec3_dis(obs.pos, head) / 100, max_dis / 100, mvector3.angle(obs.fwd, dir), obs.cone * 0.5, tostring(plain and true or false), tostring(ignoring and true or false))
end

function Sneak:check_cameras(data)
	local unit = data.unit
	local movement = unit:movement()

	if movement._sh_cam_t and data.t < movement._sh_cam_t then
		return
	end

	movement._sh_cam_t = data.t + 0.5

	local key = unit:key()

	for _, obs in ipairs(self:observers()) do
		if obs.kind == "camera" then
			local progress = self:camera_progress(obs, key)

			if progress > 0.05 and (not movement._sh_cam_log_t or data.t > movement._sh_cam_log_t) then
				movement._sh_cam_log_t = data.t + 2

				local crouched = unit:anim_data().crouch and true or false
				local rate = self:notice_rate(obs, data.m_pos, crouched)

				StreamHeist:log("Stealth camera: %s is being noticed by a camera (%d%%), the model %s. %s, %s, real head %d cm above the feet",
					self:bot_name(unit), progress * 100, rate and "agrees" or "SEES NO VIEW ON IT", self:explain_camera(obs, data.m_pos, crouched),
					crouched and "kneeling" or "standing", movement:m_head_pos().z - movement:m_pos().z)
			end
		end
	end
end

function Sneak:diagnose(data)
	if self._diag_failed or not data.unit:base()._sh_stealth_awake then
		return
	end

	local success, result = pcall(function()
		self:measure_head(data.unit)
		self:check_cameras(data)
	end)

	if not success then
		self._diag_failed = true
		StreamHeist:error("Measuring bots and logging cameras disabled until the next restart: %s", tostring(result))
	end
end

function Sneak:update(data)
	if self._failed then
		return
	end

	local unit = data.unit

	self:diagnose(data)

	local engaged = unit:movement()._sh_engaged
	if engaged and data.t < engaged then
		return
	end

	if self:active_for(unit) then
		return self:safe("update", self.update_active, data)
	elseif self:follow_active_for(unit) then
		return self:safe("update follow", self.update_follow, data)
	end

	self:release(unit)
end

function Sneak:update_active(data)
	local unit = data.unit
	local movement = unit:movement()
	local objective = data.objective

	if not objective or objective.type ~= "defend_area" or objective.forced then
		return
	end

	local st = movement._sh_sneak
	if st and st.kind ~= "wait" then
		self:release(unit)
		st = nil
	end

	if not st then
		st = { kind = "wait", mode = "hide", mode_t = data.t, search_t = 0 }
		movement._sh_sneak = st

		StreamHeist:log("Stealth wait: %s starts sneaking", self:bot_name(unit))
	end

	if st.next_t and data.t < st.next_t then
		return
	end

	st.next_t = data.t + 0.3

	local crouched = unit:anim_data().crouch and true or false
	local exposed, noticed = self:danger(data, st, crouched)
	local rising = self:notice_rising(st, noticed, data.t)
	local guard_close = self:guard_close(data)
	local civs = self:alerted_civilians(data)

	if st.evading and (objective.in_place or data.t > st.evade_t + 8) then
		st.evading = nil
		objective.haste = nil
	end

	if exposed or noticed > 0.05 then
		if not st.evading and data.t > st.search_t then
			st.search_t = data.t + 1

			local force = noticed > 0.05 and not exposed and rising
			if force then
				st.bad_spots = st.bad_spots or {}
				table.insert(st.bad_spots, mvector3.copy(data.m_pos))

				if #st.bad_spots > 6 then
					table.remove(st.bad_spots, 1)
				end

				local source, source_progress = self:notice_source(unit)
				StreamHeist:log("Stealth wait: %s is being noticed more and more (%d%%, by a %s %.1f m away) where the model sees no view on it, it moves on", self:bot_name(unit), source_progress * 100, source and source.kind or "?", source and mvec3_dis(source.pos, data.m_pos) / 100 or 0)
			end

			local spot, hidden = self:find_hidden_spot(data, false, force, st.bad_spots)
			if spot and not hidden then
				st.evading = true
				st.evade_t = data.t
				self:begin_hiding(data, st)

				StreamHeist:log("Stealth wait: %s is being noticed, sprints to a hidden spot %.1f m away", self:bot_name(unit), mvec3_dis(spot, data.m_pos) / 100)

				self:move_to(data, spot, "run", false)

				return true
			elseif spot then
				self:begin_hiding(data, st, true)
			end
		end

		self:set_pose(data, true)
		self:sync_attention(data)

		return
	end

	if st.evading then
		return
	end

	if st.hiding then
		if not self:safe_to_leave(data, st, nil) then
			st.mode = "hide"
			self:set_pose(data, true)
			self:sync_attention(data)

			return
		end

		StreamHeist:log("Stealth wait: %s leaves its hiding place, it is safe", self:bot_name(unit))

		st.hiding = nil
		st.mode_t = data.t
	end

	local mode = (guard_close or #civs == 0) and "hide" or "civ"
	if mode ~= st.mode and (guard_close or mode == "civ" or data.t > st.mode_t + self.SETTLE_T) then
		StreamHeist:log("Stealth wait: %s switches to %s (%d alerted civilians, guard close: %s)", self:bot_name(unit), mode, #civs, tostring(guard_close))

		st.mode = mode
		st.mode_t = data.t
		st.perimeter = nil
		st.wander_t = data.t + math.lerp(5, 12, math.random())
	end

	local crouch = st.mode == "hide" or guard_close or self:observer_near(data.m_pos, self.CROUCH_RANGE)

	self:set_pose(data, crouch)
	self:sync_attention(data)

	if st.mode == "hide" then
		if UsefulBots.settings.stealth_wander and objective.in_place and not guard_close and self:wander(data, st) then
			return true
		end

		self:hold_still(data, false)

		return
	end

	if not objective.in_place then
		return
	end

	if st.civ_dwell then
		st.civ_dwell = nil
		st.civ_next_t = data.t + math.lerp(1.5, 4, math.random())
	end

	if st.civ_next_t and data.t < st.civ_next_t then
		return
	end

	if not st.perimeter or data.t > st.perimeter_t + 2 then
		st.perimeter = #civs > 0 and self:build_perimeter(civs, movement._should_stay_pos, UsefulBots.hold:anchor_room(movement), movement) or {}
		st.perimeter_t = data.t
	end

	local points = st.perimeter
	local dash_checks = 0

	for i = 0, #points - 1 do
		local index = ((st.pi or 0) + i) % #points + 1
		local point = points[index]

		if mvec3_dis_sq(point, data.m_pos) > 150 * 150 then
			local speed = self:walk_speed(data, crouch)

			if not self:exposed(point, crouch, mvec3_dis(point, data.m_pos) / speed) and self:path_clear(data.m_pos, point, crouch, speed) then
				st.pi = index
				st.civ_next_t = data.t + 0.5
				st.civ_dwell = true

				self:move_to(data, point, "walk", crouch)

				return true
			elseif dash_checks < 2 then
				dash_checks = dash_checks + 1

				if self:dash_safe(data, point) then
					st.pi = index
					st.civ_next_t = data.t + 0.5
					st.civ_dwell = true

					StreamHeist:log("Stealth wait: %s dashes to the next point %.1f m away, nobody is going to notice it in time", self:bot_name(unit), mvec3_dis(point, data.m_pos) / 100)

					self:move_to(data, point, "run", false)

					return true
				elseif self:walk_safe(data, point) then
					st.pi = index
					st.civ_next_t = data.t + 0.5
					st.civ_dwell = true

					self:move_to(data, point, "walk", crouch)

					return true
				end
			end
		end
	end

	st.civ_next_t = data.t + 1
	self:hold_still(data, #points > 0)
end



function Sneak:follow_active_for(unit)
	if self._failed or not UsefulBots.settings.stealth_follow then
		return false
	end

	local base = alive(unit) and unit:base()
	if not base or not base._sh_stealth_awake then
		return false
	end

	local movement = unit:movement()
	if movement._should_stay then
		return false
	end

	if not UsefulBots.stealth:enabled() or not managers.groupai:state():whisper_mode() or UsefulBots.stealth:is_loud_bound() then
		return false
	end

	local brain = unit:brain()
	local objective = brain and brain:objective()

	return objective and (objective.type == "follow" or objective.sh_evade or objective.sh_route) and true or false
end

function Sneak:evade_follow(data, spot)
	self:hold_still(data, false)
	self:set_crouch_walk(data, false)

	local st = data.unit:movement()._sh_sneak
	if st then
		self:begin_hiding(data, st)
	end

	local followup = GroupAIStateBase.clone_objective(data.objective)
	followup.pose = nil

	data.brain:set_objective({
		type = "free",
		pos = mvector3.copy(spot),
		nav_seg = managers.navigation:get_nav_seg_from_pos(spot, true),
		haste = "run",
		pose = "stand",
		sh_evade = true,
		followup_objective = followup
	})
end

function Sneak:update_follow(data)
	local unit = data.unit
	local movement = unit:movement()
	local objective = data.objective

	if objective and objective.sh_route then
		return self:safe_route("watch", self.watch_route, data)
	end

	if not objective or objective.type ~= "follow" or not alive(objective.follow_unit) then
		return
	end

	local st = movement._sh_sneak
	if st and st.kind ~= "follow" then
		self:release(unit)
		st = nil
	end

	if not st then
		st = { kind = "follow", search_t = 0 }
		movement._sh_sneak = st

		StreamHeist:log("Stealth follow: %s starts sneaking", self:bot_name(unit))
	end

	if st.next_t and data.t < st.next_t then
		return
	end

	st.next_t = data.t + 0.3

	local crouched = unit:anim_data().crouch and true or false
	local exposed, noticed = self:danger(data, st, crouched)
	local rising = self:notice_rising(st, noticed, data.t)

	local on_route = false

	if st.route then
		local reason = self:route_deviation(st, noticed, data.t)

		if reason then
			self:abort_route(data, st, reason)
		else
			on_route = true
		end
	end

	if (exposed or noticed > 0.05) and not on_route then
		if st.route then
			self:end_route(st, "noticed")
		end

		if st.dash_until then
			StreamHeist:log("Stealth follow: %s is noticed during a dash, the dash is over", self:bot_name(unit))

			st.dash_until = nil
			objective.haste = nil
		end

		if data.t > st.search_t then
			st.search_t = data.t + 1

			local force = noticed > 0.05 and not exposed and rising
			if force then
				st.bad_spots = st.bad_spots or {}
				table.insert(st.bad_spots, mvector3.copy(data.m_pos))

				if #st.bad_spots > 6 then
					table.remove(st.bad_spots, 1)
				end

				local source, source_progress = self:notice_source(unit)
				StreamHeist:log("Stealth follow: %s is being noticed more and more (%d%%, by a %s %.1f m away) where the model sees no view on it, it moves on", self:bot_name(unit), source_progress * 100, source and source.kind or "?", source and mvec3_dis(source.pos, data.m_pos) / 100 or 0)
			end

			local target_pos = objective.follow_unit:movement():m_pos()

			if not st.pushed and self:safe_route("plan", self.try_routes, data, st, target_pos, self.NOTICE_CUTOFF, nil, false, true) then
				StreamHeist:log("Stealth follow: %s is being noticed, takes a route on towards you instead of hiding", self:bot_name(unit))

				return true
			end

			local retreat = st.retreat_to
			st.retreat_to = nil

			local spot, hidden, retreating

			if retreat and mvec3_dis(data.m_pos, retreat) < 180 then
				spot, hidden, retreating = mvector3.copy(data.m_pos), true, true
			elseif retreat and self:retreat_ok(data, retreat) then
				spot, hidden, retreating = retreat, false, true
			else
				spot, hidden = self:find_hidden_spot(data, false, force, st.bad_spots, not retreat and target_pos or nil)
			end

			if spot and not hidden then
				StreamHeist:log("Stealth follow: %s is being noticed, sprints to %s %.1f m away (%s)", self:bot_name(unit), retreating and "the spot it left" or "a hidden spot", mvec3_dis(spot, data.m_pos) / 100, retreating and "back" or mvec3_dis(spot, target_pos) < mvec3_dis(data.m_pos, target_pos) and "towards you" or "away from you")

				self:evade_follow(data, spot)

				return true
			elseif spot then
				self:begin_hiding(data, st, true)
			end
		end

		self:set_pose(data, true)
		self:sync_attention(data)
		self:hold_still(data, true)

		return
	end

	st.pushed = nil

	if st.route then
		local result = self:safe_route("drive", self.drive_route, data, st, objective)

		if result ~= nil then
			return result
		end

		if self._routes_failed then
			st.route = nil
		end
	end

	if st.hiding then
		if not self:safe_to_leave(data, st, objective.follow_unit:movement():m_pos()) then
			self:set_pose(data, true)
			self:sync_attention(data)
			self:hold_still(data, true)

			return
		end

		StreamHeist:log("Stealth follow: %s leaves its hiding place, it is safe", self:bot_name(unit))

		st.hiding = nil
	end

	if st.dash_until then
		if data.t < st.dash_until then
			self:hold_still(data, false)
			return
		end

		st.dash_until = nil
		objective.haste = nil

		StreamHeist:log("Stealth follow: %s dash is over, it covered %.1f of %.1f m and is %.1f m from you", self:bot_name(unit), mvec3_dis(st.dash_from or data.m_pos, data.m_pos) / 100, (st.dash_dis or 0) / 100, mvec3_dis(data.m_pos, objective.follow_unit:movement():m_pos()) / 100)
	end

	local crouch = self:guard_close(data) or self:observer_near(data.m_pos, self.CROUCH_RANGE)

	self:set_pose(data, crouch)
	self:sync_attention(data)
	self:set_crouch_walk(data, crouch)
	objective.pose = crouch and "crouch" or nil

	local target = objective.follow_unit:movement():m_pos()

	mvector3.set(tmp_vec3, target)
	mvector3.subtract(tmp_vec3, data.m_pos)
	mvector3.set_z(tmp_vec3, 0)

	local dis = mvector3.length(tmp_vec3)
	local blocked = false

	if dis > 300 then
		mvector3.normalize(tmp_vec3)

		local step_pos = Vector3()
		for _, step in ipairs({ 300, 600 }) do
			if step < dis then
				mvector3.set(step_pos, tmp_vec3)
				mvector3.multiply(step_pos, step)
				mvector3.add(step_pos, data.m_pos)

				if self:exposed(step_pos, crouch, step / (crouch and self:walk_speed(data, true) or self:run_speed(data))) then
					blocked = true
					break
				end
			end
		end
	end

	if blocked and st.walk_ok_until and data.t < st.walk_ok_until then
		blocked = false
	end

	if blocked then
		st.blocked_t = st.blocked_t or data.t

		if data.t > (st.dash_t or 0) then
			st.dash_t = data.t + 0.6

			local waited = data.t - st.blocked_t
			local limit = math.min(self.LIMIT_MAX, (UsefulBots.settings.stealth_dash_limit or self.DASH_LIMIT) + math.min(self.PATIENCE_MAX, waited * self.PATIENCE_RATE))

			local routes_on = UsefulBots.settings.stealth_routes and not self._routes_failed

			if routes_on and data.t > (st.plan_t or 0) then
				st.plan_t = data.t + self.PLAN_COOLDOWN

				if self:safe_route("plan", self.try_routes, data, st, target, limit) then
					st.blocked_t = nil

					return true
				end
			end

			if routes_on then
				if st.last_hide and mvec3_dis(data.m_pos, st.last_hide) > 300 and (not st.retreat_t or data.t > st.retreat_t) then
					st.retreat_t = data.t + 3

					if self:retreat_ok(data, st.last_hide) then
						StreamHeist:log("Stealth follow: %s has no route it can take unseen, it goes back to the spot it left (%.1f m)", self:bot_name(unit), mvec3_dis(data.m_pos, st.last_hide) / 100)

						self:evade_follow(data, st.last_hide)

						return true
					end
				end
			end

			local way, hop
			if not routes_on then
				way, hop = self:safe_hop(data, target, limit, 2500)
			end

			if way == "walk" then
				st.walk_ok_until = data.t + 1.2
				blocked = false
			elseif way == "dash" then
				StreamHeist:log("Stealth follow: %s dashes towards you (%.1f of %.1f m), nobody is going to notice it in time", self:bot_name(unit), hop / 100, dis / 100)

				st.dash_until = data.t + hop / self:run_speed(data) + 0.5
				st.dash_from = mvector3.copy(data.m_pos)
				st.dash_dis = hop
				st.blocked_t = nil
				self:set_crouch_walk(data, false)
				objective.pose = nil
				objective.haste = "run"
				self:hold_still(data, false)

				return
			elseif hop and hop.obs and (not st.wait_log_t or data.t > st.wait_log_t) then
				st.wait_log_t = data.t + 3

				StreamHeist:log("Stealth follow: %s waits (%.0f s), %s %.1f m away would get to %d%% with noticing it during a dash of %.1f m (limit %d%%)", self:bot_name(unit), waited, hop.obs.kind, mvec3_dis(hop.obs.pos, data.m_pos) / 100, hop.peak * 100, hop.dis / 100, limit * 100)
			end
		end
	else
		st.blocked_t = nil
	end

	self:hold_still(data, blocked)
end

function Sneak:on_called(brain, other_unit)
	if self._failed then
		return
	end

	local unit = brain._unit
	local st = alive(unit) and unit:movement()._sh_sneak

	if st and st.hiding then
		st.hiding = nil

		StreamHeist:log("Stealth call: %s is called over and leaves its hiding place", self:bot_name(unit))
	end

	if not UsefulBots.settings.stealth_call then
		return
	end

	return self:safe("call", self.start_call, brain, other_unit)
end

function Sneak:start_call(brain, other_unit)
	local unit = brain._unit
	local data = brain._logic_data
	local base = alive(unit) and unit:base()

	if not data or not base or not base._sh_stealth_awake or not alive(other_unit) then
		return
	end

	if not UsefulBots.stealth:enabled() or not managers.groupai:state():whisper_mode() or UsefulBots.stealth:is_loud_bound() then
		return
	end

	local objective = data.objective
	if not objective or objective.type ~= "follow" or objective.follow_unit ~= other_unit then
		return
	end

	local tracker = other_unit:movement():nav_tracker()
	local pos = tracker:lost() and tracker:field_position() or tracker:position()

	if mvec3_dis(data.m_pos, pos) < 400 then
		return
	end

	if not self:dash_safe(data, pos, true) then
		StreamHeist:log("Stealth call: %s can not get to you unseen right now, waits in cover", self:bot_name(unit))
		return
	end

	self:release(unit)

	local followup = GroupAIStateBase.clone_objective(objective)
	followup.pose = nil

	brain:set_objective({
		type = "free",
		pos = mvector3.copy(pos),
		nav_seg = tracker:nav_segment(),
		sh_call = true,
		followup_objective = followup
	})

	StreamHeist:log("Stealth call: %s runs to where you stood (%.1f m), nobody is going to notice it in time", self:bot_name(unit), mvec3_dis(data.m_pos, pos) / 100)
end

function Sneak:update_marking(data)
	if self._failed then
		return
	end

	return self:safe("marking", self.mark_targets, data)
end

function Sneak:mark_targets(data)
	if not UsefulBots.settings.mark_specials or not UsefulBots.stealth:holds_fire(data.unit) then
		return
	end

	local movement = data.unit:movement()

	if data._next_mark_t and data._next_mark_t > data.t or movement._sh_mark_chk_t and data.t < movement._sh_mark_chk_t then
		return
	end

	movement._sh_mark_chk_t = data.t + 1

	if movement:chk_action_forbidden("action") or data.unit:anim_data().reload or data.internal_data.acting then
		return
	end

	local head_pos = movement:m_head_pos()
	local fwd = movement:m_rot():y()
	local range = tweak_data.player.long_dis_interaction.highlight_range
	local vis_mask = data.visibility_slotmask
	local best_guard, best_guard_dis
	local best_camera, best_camera_dis

	local function consider(unit, pos, kind)
		local contour = unit:contour()
		if not contour or contour:find_id_match("^mark") then
			return
		end

		local dis = mvec3_dis(head_pos, pos)
		local current_dis = kind == "guard" and best_guard_dis or best_camera_dis

		if dis > range or current_dis and dis >= current_dis then
			return
		end

		mvector3.direction(tmp_vec2, head_pos, pos)

		if mvector3.angle(tmp_vec2, fwd) > 50 or World:raycast("ray", head_pos, pos, "slot_mask", vis_mask, "report") then
			return
		end

		if kind == "guard" then
			best_guard, best_guard_dis = unit, dis
		else
			best_camera, best_camera_dis = unit, dis
		end
	end

	for _, u_data in pairs(managers.enemy:all_enemies()) do
		local unit = u_data.unit

		if alive(unit) and unit:movement():cool() and u_data.char_tweak.silent_priority_shout then
			local damage_ext = unit:character_damage()

			if not damage_ext or not damage_ext:dead() then
				consider(unit, unit:movement():m_head_pos(), "guard")
			end
		end
	end

	for _, unit in ipairs(SecurityCamera.cameras or {}) do
		if alive(unit) and unit:enabled() and not unit:base():destroyed() then
			local interaction = unit:interaction()

			if unit:base().is_friendly or interaction and interaction:active() and not interaction:disabled() then
				unit:base():get_mark_check_position(tmp_vec1)
				consider(unit, tmp_vec1, "camera")
			end
		end
	end

	local best, best_kind = best_guard, best_guard and "guard" or "camera"

	best = best or best_camera

	if best then
		self:mark(data, best, best_kind)
	end
end

function Sneak:mark(data, unit, kind)
	local sound, contour_id

	if kind == "camera" then
		sound = "f39_any"
		contour_id = "mark_unit"
	else
		sound = tweak_data.character[unit:base()._tweak_table].silent_priority_shout .. "_any"
		contour_id = managers.player:get_contour_for_marked_enemy()
	end

	data.unit:sound():say(sound, true)
	managers.network:session():send_to_peers_synched("play_distance_interact_redirect", data.unit, "cmd_point")
	data.unit:movement():play_redirect("cmd_point")
	unit:contour():add(contour_id, true)

	data._next_mark_t = data.t + 3

	StreamHeist:log("Stealth: %s marks a %s", self:bot_name(data.unit), kind)
end
