UsefulBots.reload = UsefulBots.reload or {}

local Reload = UsefulBots.reload
Reload.TIMEOUT = 6
Reload.BLOCK = 5

local mvec3_dis_sq = mvector3.distance_sq


function Reload:enemies_nearby(data)
	local focus = data.attention_obj
	if not focus or focus.reaction < AIAttentionObject.REACT_COMBAT then
		return false
	end

	local weapon_range = data.internal_data.weapon_range
	if focus.dis and weapon_range and focus.dis > weapon_range.far then
		return false
	end

	return focus.verified or focus.verified_t and data.t - focus.verified_t < 3 or false
end

function Reload:threat_pos(data)
	local focus = data.attention_obj
	if not focus then
		return
	end

	return focus.nav_tracker and focus.nav_tracker:field_position() or focus.m_pos
end

function Reload:is_in_cover(data)
	local in_cover = data.internal_data.in_cover
	return in_cover and mvec3_dis_sq(in_cover[1][1], data.m_pos) < 150 * 150 or false
end

function Reload:find_cover(data, threat_pos)
	if data.unit:movement()._should_stay then
		return UsefulBots.hold:find_cover(data, threat_pos)
	end

	return UsefulBots.hold:find_cover_within(data, threat_pos, data.m_pos, UsefulBots.hold:radius())
end

function Reload:start(data)
	local my_data = data.internal_data
	local movement = data.unit:movement()

	if movement._should_stay and not UsefulBots.hold:is_patrolling(data) then
		return false
	end

	if not self:enemies_nearby(data) or self:is_in_cover(data) then
		return false
	end

	local moving_to_cover = my_data.moving_to_cover or my_data.walking_to_cover_shoot_pos

	if not moving_to_cover then
		local threat_pos = self:threat_pos(data)
		local cover = self:find_cover(data, threat_pos)
		if not cover then
			return false
		end

		local better_cover = { cover }
		CopLogicAttack._set_best_cover(data, my_data, better_cover)

		local offset_pos, yaw = CopLogicAttack._get_cover_offset_pos(data, better_cover, threat_pos)
		if offset_pos then
			better_cover[5] = offset_pos
			better_cover[6] = yaw
		end

		StreamHeist:log("%s goes to cover to reload (%.1f m away)", UsefulBots.hold:bot_name(data.unit), mvector3.distance(cover[1], data.m_pos) / 100)
	else
		StreamHeist:log("%s is already moving to cover, reloads there", UsefulBots.hold:bot_name(data.unit))
	end

	my_data.sh_reload = "go"
	my_data.sh_reload_t = data.t + self.TIMEOUT

	return true
end

function Reload:trip_finished(data)
	local my_data = data.internal_data

	if data.t > my_data.sh_reload_t then
		my_data.sh_reload_block_t = data.t + self.BLOCK
		StreamHeist:log("%s did not reach cover in time, reloads in place", UsefulBots.hold:bot_name(data.unit))
		return true
	end

	if not self:enemies_nearby(data) then
		StreamHeist:log("%s has no enemies nearby anymore, reloads in place", UsefulBots.hold:bot_name(data.unit))
		return true
	end

	return self:is_in_cover(data) and not my_data.moving_to_cover
end

function Reload:begin_reload(data)
	local my_data = data.internal_data

	my_data.sh_reload = "reloading"
	my_data.sh_reload_started_t = data.t
end

function Reload:chk_delay(unit)
	if not UsefulBots.settings.reload_in_cover or not Network:is_server() then
		return false
	end

	local brain = alive(unit) and unit:brain()
	local data = brain and brain._logic_data
	if not data or not data.is_team_ai or data.name ~= "assault" or not data.internal_data then
		return false
	end

	local my_data = data.internal_data
	local state = my_data.sh_reload

	if state == "reloading" then
		return false
	end

	if state == "go" then
		if self:trip_finished(data) then
			self:begin_reload(data)
			return false
		end

		return true
	end

	if unit:anim_data().reload or my_data.sh_reload_block_t and data.t < my_data.sh_reload_block_t then
		return false
	end

	return self:start(data)
end

function Reload:update(data)
	local my_data = data.internal_data
	local state = my_data.sh_reload
	if not state then
		return
	end

	local unit = data.unit

	if state == "go" then
		if self:trip_finished(data) then
			self:begin_reload(data)

			StreamHeist:log("%s starts reloading", UsefulBots.hold:bot_name(unit))

			if not unit:anim_data().reload and not unit:movement():chk_action_forbidden("action") then
				data.brain:action_request({
					body_part = 3,
					type = "reload"
				})
			end
		end
	elseif state == "reloading" then
		if data.t > my_data.sh_reload_started_t + 0.6 and not unit:anim_data().reload then
			my_data.sh_reload = nil
			my_data.sh_reload_block_t = data.t + 2
		end
	end
end
