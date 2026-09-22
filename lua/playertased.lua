-- Add random pitch when tased (Tasers are now evil!)
local _check_action_shock_original = PlayerTased._check_action_shock
function PlayerTased:_check_action_shock(t, input, ...)
	local do_shock = self._next_shock and self._next_shock < t

	_check_action_shock_original(self, t, input, ...)

	if do_shock then
		self._cam_start_pitch = self._unit:camera():camera_unit():base()._camera_properties.pitch
		self._cam_target_pitch = math.clamp(self._cam_start_pitch + math.rand(-5, 5), -90, 90)
		self._cam_start_pitch_t = t
		self._cam_target_pitch_t = t + 0.2
	end

	if self._cam_start_pitch then
		if t > self._cam_target_pitch_t then
			self._cam_start_pitch = nil
		else
			local pitch = math.map_range(t, self._cam_start_pitch_t, self._cam_target_pitch_t, self._cam_start_pitch, self._cam_target_pitch)
			self._unit:camera():camera_unit():base():set_pitch(pitch)
		end
	end
end


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
-- everything below only runs on the host, keep it at the end of this file
if not Network:is_server() then
	return
end

-- Fix assistance SO so bots return to their hold position when done
function PlayerTased:_register_revive_SO()
	if self._SO_id or not managers.navigation:is_data_ready() then
		return
	end

	self._SO_id = "PlayerTased_assistance"
	managers.groupai:state():add_special_objective(self._SO_id, UsefulBots:get_assist_SO(self._unit))
end

Hooks:PostHook(PlayerTased, "exit", "exit_ub", function (self)
	UsefulBots:stop_assist_objective(self._unit)
	self._SO_id = nil
end)
