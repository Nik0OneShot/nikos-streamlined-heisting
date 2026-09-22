UsefulBots.interact = UsefulBots.interact or {}
local Interact = UsefulBots.interact

Interact.NET_ID = "sh_interact"

Interact.POINTER_HOLD = 0.5
Interact.POINTER_RANGE = 100000 
Interact.POINTER_TOLERANCE = 150 
Interact.POINTER_TIMEOUT = 20 
Interact.ARRIVE_DISTANCE = 120
Interact.WORK_LEEWAY = 1.5
Interact.ERRAND_TIMEOUT = 90 
Interact.PUSH_AFTER = 6 
Interact.BODY_BAGS = 5 
Interact.PAGER_HUMAN_RANGE = 1500 
Interact.PAGER_WAIT = 12
Interact.KILL_TIME = 20 
Interact.CHAIN_TIME = 150
Interact.WATCH = 0.5
Interact.TIES = 4 
Interact.TIES_SKILL = 4
Interact.TIE_WAIT = 10 
Interact.GROUP_RADIUS = 1000 
Interact.GUARD_BLOCK = 60 
Interact.GUARD_SAMPLES = 16
Interact.GUARD_SPOTS = 4 
Interact.GUARD_PATROL_MIN = 10
Interact.GUARD_PATROL_MAX = 20

Interact.DENY_FIELDS = { "special_equipment", "required_deployable", "equipment_consume", "deployable_consume", "equipment_needed" }
Interact.DENY_ID = { "shaped", "trip_mine", "ecm", "emp", "saw", "c4", "thermite", "gasoline", "dynamite", "sentry", "equipment", "hostage", "revive", "intimidate", "trade", "convert", "open", "close", "door", "gate", "shutter", "hatch", "vent", "window", "lever", "elevator", "breach", "crowbar", "pry", "cut_", "chain", "kick", "knock", "atm", "cash_machine", "lock", "key", "card", "rfid", "ammo_bag", "doctor_bag", "first_aid", "fak", "grenade_crate", "armor", "bodybags_bag" }

Interact.claims = Interact.claims or {}
Interact.chains = Interact.chains or {} 
Interact.dominators = Interact.dominators or {} 
Interact.workers = Interact.workers or {} 
Interact.civ_seen = Interact.civ_seen or {} 
Interact.civ_owners = Interact.civ_owners or {} 
Interact.guard_blocks = Interact.guard_blocks or {}

local mvec3_dis = mvector3.distance

local function setting(id)
	return UsefulBots.settings[id] ~= false
end

function Interact:enabled()
	return setting("bot_interact") and not self._failed
end

function Interact:name(unit)
	return UsefulBots.hold:bot_name(unit)
end

function Interact:range()
	return (UsefulBots.settings.auto_range or 12) * 100
end

function Interact:active(unit)
	return alive(unit) and unit:movement()._sh_errand ~= nil
end

function Interact:actor()
	local unit = managers.player:player_unit()
	local damage_ext = alive(unit) and unit:character_damage()

	if damage_ext and not damage_ext:dead() then
		return unit
	end
end

