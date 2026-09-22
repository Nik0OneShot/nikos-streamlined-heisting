-- Unregister sentry guns to prevent enemies from getting stuck/cheesed
-- Enemies will still shoot sentries but they won't actively path towards them
Hooks:PostHook(SentryGunBase, "setup", "sh_setup", SentryGunBase.unregister)


-- useful bots code (https://github.com/segabl/pd2-useful-bots)
-- Adapted from LIES
Hooks:PostHook(SentryGunBase, "activate_as_module", "activate_as_module_ub", function (self)
	if self._unit:brain()._attention_handler then
		self._unit:brain()._attention_handler:set_team(self._unit:movement():team())
	end
end)
