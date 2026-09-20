-- claude code

-- HUD mods the team a.i HUD (req/bot_hud.lua) can't or shouldn't run with. If one of them is enabled, the team a.i HUD
-- switches itself off completely: none of its hooks are installed, nothing is sent over the network and it never says
-- hello to a host. The rest of Streamlined Heisting is not affected.
--
-- A rule matches an ENABLED BLT mod when
--   * `exact`: the mod's name or id is exactly one of the strings, or
--   * `all`:   every string appears (case-insensitive) in the mod's name or id.
-- `globals` are global tables the HUD mod defines, a second signal that is also re-checked while playing, in case the
-- mod is renamed or loads late. `why` is what the log says. The exact BLT names of some HUDs aren't known, so with
-- mods/developer.txt the log lists every enabled mod that looks like a HUD/UI mod, add a rule here if yours isn't caught.
--
-- Not listed on purpose: Restoration HUD and VanillaHUD Plus (its vanilla HUD types) keep vanilla's panel layout and are
-- supported. Panels that aren't vanilla-shaped (VanillaHUD Plus' Custom HUD) are caught by a structure check instead.
return {
	disable = {
		{ label = "VoidUI", all = { "voidui" }, globals = { "VoidUI" }, why = "it already shows team a.i health" },
		{ label = "VoidUI", all = { "void ui" }, why = "it already shows team a.i health" },
		{ label = "Warframe HUD", all = { "warframe", "hud" }, why = "it already shows team a.i health" },
		{ label = "MUI", exact = { "MUI" }, globals = { "MUITeammate" }, why = "it replaces the teammate panels with its own class, which this feature doesn't support" },
		-- the standalone version of this feature (mod "Team AI HUD"), running both would hook the same panels twice
		{ label = "Team AI HUD (standalone)", exact = { "Team AI HUD" }, globals = { "TeamAIHUD" }, why = "the standalone version of this feature is enabled, remove it to use the one built into Streamlined Heisting" }
	}
}