function Interact:pager_exhausted()
	local count = managers.groupai:state():get_nr_successful_alarm_pager_bluffs() or 0

	local ok, chance = pcall(function()
		local has_upgrade = managers.player:has_category_upgrade("player", "corpse_alarm_pager_bluff")
		local chances = tweak_data.player.alarm_pager[has_upgrade and "bluff_success_chance_w_skill" or "bluff_success_chance"]

		return chances[math.min(count + 1, #chances)]
	end)

	return ok and chance ~= nil and chance <= 0, count
end

function Interact:check(target, bot)
	if not alive(target) then
		return false, "that is gone"
	end

	local carry = target:carry_data()

	if carry then
		if not bot then
			return true, "carry_pickup"
		end

		if alive(bot:movement()._carry_unit) then
			return false, "this bot is carrying a bag already"
		end

		if carry._linked_to and alive(carry._linked_to) then
			return false, "somebody carries that bag"
		end

		return true, "carry_pickup"
	end

	local ext = target:interaction()

	if not ext or not ext.tweak_data then
		return false, "there is nothing to do there"
	end

	if not ext:active() or ext:disabled() then
		return false, "there is nothing to do there now"
	end

	local id = tostring(ext.tweak_data)
	local tweak = ext._tweak_data or tweak_data.interaction[id]

	if not tweak then
		return false, "that interaction is not known"
	end

	if id == "intimidate" or managers.enemy:all_civilians()[target:key()] then
		return self:check_tie(target, bot)
	end

	for _, field in ipairs(self.DENY_FIELDS) do
		if tweak[field] then
			return false, "bots have no equipment for that", true
		end
	end

	for _, part in ipairs(self.DENY_ID) do
		if id:find(part, 1, true) then
			return false, "bots do not do that", true
		end
	end

	if id == "corpse_alarm_pager" and self:pager_exhausted() then
		return false, "the next pager is an alarm, whatever a bot does"
	end

	if not self:actor() then
		return false, "no player to lend the skills"
	end

	if id == "corpse_dispose" then
		if bot and (bot:movement()._sh_bodybags or self.BODY_BAGS) <= 0 then
			return false, "this bot has no body bags left"
		end

		if bot and alive(bot:movement()._carry_unit) then
			return false, "this bot is carrying something"
		end

		return true, id
	end

	local ok, can = pcall(ext.can_interact, ext, self:actor())

	if ok and not can then
		return false, "that can not be done now"
	end

	return true, id
end

function Interact:check_tie(target, bot)
	if not managers.enemy:all_civilians()[target:key()] or self:civ_tied(target) then
		return false, "bots do not do that", true
	end

	if not self:civ_held(target) then
		return false, "that civilian is not waiting to be tied"
	end

	if bot and self:ties_left(bot) <= 0 then
		return false, "this bot has no cable ties left"
	end

	if not self:actor() then
		return false, "no player to lend the skills"
	end

	return true, "intimidate"
end

function Interact:ties_left(unit)
	local movement = unit:movement()

	if movement._sh_ties == nil then
		movement._sh_ties = self.TIES + (managers.player:has_category_upgrade("cable_tie", "quantity_1") and self.TIES_SKILL or 0)
	end

	return movement._sh_ties
end

function Interact:civilians()
	local list = {}

	for _, u_data in pairs(managers.enemy:all_civilians()) do
		local unit = u_data.unit
		local damage_ext = alive(unit) and unit:character_damage()

		if damage_ext and not damage_ext:dead() then
			list[#list + 1] = unit
		end
	end

	return list
end

function Interact:civ_tied(civ)
	if not alive(civ) then
		return true
	end

	local brain = civ:brain()
	local ok, tied = pcall(function()
		return brain:is_tied()
	end)

	return ok and tied and true or civ:anim_data().tied and true or false
end

function Interact:civ_logic(civ)
	if not alive(civ) then
		return nil
	end

	local brain = civ:brain()
	local data = brain and brain._logic_data

	return data and data.name
end

function Interact:civ_held(civ)
	if not alive(civ) or self:civ_tied(civ) or self:civ_logic(civ) ~= "surrender" then
		return false
	end

	local ext = civ:interaction()
	local id = ext and ext.tweak_data and tostring(ext.tweak_data)

	return ext and ext:active() and not ext:disabled() and id and not id:find("hostage", 1, true) and true or false
end

function Interact:stand_position(target)
	local navman = managers.navigation
	local tracker = navman:create_nav_tracker(target:position())
	local stand = mvector3.copy(tracker:field_position())

	navman:destroy_nav_tracker(tracker)

	return stand
end

function Interact:work_distance(target)
	local ext = target:interaction()
	local tweak = ext and ext._tweak_data
	local distance = tweak and tweak.interact_distance or tweak_data.interaction.INTERACT_DISTANCE or 200

	return distance * self.WORK_LEEWAY
end

function Interact:start(unit, target, kind, reason, opts)
	opts = opts or {}

	if not alive(unit) or not alive(target) then
		return false
	end

	local movement = unit:movement()

	if movement:downed() then
		return false
	end

	if kind == "pager" and self:pager_exhausted() then
		return false
	end

	local whisper = managers.groupai:state():whisper_mode()
	local current = movement._sh_errand

	if current then
		if current.kind == "pager" and current.state == "working" then
			return false
		end

		self:cancel(unit, "something else came up")
	end

	if UsefulBots.bag:active(unit) then
		if kind ~= "pager" then
			return false
		end

		UsefulBots.bag:cancel(unit, "a pager needs an answer")
	end

	if (kind == "bodybag" or kind == "pickup") and alive(movement._carry_unit) then
		return false
	end

	if whisper and UsefulBots.stealth:enabled() and movement:cool() then
		return false
	end

	local ext = target:interaction()
	local errand = {
		kind = kind,
		target = target,
		key = target:key(),
		id = kind == "pickup" and "carry_pickup" or kind == "guard" and "guard" or kind == "tie" and "intimidate" or ext and tostring(ext.tweak_data) or kind,
		stand = opts.stand or self:stand_position(target),
		reason = reason,
		state = "moving",
		t0 = TimerManager:game():time(),
		push = opts.push,
		chain = opts.chain,
		standing = opts.standing,
		group = opts.group,
		anchor = opts.anchor,
		spots = opts.spots,
		order = { tag = "Stealth errand" }
	}

	movement._sh_errand = errand

	if kind ~= "guard" then
		self.claims[errand.key] = unit:key()
		self.workers[errand.key] = unit
	end

	if kind == "guard" then
		StreamHeist:log("Stealth errand: %s goes to guard %d civilians (%s)", self:name(unit), #errand.group, reason)
	else
		StreamHeist:log("Stealth errand: %s goes to do %s (%s)", self:name(unit), errand.kind == "bodybag" and "a body bag" or errand.id, reason)
	end

	return true
end

function Interact:end_errand(unit, errand, why, success)
	local movement = unit:movement()

	movement._sh_errand = nil

	if self.claims[errand.key] == unit:key() then
		self.claims[errand.key] = nil
	end

	if self.workers[errand.key] == unit then
		self.workers[errand.key] = nil
	end

	local brain = unit:brain()
	local data = brain and brain._logic_data

	if data then
		UsefulBots.sneak:hold_still(data, false)
	end

	UsefulBots.sneak:release(unit)

	if errand.kind ~= "bodybag" then
		local objective = brain and brain:objective()

		if objective and (objective.sh_errand or objective.sh_route or objective.sh_evade or objective.sh_bag_followup) then
			brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(unit))
		end
	end

	StreamHeist:log("Stealth errand: %s is done with %s (%s)%s", self:name(unit), errand.kind == "bodybag" and "a body bag" or errand.id, why, success and "" or ", it was not done")
end

function Interact:cancel(unit, why)
	if not alive(unit) then
		return
	end

	local errand = unit:movement()._sh_errand

	if not errand then
		return
	end

	if errand.state == "working" then
		self:interrupt(unit, errand)
	end

	self:end_errand(unit, errand, why or "cancelled", false)
end

function Interact:pager_in_the_way(unit)
	local errand = alive(unit) and unit:movement()._sh_errand

	if errand and errand.kind == "pager" and errand.state == "working" then
		StreamHeist:log("Stealth errand: %s was called while it answers a pager, it finishes first", self:name(unit))

		return true
	end

	return false
end

function Interact:on_called(unit, why)
	if not self:pager_in_the_way(unit) then
		self:block_guard(unit)
		self:cancel(unit, why or "called by a player")
	end
end

function Interact:block_guard(unit)
	local errand = alive(unit) and unit:movement()._sh_errand

	if errand and errand.kind == "guard" and errand.anchor then
		table.insert(self.guard_blocks, { pos = mvector3.copy(errand.anchor), t = TimerManager:game():time() + self.GUARD_BLOCK })

		StreamHeist:log("Stealth errand: %s was called away from guarding, that group is left alone for %d s", self:name(unit), self.GUARD_BLOCK)
	end
end

function Interact:group_blocked(pos, t)
	for index = #self.guard_blocks, 1, -1 do
		local block = self.guard_blocks[index]

		if t > block.t then
			table.remove(self.guard_blocks, index)
		elseif mvec3_dis(block.pos, pos) <= self.GROUP_RADIUS then
			return true
		end
	end

	return false
end

function Interact:on_released(unit)
	if not self:pager_in_the_way(unit) then
		self:block_guard(unit)
		self:cancel(unit, "the bot was released")
	end

	if alive(unit) and unit:movement()._sh_orders then
		unit:movement()._sh_orders = nil

		StreamHeist:log("Stealth errand: %s forgets what it was to do while it waits", self:name(unit))
	end
end

function Interact:safe_update(data)
	if self._failed then
		return false
	end

	local ok, result = pcall(self.update_logic, self, data)

	if ok then
		return result
	end

	self._failed = true

	StreamHeist:error("Interactions of bots disabled until the next restart: %s", tostring(result))

	self:cancel(data.unit, "error")

	return false
end

function Interact:update_logic(data)
	local unit = data.unit
	local movement = unit:movement()
	local errand = movement._sh_errand

	if not errand then
		return false
	end

	if errand.state == "working" or errand.state == "guarding" then
		if errand.kind ~= "pager" and UsefulBots.melee:update(data) then
			return true
		end

		return false
	end

	local sneak = UsefulBots.sneak

	if not managers.groupai:state():whisper_mode() or not UsefulBots.settings.stealth_routes or sneak._routes_failed or not UsefulBots.stealth:holds_fire(unit) then
		return false
	end

	errand.hook_t = data.t

	if data.objective and (data.objective.forced or data.objective.type == "revive") then
		return false
	end

	local defense_changed = UsefulBots.melee:update(data)

	if defense_changed then
		return true
	end

	local objective = data.objective

	if movement._sh_engaged and data.t < movement._sh_engaged or objective and (objective.sh_charge or objective.sh_flank) then
		return false
	end

	local st = movement._sh_sneak

	if not st or st.kind ~= "bag" or st.tag ~= "Stealth errand" then
		sneak:release(unit)

		st = { kind = "bag", tag = "Stealth errand" }
		movement._sh_sneak = st
	end

	local order = errand.order

	if not order.check_t or data.t >= order.check_t then
		order.check_t = data.t + 0.2
		order.exposed = sneak:exposed(data.m_pos, true) or sneak:notice_progress(unit) > 0.01
	end

	local dis = mvec3_dis(data.m_pos, errand.stand)

	if errand.push and not st.route and not (objective and objective.sh_route) and data.t > errand.t0 + self.PUSH_AFTER and data.t >= (st.plan_t or 0) then
		st.plan_t = data.t + sneak.PLAN_COOLDOWN

		if sneak:try_routes(data, st, errand.stand, 1, UsefulBots.bag:followup_objective(data, errand.stand), true) then
			StreamHeist:log("Stealth errand: %s takes the least noticed way to the pager, it can not wait", self:name(unit))

			return true
		end
	end

	local routed = sneak:safe_route("errand", function(_, ...)
		return UsefulBots.bag:update_routed(...)
	end, data, order, errand.stand, dis, order.exposed)

	if routed == nil then
		errand.hook_t = nil
	end

	return routed
end

function Interact:plain_move(unit, errand, t)
	if errand.move_t and t < errand.move_t then
		return
	end

	errand.move_t = t + 1

	local brain = unit:brain()
	local objective = brain:objective()

	if objective and (objective.forced or objective.type == "revive" or objective.sh_charge or objective.sh_flank) then
		return
	end

	if objective and objective.sh_errand and mvec3_dis(objective.pos, errand.stand) < 100 then
		return
	end

	brain:set_objective({
		type = "free",
		pos = mvector3.copy(errand.stand),
		nav_seg = managers.navigation:get_nav_seg_from_pos(errand.stand, true),
		haste = "run",
		pose = "stand",
		path_ahead = true,
		sh_errand = true
	})
end

function Interact:with_voice(bot, fn, ...)
	self._voice_bot = bot

	local results = { pcall(fn, ...) }

	self._voice_bot = nil

	return unpack(results)
end

function Interact:voice_bot(sound)
	local bot = self._voice_bot

	if bot and alive(bot) and sound._unit == managers.player:player_unit() then
		return bot
	end
end

function Interact:install_sound()
	if self._sound_installed or not PlayerSound then
		return
	end

	self._sound_installed = true

	if not PlayerSound._sh_wrapped then
		PlayerSound._sh_wrapped = true

		local say_original, play_original = PlayerSound.say, PlayerSound.play

		function PlayerSound:say(...)
			local bot = UsefulBots.interact:voice_bot(self)

			if bot then
				return bot:sound():say(...)
			end

			return say_original(self, ...)
		end

		function PlayerSound:play(...)
			local bot = UsefulBots.interact:voice_bot(self)

			if bot then
				return bot:sound():play(...)
			end

			return play_original(self, ...)
		end
	end

	if BaseInteractionExt and not BaseInteractionExt._sh_say_wrapped then
		BaseInteractionExt._sh_say_wrapped = true

		local say_original = BaseInteractionExt._interact_say

		function BaseInteractionExt:_interact_say(data)
			local bot = alive(self._unit) and UsefulBots.interact.workers[self._unit:key()]

			if bot and alive(bot) and type(data) == "table" then
				data[1] = bot
			end

			return say_original(self, data)
		end
	end
end

function Interact:supply_hint(unit, what)
	local ok, err = pcall(function()
		managers.hud:show_hint({ text = string.format("%s has no %s left", self:name(unit), what), time = 3 })
	end)

	if not ok and not self._supply_hint_failed then
		self._supply_hint_failed = true

		StreamHeist:error("Interactions of bots: a hint about running out could not be shown, this is not tried again until the next restart: %s", tostring(err))
	end
end

function Interact:hud(unit, errand, enabled, success)
	if not self._hud_failed then
		local ok, err = pcall(function()
			local character = managers.criminals:character_data_by_unit(unit)
			local panel = character and managers.hud._teammate_panels[character.panel_id]

			if panel then
				panel:teammate_progress(enabled, errand.id, enabled and errand.work.timer or 0, success or false)
			end
		end)

		if not ok then
			self._hud_failed = true

			StreamHeist:error("Interactions of bots: the progress bar could not be shown, it is switched off until the next restart: %s", tostring(err))
		end
	end

	self:label(unit, errand, enabled, success)
end

function Interact:label(unit, errand, enabled, success)
	if self._label_failed then
		return
	end

	local ok, err = pcall(function()
		local hud = managers.hud
		local movement = unit:movement()
		local label

		for _, data in ipairs(hud._hud.name_labels or {}) do
			if data.movement == movement then
				label = data

				break
			end
		end

		if not label then
			return
		end

		local tweak = tweak_data.interaction[errand.id]
		local text = managers.localization:text(tweak and tweak.action_text_id or "hud_action_generic")

		label.interact:set_visible(enabled)
		label.panel:child("action"):set_visible(enabled)
		label.panel:child("action"):set_text(utf8.to_upper(text))
		label.panel:stop()

		if enabled then
			label.panel:animate(callback(hud, hud, "_animate_label_interact"), label.interact, errand.work.timer)
		elseif success then
			local panel = label.panel
			local bitmap = panel:bitmap({
				align = "center",
				blend_mode = "add",
				layer = 2,
				rotation = 360,
				texture = "guis/textures/pd2/hud_progress_active",
				valign = "center"
			})

			bitmap:set_size(label.interact:size())
			bitmap:set_position(label.interact:position())

			local circle = CircleBitmapGuiObject:new(panel, {
				blend_mode = "normal",
				layer = 3,
				rotation = 360,
				radius = label.interact:radius(),
				color = Color.white:with_alpha(1)
			})

			circle:set_position(label.interact:position())
			bitmap:animate(callback(HUDInteraction, HUDInteraction, "_animate_interaction_complete"), circle)
		end
	end)

	if not ok then
		self._label_failed = true

		StreamHeist:error("Interactions of bots: the ring over the name could not be shown, it is switched off until the next restart: %s", tostring(err))
	end
end

function Interact:tie_civilian(unit, civ)
	local actor = self:actor()

	if not actor or not self:civ_held(civ) then
		return false
	end

	local ext = civ:interaction()

	if ext then
		pcall(ext.remove_interact, ext)
		pcall(ext.set_active, ext, false)
	end

	pcall(function()
		unit:sound():play("cable_tie_apply")
	end)

	civ:brain():on_tied(actor, false, not managers.player:has_category_upgrade("player", "super_syndrome"))

	local movement = unit:movement()

	movement._sh_ties = self:ties_left(unit) - 1

	StreamHeist:log("Stealth errand: %s ties a civilian (%d cable ties left)", self:name(unit), movement._sh_ties)

	if movement._sh_ties == 0 then
		self:supply_hint(unit, "cable ties")
	end

	return true
end

function Interact:pickup(unit, errand)
	local movement = unit:movement()
	local bag = errand.target
	local carry = alive(bag) and bag:carry_data()

	if not carry then
		return self:end_errand(unit, errand, "the bag is gone", false)
	end

	if alive(movement._carry_unit) then
		return self:end_errand(unit, errand, "the bot carries a bag already", false)
	end

	if carry._linked_to and alive(carry._linked_to) then
		return self:end_errand(unit, errand, "somebody else took the bag", false)
	end

	local ok, err = pcall(carry.link_to, carry, unit)

	if not ok then
		StreamHeist:error("Interactions of bots: a bag could not be picked up: %s", tostring(err))

		return self:end_errand(unit, errand, "the bag could not be picked up", false)
	end

	StreamHeist:log("Stealth errand: %s picks up a bag (%s)", self:name(unit), tostring(carry:carry_id()))

	self:end_errand(unit, errand, "the bag is picked up", true)
end

function Interact:start_work(unit, errand, t)
	if errand.kind == "pickup" then
		return self:pickup(unit, errand)
	end

	local actor = self:actor()

	if not actor then
		return self:cancel(unit, "no player to lend the skills")
	end

	local movement = unit:movement()
	local brain = unit:brain()
	local data = brain._logic_data
	local target = errand.target
	local timer

	if errand.kind == "tie" then
		local multiplier = managers.player:upgrade_value("cable_tie", "interact_speed_multiplier", 1) * managers.player:crew_ability_upgrade_value("crew_interact", 1) * managers.player:toolset_value()

		timer = (tweak_data.interaction.intimidate.timer or 2) * multiplier
	elseif errand.kind == "bodybag" then
		local multiplier = managers.player:upgrade_value("player", "corpse_dispose_speed_multiplier", 1) * managers.player:crew_ability_upgrade_value("crew_interact", 1) * managers.player:toolset_value()

		timer = (tweak_data.interaction.corpse_dispose.timer or 2) * multiplier
	else
		local ext = target:interaction()
		local ok, interacted, value = self:with_voice(unit, ext.interact_start, ext, actor)

		if not ok then
			StreamHeist:error("Interactions of bots: %s could not start %s: %s", self:name(unit), errand.id, tostring(interacted))

			return self:cancel(unit, "it could not be started")
		end

		if type(value) == "number" then
			timer = managers.modifiers:modify_value("PlayerStandard:OnStartInteraction", value, target)
		elseif interacted == false then
			return self:cancel(unit, "the game does not let it be done now")
		else
			StreamHeist:log("Stealth errand: %s did %s at once", self:name(unit), errand.id)

			return self:end_errand(unit, errand, "done", true)
		end
	end

	errand.state = "working"
	errand.work = { t0 = t, timer = timer, actor = actor }

	UsefulBots.sneak:hold_still(data, true)

	if managers.groupai:state():whisper_mode() then
		UsefulBots.sneak:set_pose(data, true)
	end

	pcall(function()
		movement:set_attention({ pos = target:position() })
	end)

	self:hud(unit, errand, true)

	StreamHeist:log("Stealth errand: %s starts %s (%.1f s, %s)", self:name(unit), errand.kind == "bodybag" and "a body bag" or errand.id, timer, errand.reason)

	if errand.kind == "pager" then
		StreamHeist:log("Stealth errand: that is pager number %d of this heist (%d were answered before)", (select(2, self:pager_exhausted())) + 1, (select(2, self:pager_exhausted())))
	end
end

function Interact:interrupt(unit, errand)
	local work = errand.work

	self:hud(unit, errand, false, false)

	if errand.kind == "bodybag" or errand.kind == "tie" or not work then
		return
	end

	local target = errand.target
	local ext = alive(target) and target:interaction()

	if ext and alive(work.actor) then
		local ok, err = self:with_voice(unit, ext.interact_interupt, ext, work.actor, false)

		if not ok then
			StreamHeist:error("Interactions of bots: %s could not be stopped: %s", errand.id, tostring(err))
		end
	end

	if errand.kind == "pager" then
		StreamHeist:log("Stealth errand: the answer of a pager was given up, the game calls the police")
	end
end

function Interact:finish(unit, errand)
	local work = errand.work
	local target = errand.target

	self:hud(unit, errand, false, true)

	if errand.kind == "tie" then
		local ok, result = pcall(self.tie_civilian, self, unit, target)

		if not ok then
			StreamHeist:error("Interactions of bots: a civilian could not be tied: %s", tostring(result))

			return self:end_errand(unit, errand, "the tie failed", false)
		end

		return self:end_errand(unit, errand, result and "the civilian is tied" or "the civilian could not be tied", result and true or false)
	end

	if errand.kind == "bodybag" then
		local ok, result = pcall(self.bag_corpse, self, unit, target)

		if not ok then
			StreamHeist:error("Interactions of bots: a body bag could not be made: %s", tostring(result))

			return self:end_errand(unit, errand, "the body bag failed", false)
		end

		return self:end_errand(unit, errand, result and "the body is bagged" or "the body could not be bagged", result and true or false)
	end

	local ext = target:interaction()
	local ok, err = self:with_voice(unit, function()
		ext:interact_interupt(work.actor, true)
		ext:interact(work.actor)
	end)

	if not ok then
		StreamHeist:error("Interactions of bots: %s could not be finished: %s", errand.id, tostring(err))

		return self:end_errand(unit, errand, "it failed", false)
	end

	if errand.kind == "pager" and not errand.chain then
		local damage_ext = alive(target) and target:character_damage()

		if damage_ext and not damage_ext:dead() and not self.chains[target:key()] then
			local t = TimerManager:game():time()

			self.chains[target:key()] = { key = target:key(), bot = unit, guard = target, t0 = t, stage = "kill", stage_t = t, how = "dominated" }

			StreamHeist:log("Stealth errand: %s finished a pager that was not its own, the guard is still its job (kill it, bag it)", self:name(unit))
		end
	end

	self:end_errand(unit, errand, "done", true)
end

function Interact:work_step(unit, errand, t)
	local work = errand.work
	local target = errand.target
	local why

	if errand.kind == "tie" then
		if not self:civ_held(target) or self:ties_left(unit) <= 0 then
			why = "the civilian is not waiting to be tied anymore"
		end
	elseif errand.kind ~= "bodybag" then
		local ext = target:interaction()

		if not ext or not ext:active() or tostring(ext.tweak_data) ~= errand.id then
			why = "the interaction is over"
		elseif ext:check_interupt() then
			why = "the interaction was interrupted"
		end
	elseif not alive(target) or not target:character_damage():dead() then
		why = "the body is gone"
	end

	if not why and mvec3_dis(unit:movement():m_pos(), target:position()) > self:work_distance(target) then
		why = "the bot was moved away"
	end

	if not why and not alive(work.actor) then
		why = "no player to lend the skills"
	end

	if why then
		return self:cancel(unit, why)
	end

	if t - work.t0 >= work.timer then
		return self:finish(unit, errand)
	end

	local data = unit:brain()._logic_data

	UsefulBots.sneak:hold_still(data, true)
end

function Interact:step_errand(unit, errand, t)
	local movement = unit:movement()
	local damage_ext = unit:character_damage()

	if movement:downed() or damage_ext and damage_ext:dead() then
		return self:cancel(unit, "the bot is down")
	end

	local whisper = managers.groupai:state():whisper_mode()

	if errand.kind == "pager" and not whisper then
		return self:cancel(unit, "stealth is over")
	end

	if errand.kind == "pager" and errand.state == "moving" and self:pager_exhausted() then
		return self:cancel(unit, "the next pager is an alarm, whatever a bot does")
	end

	if errand.kind == "guard" then
		return self:guard_step(unit, errand, t, whisper)
	end

	local target = errand.target

	if not alive(target) then
		return self:cancel(unit, "the target is gone")
	end

	if errand.state == "working" then
		return self:work_step(unit, errand, t)
	end

	if errand.kind ~= "bodybag" and errand.kind ~= "pickup" then
		local ext = target:interaction()

		if not ext or not ext:active() or ext:disabled() then
			return self:cancel(unit, "there is nothing to do there anymore")
		end
	end

	if errand.kind == "tie" and (not self:civ_held(target) or self:ties_left(unit) <= 0) then
		return self:cancel(unit, "the civilian is not waiting to be tied anymore")
	end

	if t > errand.t0 + self.ERRAND_TIMEOUT then
		return self:cancel(unit, "it took too long to get there")
	end

	local pos = movement:m_pos()

	if mvec3_dis(pos, errand.stand) <= self.ARRIVE_DISTANCE or mvec3_dis(pos, target:position()) <= self:work_distance(target) * 0.6 then
		return self:start_work(unit, errand, t)
	end

	if not (errand.hook_t and t < errand.hook_t + 1.5) then
		self:plain_move(unit, errand, t)
	end
end

function Interact:guard_step(unit, errand, t, whisper)
	if not whisper or not setting("auto_guard") then
		return self:cancel(unit, whisper and "guarding is switched off" or "stealth is over")
	end

	if not errand.check_t or t >= errand.check_t then
		errand.check_t = t + 0.5

		local left = {}

		for _, civ in ipairs(errand.group) do
			local damage_ext = alive(civ) and civ:character_damage()

			if damage_ext and not damage_ext:dead() and not self:civ_tied(civ) then
				left[#left + 1] = civ
			end
		end

		errand.group = left

		if #left == 0 then
			return self:cancel(unit, "no civilian is left that could call the police")
		end
	end

	local data = unit:brain()._logic_data

	if not errand.shout_t or t >= errand.shout_t then
		errand.shout_t = t + 0.5

		self:guard_shout(unit, errand, t, data)
	end

	local pos = unit:movement():m_pos()

	if errand.state == "moving" then
		if t > errand.t0 + self.ERRAND_TIMEOUT then
			return self:cancel(unit, "it took too long to get to its post")
		end

		if mvec3_dis(pos, errand.stand) <= self.ARRIVE_DISTANCE then
			return self:start_guarding(unit, errand, t)
		end

		if not (errand.hook_t and t < errand.hook_t + 1.5) then
			self:plain_move(unit, errand, t)
		end

		return
	end

	if mvec3_dis(pos, errand.stand) > 400 then
		self:go_watch(unit, errand, t, errand.stand)

		return
	end

	if t >= errand.patrol_t then
		local spots = errand.spots or { errand.stand }
		local next_i = errand.spot_i and errand.spot_i % #spots + 1 or 1

		errand.spot_i = next_i

		self:go_watch(unit, errand, t, spots[next_i])

		return
	end

	UsefulBots.sneak:hold_still(data, true)
end

function Interact:go_watch(unit, errand, t, spot)
	errand.state = "moving"
	errand.t0 = t
	errand.stand = spot

	UsefulBots.sneak:hold_still(unit:brain()._logic_data, false)
end

function Interact:start_guarding(unit, errand, t)
	local data = unit:brain()._logic_data

	errand.state = "guarding"
	errand.patrol_t = t + self.GUARD_PATROL_MIN + math.random() * (self.GUARD_PATROL_MAX - self.GUARD_PATROL_MIN)

	UsefulBots.sneak:hold_still(data, true)
	UsefulBots.sneak:set_pose(data, true)

	StreamHeist:log("Stealth errand: %s watches %d civilians (moves to another spot in %d s)", self:name(unit), #errand.group, math.floor(errand.patrol_t - t))
end

function Interact:guard_shout(unit, errand, t, data)
	local melee = UsefulBots.melee

	errand.shouts = errand.shouts or {}

	for _, civ in ipairs(errand.group) do
		if alive(civ) and self:civ_logic(civ) ~= "surrender" and melee:can_shout_civilian(civ) then
			local key = civ:key()
			local record = errand.shouts[key] or { n = 0, t = 0 }

			if record.n < 8 and t >= record.t and mvec3_dis(unit:movement():m_pos(), civ:position()) <= melee.CIV_SHOUT_RANGE and melee:has_los(data, civ) and melee:shout_civilian(data, civ) then
				record.n = record.n + 1
				record.t = t + melee.DOMINATE_WAIT
				errand.shouts[key] = record

				StreamHeist:log("Stealth errand: %s keeps a civilian down (shout %d)", self:name(unit), record.n)

				return
			end
		end
	end
end

function Interact:bag_corpse(unit, corpse)
	local movement = unit:movement()

	if alive(movement._carry_unit) then
		return false
	end

	local corpse_data = managers.enemy:get_corpse_unit_data_from_key(corpse:key())

	if not corpse_data then
		StreamHeist:log("Stealth errand: %s found no data of the corpse, it can not be bagged", self:name(unit))

		return false
	end

	local pos = mvector3.copy(corpse:position())

	mvector3.set_z(pos, pos.z + 20)

	local ext = corpse:interaction()

	if ext then
		pcall(ext.remove_interact, ext)
		pcall(ext.set_active, ext, false, true)
	end

	corpse:set_slot(0)
	managers.network:session():send_to_peers_synched("remove_corpse_by_id", corpse_data.u_id, false, 1)

	local carry = World:spawn_unit(Idstring(tweak_data.carry.person.unit), pos, Rotation())
	local dir = Vector3()

	managers.network:session():send_to_peers_synched("sync_carry_data", carry, "person", 1, false, false, 0, pos, dir, 0, nil, 0)
	managers.player:sync_carry_data(carry, "person", 1, false, false, 0, pos, dir, 0, nil, 0)

	movement._sh_bodybags = (movement._sh_bodybags or self.BODY_BAGS) - 1

	if movement._sh_bodybags == 0 then
		self:supply_hint(unit, "body bags")
	end

	local actor = self:actor()

	call_on_next_update(function()
		if not alive(unit) or not alive(carry) then
			return
		end

		carry:carry_data():link_to(unit)

		if UsefulBots.bag:request_body(unit, carry, actor) then
			StreamHeist:log("Stealth errand: %s carries a body bag (%d left) to where nobody finds it", self:name(unit), movement._sh_bodybags)
		else
			StreamHeist:log("Stealth errand: %s carries a body bag but could not be given the way to leave it, it drops it", self:name(unit))

			movement:throw_bag()
		end
	end)

	return true
end

function Interact:humans()
	local list = {}

	for _, u_data in pairs(managers.groupai:state():all_player_criminals()) do
		if alive(u_data.unit) then
			list[#list + 1] = u_data.unit
		end
	end

	return list
end

function Interact:human_busy(unit)
	local movement = unit:movement()

	if not movement then
		return false
	end

	if movement._interaction_tweak then
		return true
	end

	local state = movement.current_state and movement:current_state()

	if state and (state._interact_expire_t or state._use_item_expire_t) then
		return true
	end

	local damage_ext = unit:character_damage()

	return damage_ext and (damage_ext.need_revive and damage_ext:need_revive() or damage_ext.arrested and damage_ext:arrested() or damage_ext.dead and damage_ext:dead()) and true or false
end

function Interact:humans_away_or_busy(pos)
	for _, unit in ipairs(self:humans()) do
		if not self:human_busy(unit) and mvec3_dis(unit:movement():m_pos(), pos) <= self.PAGER_HUMAN_RANGE then
			return false
		end
	end

	return true
end

function Interact:free_bots(pos, max_dis, allow_guard)
	local list = {}

	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit

		if alive(unit) and not unit:movement():downed() and (not unit:movement()._sh_errand or allow_guard and unit:movement()._sh_errand.kind == "guard") and not UsefulBots.bag:active(unit) and not unit:movement()._sh_kill and not unit:movement():cool() then
			local dis = mvec3_dis(unit:movement():m_pos(), pos)

			if dis <= max_dis then
				list[#list + 1] = { unit = unit, dis = dis }
			end
		end
	end

	table.sort(list, function(a, b)
		return a.dis < b.dis
	end)

	return list
end

function Interact:add_order(unit, target, id)
	local movement = unit:movement()

	movement._sh_orders = movement._sh_orders or {}

	if not movement._sh_orders[target:key()] then
		StreamHeist:log("Stealth errand: %s does %s again and again while it waits", self:name(unit), id)
	end

	movement._sh_orders[target:key()] = { target = target, id = id }
end

function Interact:watch_orders(t)
	if not setting("auto_orders") then
		return
	end

	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit
		local movement = alive(unit) and unit:movement()
		local orders = movement and movement._sh_orders

		local patrol_ok = not managers.groupai:state():whisper_mode() or movement._sh_hold_mode == UsefulBots.hold.MODE_PATROL

		if orders and not movement._sh_errand and movement._should_stay and patrol_ok and not movement:downed() and not (UsefulBots.bag:active(unit)) then
			for key, order in pairs(orders) do
				if not alive(order.target) then
					orders[key] = nil
				elseif not self.claims[key] then
					local post = movement._should_stay_pos or movement:m_pos()
					local ok = self:check(order.target, unit)

					if ok and mvec3_dis(post, order.target:position()) <= self:range() and self:start(unit, order.target, "interact", "it waits and was told to", { standing = true }) then
						break
					end
				end
			end
		end
	end
end

function Interact:watch_pagers(t)
	if not setting("auto_pager") or not managers.groupai:state():whisper_mode() then
		return
	end

	for _, unit in ipairs(managers.interaction._interactive_units or {}) do
		if alive(unit) and not self.claims[unit:key()] then
			local ext = unit:interaction()

			if ext and ext.tweak_data == "corpse_alarm_pager" and ext:active() and not ext:disabled() and not ext._in_progress then
				local pos = unit:position()

				if not self.chains[unit:key()] and self:humans_away_or_busy(pos) then
					local free = self:free_bots(pos, self:range() * 2, true)

					if free[1] and self:check(unit, free[1].unit) then
						self:start(free[1].unit, unit, "pager", "no player can answer it now", { push = true })
					end
				end
			end
		end
	end
end

function Interact:on_civ_shout(bot, civ)
	if alive(civ) then
		self.civ_owners[civ:key()] = { bot = bot, t = TimerManager:game():time() }
	end
end

function Interact:tie_bot(civ, owner)
	local function able(unit)
		if not alive(unit) or unit:movement():downed() or unit:movement():cool() or UsefulBots.bag:active(unit) or unit:movement()._sh_kill then
			return false
		end

		local errand = unit:movement()._sh_errand

		if errand and errand.kind ~= "guard" then
			return false
		end

		return self:ties_left(unit) > 0
	end

	if able(owner) then
		return owner
	end

	for _, entry in ipairs(self:free_bots(civ:position(), self:range() * 2, true)) do
		if able(entry.unit) then
			return entry.unit
		end
	end
end

function Interact:tie_busy_near(civ)
	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit
		local errand = alive(unit) and unit:movement()._sh_errand

		if errand and errand.kind == "tie" and alive(errand.target) and mvec3_dis(errand.target:position(), civ:position()) <= self.GROUP_RADIUS then
			return true
		end
	end

	return false
end

function Interact:watch_civilians(t)
	local tie, guard = setting("auto_tie"), setting("auto_guard")

	if not (tie or guard) or not managers.groupai:state():whisper_mode() then
		return
	end

	local held = {}
	local seen = {}

	for _, civ in ipairs(self:civilians()) do
		if self:civ_held(civ) then
			held[#held + 1] = civ
			seen[civ:key()] = self.civ_seen[civ:key()] or t
		end
	end

	self.civ_seen = seen

	if tie then
		for _, civ in ipairs(held) do
			local key = civ:key()

			if not self.claims[key] and not self:tie_busy_near(civ) then
				local record = self.civ_owners[key]
				local owner = record and record.bot
				local why

				if alive(owner) then
					why = "it made the civilian surrender"
				elseif self:humans_away_or_busy(civ:position()) then
					why = "no player can tie it now"
				elseif t - seen[key] >= self.TIE_WAIT then
					why = "no player tied it for a while"
				end

				if why then
					local bot = self:tie_bot(civ, alive(owner) and owner or nil)

					if bot and self:check(civ, bot) then
						self:start(bot, civ, "tie", why)
					end
				end
			end
		end
	end

	if guard then
		self:assign_guards(held, t)
	end
end

function Interact:assign_guards(held, t)
	if #held == 0 then
		return
	end

	local civs = {}

	for _, civ in ipairs(self:civilians()) do
		if not self:civ_tied(civ) then
			civs[#civs + 1] = civ
		end
	end

	local visited = {}

	for _, seed in ipairs(held) do
		if not visited[seed:key()] then
			local group, queue = {}, { seed }

			visited[seed:key()] = true

			while #queue > 0 do
				local civ = table.remove(queue)

				group[#group + 1] = civ

				for _, other in ipairs(civs) do
					if not visited[other:key()] and mvec3_dis(civ:position(), other:position()) <= self.GROUP_RADIUS then
						visited[other:key()] = true
						queue[#queue + 1] = other
					end
				end
			end

			self:guard_group(group, t)
		end
	end
end

function Interact:guard_group(group, t)
	local centroid = Vector3()

	for _, civ in ipairs(group) do
		mvector3.add(centroid, civ:position())
	end

	mvector3.divide(centroid, #group)

	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit
		local errand = alive(unit) and unit:movement()._sh_errand

		if errand and errand.kind == "guard" and mvec3_dis(errand.anchor, centroid) <= self.GROUP_RADIUS then
			errand.group = group

			return
		end
	end

	if self:group_blocked(centroid, t) then
		return
	end

	local owner

	for _, civ in ipairs(group) do
		local record = self.civ_owners[civ:key()]

		if record and alive(record.bot) then
			owner = record.bot

			break
		end
	end

	local bot

	local function able(unit)
		return alive(unit) and not unit:movement():downed() and not unit:movement():cool() and not unit:movement()._sh_errand and not UsefulBots.bag:active(unit) and not unit:movement()._sh_kill
	end

	if able(owner) then
		bot = owner
	else
		local free = self:free_bots(centroid, self:range() * 2)

		bot = free[1] and free[1].unit
	end

	if not bot then
		return
	end

	local anchor_civ = group[1]
	local spots = self:guard_spots(centroid, group)

	self:start(bot, anchor_civ, "guard", "there are civilians that nobody tied", { group = group, anchor = centroid, stand = spots[1], spots = spots })
end

function Interact:guard_spots(centroid, group)
	local navman = managers.navigation
	local melee = UsefulBots.melee
	local candidates = {}
	local from = Vector3()

	for _ = 1, self.GUARD_SAMPLES do
		local pos = Vector3(math.random() * 2 - 1, math.random() * 2 - 1, 0)

		mvector3.normalize(pos)
		mvector3.multiply(pos, 300 + math.random() * 400)
		mvector3.add(pos, centroid)

		local tracker = navman:create_nav_tracker(pos)
		local spot = mvector3.copy(tracker:field_position())

		navman:destroy_nav_tracker(tracker)

		local sees = 0

		mvector3.set_static(from, spot.x, spot.y, spot.z + 150)

		for _, civ in ipairs(group) do
			if mvec3_dis(spot, civ:position()) <= melee.CIV_SHOUT_RANGE and not World:raycast("ray", from, civ:movement():m_head_pos(), "slot_mask", managers.slot:get_mask("AI_visibility"), "ray_type", "ai_vision", "report") then
				sees = sees + 1
			end
		end

		candidates[#candidates + 1] = { pos = spot, score = sees * 1000 - mvec3_dis(spot, centroid) }
	end

	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)

	local spots = {}

	for _, candidate in ipairs(candidates) do
		local apart = true

		for _, spot in ipairs(spots) do
			if mvec3_dis(spot, candidate.pos) < 300 then
				apart = false

				break
			end
		end

		if apart then
			spots[#spots + 1] = candidate.pos

			if #spots >= self.GUARD_SPOTS then
				break
			end
		end
	end

	return #spots > 0 and spots or { self:stand_position(group[1]) }
end

function Interact:watch_corpses(t)
	if not setting("auto_bodybag") or not managers.groupai:state():whisper_mode() then
		return
	end

	local corpses = managers.enemy and managers.enemy._enemy_data and managers.enemy._enemy_data.corpses

	if not corpses then
		return
	end

	local civilians = managers.enemy:all_civilians()
	local guard_corpse, civ_corpse

	for key, corpse_data in pairs(corpses) do
		local unit = corpse_data.unit

		local brain = unit:brain()
		local pager_live = brain and brain._alarm_pager_data

		if alive(unit) and not self.claims[key] and not pager_live then
			if civilians[key] then
				civ_corpse = civ_corpse or unit
			else
				guard_corpse = guard_corpse or unit
			end
		end
	end

	local corpse = guard_corpse or civ_corpse

	if not corpse then
		return
	end

	local pos = corpse:position()

	if not self:humans_away_or_busy(pos) then
		return
	end

	local free = self:free_bots(pos, self:range())
	local bot = free[1] and free[1].unit

	if bot and self:check(corpse, bot) then
		self:start(bot, corpse, "bodybag", "no player is free to bag it")
	end
end

function Interact:watch_seek(t)
	if not setting("auto_seek") or not managers.groupai:state():whisper_mode() then
		return
	end

	for _, unit in ipairs(managers.interaction._interactive_units or {}) do
		if alive(unit) and not self.claims[unit:key()] then
			local ext = unit:interaction()

			if ext and ext.tweak_data == "drill_jammed" and ext:active() and not ext:disabled() then
				local pos = unit:position()

				if self:humans_away_or_busy(pos) then
					local free = self:free_bots(pos, self:range())

					if free[1] and self:check(unit, free[1].unit) then
						self:start(free[1].unit, unit, "interact", "no player can fix it now")
					end
				end
			end
		end
	end
end

function Interact:on_dominate_try(bot, guard)
	if alive(guard) then
		self.dominators[guard:key()] = { bot = bot, guard = guard, t = TimerManager:game():time() }
	end
end

function Interact:on_guard_down(bot, guard, how)
	if not managers.groupai:state():whisper_mode() or not (setting("auto_pager") or setting("auto_bodybag")) then
		return
	end

	local key = guard:key()

	if self.chains[key] then
		return
	end

	self.chains[key] = { bot = bot, guard = guard, how = how, stage = "pager", t0 = TimerManager:game():time(), key = key }

	StreamHeist:log("Stealth errand: %s took a guard down (%s), the pager, the body and the stash are its job", self:name(bot), how)
end

function Interact:watch_dominators(t)
	for key, record in pairs(self.dominators) do
		local guard = record.guard
		local logic = alive(guard) and guard:brain() and guard:brain()._logic_data

		if not logic or t > record.t + 8 or guard:character_damage():dead() then
			self.dominators[key] = nil
		elseif logic.name == "intimidated" then
			self.dominators[key] = nil

			if alive(record.bot) then
				self:on_guard_down(record.bot, guard, "dominated")
			end
		end
	end
end

function Interact:chain_step(chain, t)
	local bot, guard = chain.bot, chain.guard
	local dead = guard:character_damage():dead()

	if chain.stage == "pager" then
		local ext = guard:interaction()
		local brain = guard:brain()
		local is_pager = ext and ext.tweak_data == "corpse_alarm_pager"
		local ringing = is_pager and ext:active() and not ext._in_progress
		local answering = is_pager and ext:active() and ext._in_progress
		local pending = guard:unit_data().has_alarm_pager and brain and brain._alarm_pager_data ~= nil
		local exhausted, count = self:pager_exhausted()

		if exhausted and (ringing or pending) and not answering then
			self.chains[chain.key] = nil

			StreamHeist:log("Stealth errand: %s leaves the pager of that guard alone, %d were answered, the next one is an alarm whatever a bot does", self:name(bot), count)

			return
		end

		if ringing and setting("auto_pager") then
			self:start(bot, guard, "pager", "it took the guard down", { push = true, chain = chain.key })

			return
		end

		if answering or pending and t < chain.t0 + self.PAGER_WAIT then
			return
		end

		chain.stage = chain.how == "dominated" and not dead and "kill" or "bag"
		chain.stage_t = t

		StreamHeist:log("Stealth errand: %s is done with the pager of that guard, next is %s", self:name(bot), chain.stage == "kill" and "killing it (it was dominated)" or "its body")

		return
	end

	if not setting("auto_bodybag") then
		self.chains[chain.key] = nil

		return
	end

	if chain.stage == "kill" then
		if dead then
			chain.stage = "bag"
			chain.stage_t = t

			return
		end

		if bot:movement()._sh_kill then
			return
		end

		if chain.kill_started and t > chain.stage_t + self.KILL_TIME + 5 then
			self.chains[chain.key] = nil

			return
		end

		local started, why = UsefulBots.melee:start_kill(bot, guard)

		if started then
			chain.kill_started = true
			chain.stage_t = t
		elseif not chain.kill_log_t or t >= chain.kill_log_t then
			chain.kill_log_t = t + 5

			StreamHeist:log("Stealth errand: %s can not kill the guard it dominated yet (%s)", self:name(bot), why or "?")
		end

		return
	end

	if not dead then
		self.chains[chain.key] = nil

		return
	end

	if (bot:movement()._sh_bodybags or self.BODY_BAGS) <= 0 then
		self.chains[chain.key] = nil

		StreamHeist:log("Stealth errand: %s has no body bags left", self:name(bot))

		return
	end

	local brain = guard:brain()

	if managers.enemy:get_corpse_unit_data_from_key(guard:key()) and not (brain and brain._alarm_pager_data) then
		if self:start(bot, guard, "bodybag", "it took the guard down", { chain = chain.key }) then
			self.chains[chain.key] = nil
		end
	end
end

function Interact:watch_chains(t)
	local whisper = managers.groupai:state():whisper_mode()

	for key, chain in pairs(self.chains) do
		if not whisper or not alive(chain.bot) or not alive(chain.guard) or t > chain.t0 + self.CHAIN_TIME or chain.bot:movement():downed() then
			self.chains[key] = nil
		elseif not self:active(chain.bot) then
			local ok, err = pcall(self.chain_step, self, chain, t)

			if not ok then
				self.chains[key] = nil

				StreamHeist:error("Interactions of bots: what a bot does with a guard it took down failed: %s", tostring(err))
			end
		end
	end
end

function Interact:update(t)
	if self._failed or not Network:is_server() or not managers.groupai then
		return
	end

	self:install_sound()

	if self._step_t and t < self._step_t then
		return
	end

	self._step_t = t + 0.1

	local ok, err = pcall(function()
		for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
			local unit = u_data.unit
			local errand = alive(unit) and unit:movement()._sh_errand

			if errand then
				self:step_errand(unit, errand, t)
			end
		end

		if not self._watch_t or t >= self._watch_t then
			self._watch_t = t + self.WATCH

			self:watch_dominators(t)
			self:watch_chains(t)
			self:watch_pagers(t)
			self:watch_corpses(t)
			self:watch_seek(t)
			self:watch_civilians(t)
			self:watch_orders(t)
		end
	end)

	if not ok then
		self._failed = true

		StreamHeist:error("Interactions of bots disabled until the next restart: %s", tostring(err))
	end
end

function Interact:command(bot, target)
	if not self:enabled() or not alive(bot) or bot:movement():downed() then
		return false
	end

	if managers.groupai:state():whisper_mode() and UsefulBots.stealth:enabled() and bot:movement():cool() then
		return false
	end

	local ok, result = self:check(target, bot)

	if not ok then
		StreamHeist:log("Stealth errand: %s is told to do something it does not do (%s)", self:name(bot), result)

		return false
	end

	local movement = bot:movement()
	local holding = movement._should_stay and true or false
	local kind = result == "corpse_dispose" and "bodybag" or result == "carry_pickup" and "pickup" or result == "intimidate" and "tie" or "interact"

	if holding and kind == "interact" and setting("auto_orders") then
		self:add_order(bot, target, result)
	end

	return self:start(bot, target, kind, holding and "it waits and was told to" or "it was told to", { standing = holding })
end

function Interact:request(bot, target)
	if Network:is_server() then
		return self:command(bot, target)
	end

	if not LuaNetworking or not LuaNetworking.SendToPeer or not (managers.network and managers.network:session()) then
		return
	end

	local name = managers.criminals:character_name_by_unit(bot)

	if name then
		LuaNetworking:SendToPeer(1, self.NET_ID, json.encode({ name = name, id = target:id() }))
	end
end

function Interact:receive_command(sender, data)
	local success, decoded = pcall(json.decode, data)

	if not success or type(decoded) ~= "table" or type(decoded.name) ~= "string" or type(decoded.id) ~= "number" then
		return
	end

	local bot = managers.criminals:character_unit_by_name(decoded.name)

	if not alive(bot) then
		return
	end

	local record = managers.groupai:state():all_criminals()[bot:key()]

	if not record or not record.ai then
		return
	end

	local session = managers.network:session()
	local peer = session and session:peer(sender)
	local peer_unit = peer and peer:unit()

	if not alive(peer_unit) or mvec3_dis(peer_unit:position(), bot:position()) > 5000 then
		return
	end

	for _, unit in ipairs(managers.interaction._interactive_units or {}) do
		if alive(unit) and unit:id() == decoded.id then
			self:command(bot, unit)

			return
		end
	end
end

if not Interact._net_hooked then
	Interact._net_hooked = true

	Hooks:Add("NetworkReceivedData", "NetworkReceivedDataStreamHeistInteract", function(sender, message_id, data)
		if message_id == Interact.NET_ID and Network:is_server() then
			UsefulBots.interact:receive_command(sender, data)
		end
	end)
end

function Interact:bot_sees(bot, target)
	local from = bot:movement():m_head_pos()
	local masks = { managers.slot:get_mask("AI_visibility"), managers.slot:get_mask("world_geometry") }
	local pos = target:position()
	local points = { Vector3(pos.x, pos.y, pos.z + 40) }
	local ok, center = pcall(function()
		return target:oobb():center()
	end)

	if ok and center then
		points[#points + 1] = center
	end

	for _, point in ipairs(points) do
		local blocked = false

		for _, mask in ipairs(masks) do
			if World:raycast("ray", from, point, "slot_mask", mask, "ray_type", "ai_vision", "ignore_unit", target, "report") then
				blocked = true

				break
			end
		end

		if not blocked then
			return true
		end
	end

	return false
end

function Interact:pointer_aim(ps, bot)
	local camera = ps._ext_camera
	local origin, fwd = camera:position(), camera:forward()
	local best, best_perp

	for _, unit in ipairs(managers.interaction._interactive_units or {}) do
		if alive(unit) then
			local ext = unit:interaction()

			if ext and ext:active() and not ext:disabled() then
				local rel = unit:position() - origin
				local along = mvector3.dot(rel, fwd)

				if along > 50 and along < self.POINTER_RANGE then
					local perp = mvec3_dis(rel, fwd * along)

					if perp < self.POINTER_TOLERANCE and (not best_perp or perp < best_perp) and self:bot_sees(bot, unit) then
						local ok, why, hard = self:check(unit, bot)

						if not hard then
							best, best_perp = unit, perp
						end
					end
				end
			end
		end
	end

	if not best then
		local far = origin + fwd * self.POINTER_RANGE
		local ok, hit = pcall(World.raycast, World, "ray", origin, far, "slot_mask", managers.slot:get_mask("world_geometry"))
		local hit_table = ok and hit and type(hit) == "table" and hit
		local aim = hit_table and hit_table.position or far

		if not self._pointer_log_t or TimerManager:game():time() > self._pointer_log_t then
			local dis = mvector3.distance(origin, aim)

			if dis < 3000 then
				self._pointer_log_t = TimerManager:game():time() + 1

				StreamHeist:log("Stealth errand: the pointer's empty-aim line reaches %.1f m (hit: %s)", dis / 100, hit_table and (hit_table.unit and tostring(hit_table.unit:name()) or "something with no unit") or "nothing, this is not where it should have stopped")
			end
		end

		return nil, aim
	end

	if not self._pointer_target_log_t or TimerManager:game():time() > self._pointer_target_log_t then
		local dis = mvector3.distance(origin, best:position())

		if dis < 3000 then
			self._pointer_target_log_t = TimerManager:game():time() + 1

			StreamHeist:log("Stealth errand: the pointer found a target %.1f m away: %s", dis / 100, tostring(best:name()))
		end
	end

	return best, best:position()
end


function Interact:pointer_hint(text)
	if text and text ~= self._hint then
		self._hint = text

		pcall(function()
			managers.hud:show_hint({ text = text, time = 2 })
		end)
	end
end

function Interact:pointer_input(ps, t, input)
	if not self:enabled() then
		return
	end

	local pointer = self.pointer

	if pointer then
		if input.btn_melee_press then
			self:pointer_confirm(ps)
		end

		input.btn_melee_press = nil
		input.btn_melee_release = nil

		return
	end

	if self._inject_release then
		self._inject_release = nil
		input.btn_melee_release = true

		return
	end

	local hold = self._hold

	if hold then
		input.btn_melee_press = nil

		if t > hold.t0 + 3 and not input.btn_meleet_state then
			self._hold = nil
		elseif input.btn_melee_release or not input.btn_meleet_state then
			self._hold = nil
			self._inject_release = true
			input.btn_melee_press = true
			input.btn_melee_release = nil
		elseif t >= hold.t0 + self.POINTER_HOLD then
			self._hold = nil
			self.pointer = { bot = hold.bot, t0 = t }

			StreamHeist:log("Stealth errand: the pointer is up for %s", self:name(hold.bot))
		end

		return
	end

	if input.btn_melee_press then
		local target = ps:sh_get_bot_target(true)
		local bot = target and target.unit

		if alive(bot) then
			self._hold = { bot = bot, t0 = t }
			input.btn_melee_press = nil
		end
	end
end

function Interact:pointer_confirm(ps)
	local pointer = self.pointer
	local target = pointer.target

	if not target then
		self.pointer = nil

		return
	end

	local ok, why = self:check(target, pointer.bot)

	if not ok then
		self:pointer_hint(why)

		return
	end

	self:request(pointer.bot, target)

	StreamHeist:log("Stealth errand: %s is pointed at %s", self:name(pointer.bot), target:carry_data() and "a bag" or tostring(target:interaction() and target:interaction().tweak_data))

	self.pointer = nil
end

function Interact:pointer_brushes()
	if self._brush_ok then
		return
	end

	self._brush_ok = Draw:brush(Color(1, 0.2, 1, 0.3), 0.1)
	self._brush_no = Draw:brush(Color(1, 1, 0.2, 0.2), 0.1)

	local ok, err = pcall(function()
		self._brush_ok:set_render_template(Idstring("OverlayVertexColor"))
		self._brush_no:set_render_template(Idstring("OverlayVertexColor"))
	end)

	if not ok then
		StreamHeist:error("Interactions of bots: the pointer could not be drawn over the walls, it is drawn the normal way: %s", tostring(err))
	end
end

function Interact:pointer_ring(brush, pos, camera)
	local rotation = camera:rotation()
	local right, up = rotation:x(), rotation:z()

	for _, radius in ipairs({ 34, 36, 38 }) do
		local previous

		for step = 0, 24 do
			local angle = step / 24 * 2 * math.pi
			local point = pos + right * (math.cos(angle) * radius) + up * (math.sin(angle) * radius)

			if previous then
				brush:line(previous, point)
			end

			previous = point
		end
	end

	brush:sphere(pos, 4)
end

function Interact:pointer_update(ps, t)
	local pointer = self.pointer

	if not pointer then
		return
	end

	local bot = pointer.bot

	if not alive(bot) or bot:movement():downed() or t > pointer.t0 + self.POINTER_TIMEOUT then
		self.pointer = nil

		return
	end

	local target, aim = self:pointer_aim(ps, bot)
	local ok, why = false, nil

	pointer.target = target

	if target then
		ok, why = self:check(target, bot)
		self:pointer_hint(not ok and why or nil)
	else
		self._hint = nil
	end

	local from = bot:movement():m_head_pos()
	local dir = aim - from

	mvector3.normalize(dir)

	self:pointer_brushes()

	local brush = target and ok and self._brush_ok or self._brush_no

	brush:line(from, aim)
	brush:cone(aim, aim - dir * 40, 14, 8)

	if target then
		self:pointer_ring(brush, target:position(), ps._ext_camera)
	end
end
