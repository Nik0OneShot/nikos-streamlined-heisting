if Network:is_client() then
	return
end


-- When an escape or loot secure zone is activated, mark that area for reinforcement spawngroups
-- This is done by checking the list of elements an ElementAreaTrigger executes for ElementMissionEnd or ElementCarry,
-- If it contains any of these, it is considered the escape zone/loot secure trigger
local function check_executed_objects(trigger, current, checked)
	if not current or checked[current] then
		return
	end

	checked[current] = true

	if (trigger._values.enabled and true or false) == (trigger._reinforce_point_enabled and true or false) then
		return
	end

	for _, params in pairs(current._values.on_executed) do
		local element = current:get_mission_element(params.id)
		local element_class = getmetatable(element)
		if element_class == ElementMissionEnd or element_class == ElementCarry and element._values.operation == "secure" then
			local force = trigger._values.enabled and 3 or nil
			trigger._reinforce_point_enabled = trigger._values.enabled
			if trigger._values.use_shape_element_ids then
				for _, shape_element in pairs(trigger._shape_elements) do
					if shape_element._values.enabled then
						managers.groupai:state():set_area_min_police_force(shape_element._id, force, shape_element._values.position)
					end
				end
			else
				managers.groupai:state():set_area_min_police_force(trigger._id, force, trigger._values.position)
			end
			local type = element_class == ElementMissionEnd and "Escape" or "Loot secure"
			if trigger._values.enabled then
				StreamHeist:log("%s zone activated, enabling reinforce groups in its area", type)
			else
				StreamHeist:log("%s zone deactivated, disabling reinforce groups in its area", type)
			end
			return true
		elseif check_executed_objects(trigger, element, checked) then
			return true
		end
	end
end

Hooks:PostHook(ElementAreaTrigger, "on_set_enabled", "sh_on_set_enabled", function(self)
	check_executed_objects(self, self, {})
end)


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
local needs_secure_match_level = {
	framing_frame_2 = true
}

local valid_carry_operations = {
	secure = true,
	secure_silent = true
}

local valid_instigators = {
	loot = true,
	unique_loot = true
}

local function get_loot_secure_elements(current, recursion_depth, found_elements, checked)
	recursion_depth = recursion_depth or 50
	found_elements = found_elements or {}
	checked = checked or {}
	if not current or checked[current] then
		return found_elements
	end
	checked[current] = true
	for _, params in pairs(current._values.on_executed or {}) do
		local element = current:get_mission_element(params.id)
		local element_class = getmetatable(element)
		if element_class == ElementCarry and valid_carry_operations[element._values.operation] then
			found_elements[element] = element
		end
		if element and recursion_depth > 0 then
			get_loot_secure_elements(element, recursion_depth - 1, found_elements, checked)
		end
	end
	return found_elements
end

function ElementAreaTrigger:sh_register_loot_secure()
	if not valid_instigators[self._values.instigator] then
		return false
	end

	self._loot_secure_elements = get_loot_secure_elements(self)
	if not next(self._loot_secure_elements) then
		return false
	end

	ElementAreaTrigger.sh_loot_secure_triggers = ElementAreaTrigger.sh_loot_secure_triggers or setmetatable({}, { __mode = "k" })
	ElementAreaTrigger.sh_loot_secure_triggers[self] = true
	return true
end

-- Some heists activate or assemble mission scripts in an order where the first
-- activation hook is too early. Rescan every loaded mission script when a player
-- gives a bag order so an active van cannot be missed.
function ElementAreaTrigger.sh_refresh_loot_secure_triggers()
	local count = 0
	for _, script in pairs(managers.mission:scripts() or {}) do
		for _, element in pairs(script:elements() or {}) do
			if getmetatable(element) == ElementAreaTrigger and element:sh_register_loot_secure() then
				count = count + 1
			end
		end
	end
	return count
end

Hooks:PostHook(ElementAreaTrigger, "on_script_activated", "on_script_activated_ub", function (self)
	self:sh_register_loot_secure()
end)

Hooks:PreHook(ElementAreaTrigger, "on_executed", "on_executed_ub", function (self, instigator)
	local throw_params = self:ub_can_secure_loot(instigator, true) and instigator:carry_data()._ub_throw_params
	if not throw_params or throw_params.expire_t < TimerManager:game():time() then
		return
	end

	local peer = managers.network:session():peer(instigator:carry_data():latest_peer_id())
	local peer_unit = peer and peer:unit()
	if not alive(peer_unit) then
		return
	end

	local u_key = peer_unit:key()
	local carry_id = instigator:carry_data():carry_id()
	local carry_type_tweak = tweak_data.carry[carry_id] and tweak_data.carry.types[tweak_data.carry[carry_id].type]
	local carry_throw_multiplier = carry_type_tweak and carry_type_tweak.throw_distance_multiplier or 1
	for _, v in pairs(managers.groupai:state():all_AI_criminals()) do
		local logic_data = v.unit:brain()._logic_data
		logic_data.secure_bag_data[u_key] = logic_data.secure_bag_data[u_key] or {}
		logic_data.secure_bag_data[u_key][self] = logic_data.secure_bag_data[u_key][self] or {}
		logic_data.secure_bag_data[u_key][self][carry_throw_multiplier] = throw_params
	end

	local has_value = tweak_data.carry[carry_id] and tweak_data.carry[carry_id].bag_value
	self._ub_match_carry_id = not has_value or needs_secure_match_level[Global.game_settings.level_id]
	self._ub_match_carry_id_secured = self._ub_match_carry_id_secured or {}
	self._ub_match_carry_id_secured[carry_id] = true
end)

function ElementAreaTrigger:ub_can_secure_loot(unit, manual)
	if Monkeepers or not (manual or UsefulBots.settings.secure_loot) or not self._values.enabled or not self._loot_secure_elements or not self:is_instigator_valid(unit) then
		return
	end

	local carry_data = alive(unit) and unit:carry_data()
	-- ElementCarry only calls managers.loot:secure (and therefore increments the
	-- secured-bag count and value) when the bag still has positive value.
	if not carry_data or carry_data:value() <= 0 then
		return
	end

	local carry_id = carry_data:carry_id()
	if self._ub_match_carry_id and not self._ub_match_carry_id_secured[carry_id] then
		return
	end

	for element in pairs(self._loot_secure_elements) do
		if element._values.enabled and (not element._values.type_filter or element._values.type_filter == "none" or carry_id == element._values.type_filter) then
			return true
		end
	end
end

-- Manual bot deliveries do not need to wait until a player has demonstrated a
-- throw into this zone. Use the center of an active trigger (or one of its
-- active shape elements) as the delivery point.
function ElementAreaTrigger:sh_manual_secure_info(carry_unit, from_pos)
	if not self:ub_can_secure_loot(carry_unit, true) then
		return
	end

	local points = {}
	if self._values.position then
		table.insert(points, self._values.position)
	end
	for _, shape in ipairs(self._shape_elements or {}) do
		if shape._values and shape._values.position and (self._values.use_disabled_shapes or shape:enabled()) then
			table.insert(points, shape._values.position)
		end
	end

	local best, best_dis
	for _, point in ipairs(points) do
		local dis = mvector3.distance_sq(from_pos, point)
		if not best_dis or dis < best_dis then
			best = point
			best_dis = dis
		end
	end

	if best then
		local tracker = managers.navigation:create_nav_tracker(best)
		local stand_pos = mvector3.copy(tracker:field_position())
		managers.navigation:destroy_nav_tracker(tracker)
		return {
			pos = stand_pos,
			bag_pos = mvector3.copy(best),
			dir = Vector3()
		}
	end
end
