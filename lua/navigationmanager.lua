-- Nav seg ids have been changed to string, attempt to access them both ways
Hooks:PostHook(NavigationManager, "_load_nav_data", "sh__load_nav_data", function(self)
	setmetatable(self._nav_segments, {
		__index = function(t, k)
			return type(k) == "number" and rawget(t, tostring(k)) or nil
		end
	})
end)


-- Ways bots may go (see req/bot_nav.lua): a new level starts from nothing
Hooks:PostHook(NavigationManager, "_load_nav_data", "sh_nav_reset", function()
	if UsefulBots and UsefulBots.nav then
		UsefulBots.nav:reset()
	end
end)

-- In stealth a link that would smash glass is closed to the team AI before it is registered
Hooks:PreHook(NavigationManager, "register_anim_nav_link", "sh_nav_register_link", function(self, element)
	local nav = UsefulBots and UsefulBots.nav

	if nav then
		local ok, err = pcall(nav.on_link_register, nav, element)

		if not ok and not nav._link_error_logged then
			nav._link_error_logged = true
			StreamHeist:error("Stealth nav: a link could not be checked for glass: %s", tostring(err))
		end
	end
end)

-- Everything that changes what can be walked through: what bots learned about shut ways is not valid anymore
Hooks:PostHook(NavigationManager, "register_anim_nav_link", "sh_nav_registered_link", function()
	if UsefulBots and UsefulBots.nav then
		UsefulBots.nav:changed(nil, nil, true)
	end
end)

Hooks:PostHook(NavigationManager, "unregister_anim_nav_link", "sh_nav_unregistered_link", function()
	if UsefulBots and UsefulBots.nav then
		UsefulBots.nav:changed(nil, nil, true)
	end
end)

Hooks:PostHook(NavigationManager, "add_obstacle", "sh_nav_add_obstacle", function(self, unit)
	if UsefulBots and UsefulBots.nav then
		UsefulBots.nav:changed("an obstacle was put in place", unit)
	end
end)

Hooks:PostHook(NavigationManager, "remove_obstacle", "sh_nav_remove_obstacle", function(self, unit)
	if UsefulBots and UsefulBots.nav then
		UsefulBots.nav:changed("an obstacle was taken away", unit)
	end
end)

Hooks:PostHook(NavigationManager, "set_nav_segment_state", "sh_nav_segment_state", function()
	if UsefulBots and UsefulBots.nav then
		UsefulBots.nav:changed()
	end
end)
