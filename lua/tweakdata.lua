			tweak_data.team_ai.stop_action.distance = 9999999999

-- incorporate my fuckass team a.i mod here because APPARENTLY putting it charactertweakdata now crashes your fucking game.
for _, v in pairs(tweak_data.character) do
	if type(v) == "table" and v.access == "teamAI1" then
		v.no_run_start = true
		v.no_run_stop = true
		v.always_face_enemy = true
		v.crouch_move = false
		v.weapon.weapons_of_choice = { primary = "wpn_fps_ass_amcar_npc" }
	end
end
