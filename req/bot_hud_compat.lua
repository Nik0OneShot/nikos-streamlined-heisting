-- claude code

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
