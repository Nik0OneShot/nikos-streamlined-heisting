-- Don't interrupt spooc action on target being tased
function ActionSpooc:_chk_target_invalid()
	if not self._target_unit then
		return true
	end

	if self._target_unit:base().is_local_player and not self._target_unit:movement():is_SPOOC_attack_allowed() then
		return true
	end

	if self._target_unit:movement():zipline_unit() then
		return true
	end

	local record = managers.groupai:state():criminal_record(self._target_unit:key())
	return not record or record.status == "disabled" or record.status == "dead"
end


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
-- everything below only runs on the host, keep it at the end of this file
if not Network:is_server() then
	return
end

-- make bots aware of cloaker attacks
Hooks:PostHook(ActionSpooc, "init", "init_ub", function (self)
	self._is_sabotaging_action = true
	UsefulBots:force_attention(self._unit)
end)
