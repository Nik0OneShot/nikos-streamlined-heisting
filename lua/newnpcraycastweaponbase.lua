-- Team a.i HUD (see req/bot_hud.lua): clients simulate bot shooting but never consume the real clip, so they count
-- bot shots themselves and correct the count on every reload. This is above the client early return on purpose.
if not StreamHeist.bot_hud then
	StreamHeist:require("bot_hud")
end

if StreamHeist.bot_hud.active and not NewNPCRaycastWeaponBase._sh_bot_hooked then
	NewNPCRaycastWeaponBase._sh_bot_hooked = true

	local fire_original = NewNPCRaycastWeaponBase.fire

	if fire_original then
		function NewNPCRaycastWeaponBase:fire(...)
			local result = fire_original(self, ...)

			-- fire returns nil when no shot was made
			if result and Network:is_client() then
				local bot_hud = StreamHeist.bot_hud

				if bot_hud.active then
					bot_hud:on_client_bot_fire(self)
				end
			end

			return result
		end
	else
		StreamHeist:warn("NewNPCRaycastWeaponBase.fire not found, client bot ammo counting is disabled")
	end

	Hooks:PostHook(NewNPCRaycastWeaponBase, "on_reload", "sh_bot_on_reload", function(self)
		local bot_hud = StreamHeist.bot_hud

		if bot_hud.active and Network:is_client() then
			bot_hud:on_client_bot_reloaded(self)
		end
	end)
end

if Network:is_client() then
	return
end


-- Make team AI weapons alert enemies (oversight from when bots got the ability to use player weapons)
Hooks:PostHook(NewNPCRaycastWeaponBase, "set_user_is_team_ai", "sh_set_user_is_team_ai", function (self)
	if not self._setup or not alive(self._setup.user_unit) then
		return
	end

	self._setup.alert_AI = true
	self._setup.alert_filter = self._setup.user_unit:brain():SO_access()
	self._alert_events = {}
end)


-- Disable player skills and ammo types affecting NPC weapons
function NewNPCRaycastWeaponBase:_update_stats_values(...)
	local can_shoot_through_shield = self._can_shoot_through_shield
	local can_shoot_through_enemy = self._can_shoot_through_enemy
	local can_shoot_through_wall = self._can_shoot_through_wall
	local bullet_class = self._bullet_class
	local bullet_slotmask = self._bullet_slotmask
	local blank_slotmask = self._blank_slotmask

	NewRaycastWeaponBase._update_stats_values(self, ...)

	self._can_shoot_through_shield = can_shoot_through_shield
	self._can_shoot_through_enemy = can_shoot_through_enemy
	self._can_shoot_through_wall = can_shoot_through_wall
	self._bullet_class = bullet_class
	self._bullet_slotmask = bullet_slotmask
	self._blank_slotmask = blank_slotmask
end

function NewNPCRaycastWeaponBase:get_add_head_shot_mul()
end

function NewNPCRaycastWeaponBase:is_stagger()
end
