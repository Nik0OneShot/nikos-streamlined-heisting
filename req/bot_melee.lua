-- Stealth defense of awake bots: what the bots do when a guard has noticed something.
--
-- Bots never hunt unaware guards, those are left alone (and avoided, see bot_sneak.lua). An alerted guard that is "about to
-- fire" (its focus is a bot or a player) is dealt with by ONE bot, the rest stays hidden and keeps sneaking:
--   1. a bot that can dominate it right now (in range, same rules as Useful Bots) is chosen,
--   2. if nobody can: the nearest bot the guard has not noticed goes around it (crouched, out of view of every observer, see
--      Melee:plan_flank) to a spot behind it, where the game gives the guard a much lower chance to hold out ("flanked",
--      and "unaware of the aggressor"), and dominates it from there,
--   3. if there is no such bot or it fails: the nearest bot within reach charges.
-- Whoever is in charge tries to dominate (shout, up to two tries) and, if that does not work or is not possible, charges at
-- the guard and melees it, no matter if the guard has a pager (the melee of a bot kills at once in stealth, see
-- lua/copdamage.lua). Any bot melees an alerted guard that comes up to it, that is no going out of the way.
-- A guard that is calling the police (see Melee:guard_state) comes first and is different: there is no time to sneak around. The
-- nearest bot, whatever it does and whatever the guard knows about it, runs straight at it, shouts at it on the way (the shout
-- only uses the upper body) and melees it as soon as it is close.
-- A civilian that is calling the police gets the same bot, but only a shout: that puts it into the surrender logic within a
-- fraction of a second, which ends the call. It is never meleed (that would be a kill that costs money, and the shoot action of
-- a bot can not target a civilian anyway, bots do not detect them).
-- A civilian that runs away calls the police, a call is due 1 to 10 seconds after it was alerted (and it repeats). That civilian
-- is dealt with the same way before the phone act even starts, if no bot has it in shout range and in view yet (setting
-- stealth_civ_rush): the nearest bot goes at once, whatever it is doing and whoever may see it on the way. The call is what
-- ends the stealth, being seen is not, so that comes first.
-- A dominated (hands up), tied or dead guard is not a threat anymore.
-- Chases require a route through the bot's allowed rooms and open navigation.
-- Calling targets must also fit the estimated remaining call budget. Neither
-- restriction prevents a shout or melee that can already reach the target.
--
-- The bullets stay blocked while the heist is quiet (see bot_stealth.lua), only the melee attack of the shoot action is
-- used: it is started by hand here because the shoot action does nothing at all while firing is not allowed. The damage and
-- the animation are the ones of the game (weapon usage of the bot: melee_dmg, melee_speed, melee_retry_delay).
--
-- State: TeamAIMovement._sh_melee (table), _sh_engaged (time until which the bot is busy, the sneaking code stays out of it),
-- Melee._claims (guard -> the bot that is in charge of it)

UsefulBots.melee = UsefulBots.melee or {}

local Melee = UsefulBots.melee

-- From this far away a bot is given the guard as the target of its shoot action, so that the action is ready when the swing can
-- start: that is from about a meter (see Melee:strike), and the hit lands within the melee range of the weapon.
Melee.RANGE = 225
Melee.DOMINATE_TRIES = 2
Melee.TURN_RANGE = 130 -- closer than this (cm) a bot that does not face the guard stops and turns before it swings
Melee.DOMINATE_WAIT = 1.6 -- seconds between two tries, and until a charge starts after the last one
Melee.CLAIM_T = 1.5 -- a claim runs out if the bot in charge does not renew it for this long
Melee.FAIL_T = 10 -- a bot that failed to go around a guard is not chosen for it again for this long
Melee.FLANK_MAX = 3000 -- a bot that is farther from the guard does not go around it
Melee.FLANK_MIN = 260 -- the game counts a guard as flanked from 2.5 m on
Melee.FLANK_ARC = 55 -- degrees to each side of straight behind the guard (the game wants more than 120 from its front)
Melee.FLANK_SAMPLES = 32
Melee.FLANK_TESTS = 8 -- how many of the spots (nearest first) are checked in detail
Melee.FLANK_WAIT = 5 -- seconds a bot waits for a safe way before it gives up going around
Melee.PLAN_T = 1
Melee.CIV_SHOUT_RANGE = 900 -- the game lets a shout reach civilians up to 10 m
Melee.CIV_SHOUTS = 3

-- Estimates, not engine deadlines: calls finish at an animation event. Claude's
-- pending/started states start this budget once; polling must never renew it.
Melee.CALL_ESTIMATE = 4
Melee.KILL_TIME = 20 -- seconds a bot has to kill a guard it dominated
Melee.PRE_CALL_ESTIMATE = 1
Melee.INTERCEPT_MARGIN = 0.75
Melee.CHASE_STUCK_T = 3
Melee.CHASE_RECHECK_T = 0.75

Melee._claims = Melee._claims or {}
Melee._call_logged = Melee._call_logged or {}
Melee._call_windows = Melee._call_windows or {}
Melee._pursuits = Melee._pursuits or {}

local mvec3_dis = mvector3.distance


function Melee:safe(name, func, ...)
	if self._failed then
		return
	end

	local success, result = pcall(func, self, ...)
	if not success then
		self._failed = true
		StreamHeist:error("Stealth defense of bots disabled until the next restart, error in %s: %s", name, tostring(result))
		return
	end

	return result
end

function Melee:bot_name(unit)
	return UsefulBots.hold:bot_name(unit)
end

function Melee:dominate_range()
	return tweak_data.player.long_dis_interaction.intimidate_range_enemies * 0.75
end

-- Close defense does not require a walkable route, but still requires sight and
-- the real action range. The wider RANGE is only for preparing a shoot action.
function Melee:can_melee_here(data, guard)
	local action = data.unit:movement()._active_actions and data.unit:movement()._active_actions[3]
	local usage = action and action._w_usage_tweak
	local range = ((usage and usage.melee_range) or 125) * 0.8
	local a, b = data.unit:movement():m_head_pos(), guard:movement():m_head_pos()
	local dx, dy = a.x - b.x, a.y - b.y
	return math.abs(a.z - b.z) <= 200 and dx * dx + dy * dy <= range * range and self:has_los(data, guard)
end

function Melee:can_act_here(data, target, info)
	local st = data.unit:movement()._sh_melee
	local tries = st and st.key == target:key() and st.tries or 0
	local dis = mvec3_dis(data.m_pos, target:movement():m_pos())
	if info.civilian then
		return tries < self.CIV_SHOUTS and dis <= self.CIV_SHOUT_RANGE and self:can_shout_civilian(target) and self:has_los(data, target)
	end
	return self:can_melee_here(data, target) or tries < self.DOMINATE_TRIES and dis <= self:dominate_range() and self:has_los(data, target) and self:can_dominate(data, target, info, dis)
end

function Melee:call_deadline(target, info)
	local key = target:key()
	if not info.calling then
		self._call_windows[key] = nil
		return
	end
	local now = TimerManager:game():time()
	local window = self._call_windows[key]
	if not window or window.logic ~= info.logic_data.internal_data then
		window = { logic = info.logic_data.internal_data, deadline = now + self.CALL_ESTIMATE + (info.call_started and 0 or self.PRE_CALL_ESTIMATE) }
		self._call_windows[key] = window
	end
	if info.call_started and not window.started then
		window.started = true
		window.deadline = math.min(window.deadline, now + self.CALL_ESTIMATE)
	end
	return window.deadline
end

-- The bot's permitted room (when holding), its current room, and Claude's
-- connected navigation rooms all matter. Even two points in one room can be
-- separated by a shut door. Do not use spot_reachable's fail-open fallback.
function Melee:can_pursue(data, target, info)
	local ok, result = pcall(self.check_pursuit, self, data, target, info)
	if not ok and not self._pursuit_error_logged then
		self._pursuit_error_logged = true
		StreamHeist:error("Stealth defense: could not verify a chase route; ignoring it: %s", tostring(result))
	end
	return ok and result or false
end

function Melee:check_pursuit(data, target, info)
	local movement = data.unit:movement()
	local tracker, target_tracker = movement:nav_tracker(), target:movement():nav_tracker()
	if not tracker or not target_tracker or tracker:lost() or target_tracker:lost() then
		return false
	end
	local nav, sneak = UsefulBots.nav, UsefulBots.sneak
	if not nav then
		return false
	end
	local now = TimerManager:game():time()
	local from_seg, to_seg = tracker:nav_segment(), target_tracker:nav_segment()
	local pos = target:movement():m_pos()
	local room = UsefulBots.hold:anchor_room(movement)
	if from_seg ~= to_seg and not UsefulBots.hold:in_room(room, pos) then
		return false
	end
	local key, bot_key = target:key(), data.unit:key()
	self._pursuits[key] = self._pursuits[key] or {}
	local cache = self._pursuits[key][bot_key]
	if not cache or cache.room ~= room or cache.from_seg ~= from_seg or cache.to_seg ~= to_seg or cache.epoch ~= nav.epoch or cache.link_epoch ~= nav.link_epoch or mvec3_dis(cache.target_pos, pos) > 100 then
		cache = { room = room, from_seg = from_seg, to_seg = to_seg, epoch = nav.epoch, link_epoch = nav.link_epoch, target_pos = mvector3.copy(pos) }
		self._pursuits[key][bot_key] = cache
	end
	if cache.blocked_until and now < cache.blocked_until then
		return false
	end
	local st = movement._sh_melee
	if st and st.charge_key == key and data.objective and data.objective.sh_charge then
		if not st.progress_pos or mvec3_dis(data.m_pos, st.progress_pos) >= 75 then
			st.progress_pos, st.progress_t = mvector3.copy(data.m_pos), now
		elseif now - st.progress_t >= self.CHASE_STUCK_T and not st.hold_until then
			cache.blocked_until = now + self.FAIL_T
			StreamHeist:log("Stealth defense: %s ignores an unreachable target (no chase progress)", self:bot_name(data.unit))
			return false
		end
	end
	if not cache.checked_t or now - cache.checked_t >= self.CHASE_RECHECK_T or mvec3_dis(cache.from_pos, data.m_pos) > 100 then
		cache.checked_t, cache.from_pos = now, mvector3.copy(data.m_pos)
		cache.length = nil
		local path = nav:coarse_path(data, from_seg, to_seg, data.m_pos, pos)
		if path then
			local previous, length = data.m_pos, 0
			for i = 2, #path do
				local entry = path[i][3] or path[i][2]
				if room and path[i][1] ~= from_seg and not UsefulBots.hold:in_room(room, path[i][2]) or nav:line_shut(previous, entry) then
					return false
				end
				length = length + mvec3_dis(previous, entry)
				previous = entry
			end
			if not nav:line_shut(previous, pos) then
				cache.length = length + mvec3_dis(previous, pos)
			end
		end
	end
	if not cache.length then
		return false
	end
	local deadline = self:call_deadline(target, info)
	-- Room/door route length, with a detour allowance and time to stop the call.
	local eta = cache.length * 1.25 / math.max(sneak:run_speed(data), 1) + self.INTERCEPT_MARGIN
	return not deadline or now + eta < deadline
end

function Melee:eligible(data, target, info)
	return self:can_act_here(data, target, info) or self:can_pursue(data, target, info)
end


-- Guards

-- nil if the unit is no threat (unaware, dead, tied, dominated), otherwise a table with what it is up to
function Melee:guard_state(guard)
	if not alive(guard) or guard:movement():cool() then
		return
	end

	local damage_ext = guard:character_damage()
	if damage_ext and damage_ext:dead() then
		return
	end

	local anim_data = guard:anim_data()
	if anim_data.hands_tied or anim_data.hands_back or anim_data.hands_up or anim_data.surrender then
		return
	end

	local brain = guard:brain()
	local logic_data = brain and brain._logic_data
	if not logic_data or logic_data.name == "intimidated" or logic_data.name == "trade" or logic_data.name == "inactive" then
		return
	end

	-- about to fire: alerted, and its focus is a bot or a player
	local focus = logic_data.attention_obj
	local about_to_fire = focus and alive(focus.unit) and focus.reaction >= AIAttentionObject.REACT_SHOOT and managers.groupai:state():all_criminals()[focus.unit:key()] and true or false

	-- calling the police: a guard that is alerted but has nothing to shoot at goes into the arrest logic, where it plays a call
	-- animation (it can not do anything else meanwhile) and the police is called halfway through it. The call starts a moment
	-- after the guard entered that logic: a guard that is going to is counted too, that is time to get there
	local state = managers.groupai:state()
	local internal_data = logic_data.internal_data
	local call_started = internal_data and internal_data.calling_the_police and true or false
	local calling = logic_data.name == "arrest" and (call_started or logic_data.char_tweak and logic_data.char_tweak.calls_in and state:can_police_be_called()) and not state:is_police_called() and true or false

	return {
		about_to_fire = about_to_fire,
		calling = calling,
		call_started = call_started,
		logic_data = logic_data
	}
end

-- nil if the civilian is no threat, otherwise a table like the one of guard_state. A civilian that is alerted runs away (flee
-- logic) and, if it is one that calls in, a call is due a few seconds after that (call_police_clbk_id): it plays a phone act
-- (calling_the_police) and the police is called halfway through it. It is a threat when the act has started, and (setting) when the
-- call is due and no bot is where a shout reaches it yet
function Melee:civilian_state(civ, get_bots)
	if not alive(civ) or civ:movement():cool() then
		return
	end

	local damage_ext = civ:character_damage()
	if damage_ext and damage_ext:dead() then
		return
	end

	local brain = civ:brain()
	local logic_data = brain and brain._logic_data
	local internal_data = logic_data and logic_data.internal_data

	if not logic_data or logic_data.name ~= "flee" or not internal_data then
		return
	end

	if civ:anim_data().hands_tied or managers.groupai:state():is_police_called() then
		return
	end

	local started = internal_data.calling_the_police and true or false

	if not started then
		local due = internal_data.call_police_clbk_id and true or false

		if not due or not UsefulBots.settings.stealth_civ_rush or not self:can_shout_civilian(civ) then
			return
		end

		-- a bot that was sent stays until the civilian gave up, otherwise it would be sent home the moment it gets there
		if not self._claims[civ:key()] and self:civ_covered(civ, get_bots()) then
			return
		end
	end

	return {
		calling = true,
		call_started = started,
		civilian = true,
		logic_data = logic_data
	}
end

-- Is a bot where a shout reaches the civilian (in range and in view)
function Melee:civ_covered(civ, bots)
	local civ_pos = civ:movement():m_pos()

	for _, bot in ipairs(bots) do
		if mvec3_dis(bot.data.m_pos, civ_pos) <= self.CIV_SHOUT_RANGE and self:has_los(bot.data, civ) then
			return true
		end
	end

	return false
end

-- The same rules the game (and Useful Bots) have for who can be shouted at
function Melee:can_shout_civilian(civ)
	local tweak = tweak_data.character[civ:base()._tweak_table]

	return tweak and tweak.intimidateable and not civ:base().unintimidateable and not civ:anim_data().unintimidateable and not civ:unit_data().disable_shout and not civ:brain():is_tied() and true or false
end

-- What a bot does when it shouts at a civilian, the civilian is told with the full strength
function Melee:shout_civilian(data, civ)
	if data.unit:movement():chk_action_forbidden("action") then
		return false
	end

	local anim_data = civ:anim_data()

	data.unit:sound():say(anim_data.drop and "f03a_sin" or "f02x_sin", true)
	data.unit:brain():action_request({
		align_sync = true,
		body_part = 3,
		type = "act",
		variant = anim_data.move and "gesture_stop" or "arrest"
	})
	civ:brain():on_intimidated(1, data.unit)

	-- what the bot does with a civilian it made surrender is looked after in req/bot_interact.lua
	if UsefulBots.interact then
		pcall(UsefulBots.interact.on_civ_shout, UsefulBots.interact, data.unit, civ)
	end

	return true
end

-- Get to the civilian and shout at it (up to a few times, from where it is in range and the bot can see it)
function Melee:stop_civilian_call(data, civ, st, dis)
	local unit = data.unit

	if not self:can_shout_civilian(civ) then
		if not st.no_shout_logged then
			st.no_shout_logged = true

			StreamHeist:log("Stealth defense: %s can not stop a civilian that is calling the police, it can not be shouted at", self:bot_name(unit))
		end

		return
	end

	if dis <= self.CIV_SHOUT_RANGE and st.tries < self.CIV_SHOUTS and (not st.try_t or data.t > st.try_t) and self:has_los(data, civ) and self:shout_civilian(data, civ) then
		st.tries = st.tries + 1
		st.try_t = data.t + self.DOMINATE_WAIT

		StreamHeist:log("Stealth defense: %s shouts at a civilian that is calling the police (try %d, %.1f m)", self:bot_name(unit), st.tries, dis / 100)
	end

	-- keep going until it is close: a shout does not get around corners
	if dis > 300 then
		return self:charge(data, civ, st)
	end
end

-- Has the guard noticed the unit (a bot)
function Melee:detected_by(guard, unit)
	local brain = guard:brain()
	local logic_data = brain and brain._logic_data
	local info = logic_data and logic_data.detected_attention_objects and logic_data.detected_attention_objects[unit:key()]

	return info and (info.identified or (info.notice_progress or 0) > 0.05) and true or false
end

-- The alerted guards that are about to fire, checked every quarter of a second
function Melee:threats()
	local t = TimerManager:game():time()
	if self._threats and t < self._threats_t + 0.25 then
		return self._threats
	end

	local list = {}
	local keys = {}

	-- the bots that can take part, only looked at if a civilian needs it
	local bots
	local function get_bots()
		bots = bots or self:ready_bots()

		return bots
	end

	local function add(unit, info)
		self:call_deadline(unit, info)
		table.insert(list, { guard = unit, info = info })
		keys[unit:key()] = true

		if info.calling and not self._call_logged[unit:key()] then
			self._call_logged[unit:key()] = true

			StreamHeist:log("Stealth defense: %s is calling the police (%s)", info.civilian and "a civilian" or "a guard", info.call_started and "the call has started" or "it is about to")
		end
	end

	for _, u_data in pairs(managers.enemy:all_enemies()) do
		local guard = u_data.unit
		local info = alive(guard) and self:guard_state(guard)

		if info and (info.about_to_fire or info.calling) then
			add(guard, info)
		end
	end

	for _, u_data in pairs(managers.enemy:all_civilians()) do
		local civ = u_data.unit
		local info = alive(civ) and self:civilian_state(civ, get_bots)

		if info then
			add(civ, info)
		end
	end

	-- claims of guards that are no threat anymore
	for key in pairs(self._claims) do
		if not keys[key] then
			self._claims[key] = nil
		end
	end

	for key in pairs(self._call_logged) do
		if not keys[key] then
			self._call_logged[key] = nil
		end
	end
	for key in pairs(self._call_windows) do
		if not keys[key] then
			self._call_windows[key] = nil
		end
	end
	for key in pairs(self._pursuits) do
		if not keys[key] then
			self._pursuits[key] = nil
		end
	end

	self._threats = list
	self._threats_t = t

	return list
end

-- The alerted guard that is right next to the bot, whatever it is up to
function Melee:close_guard(data)
	local best, best_dis

	for _, u_data in pairs(managers.enemy:all_enemies()) do
		local guard = u_data.unit
		local dis = alive(guard) and mvec3_dis(data.m_pos, guard:movement():m_pos())

		if dis and dis <= self.RANGE * 1.5 and (not best_dis or dis < best_dis) and self:guard_state(guard) and self:can_melee_here(data, guard) then
			best, best_dis = guard, dis
		end
	end

	return best, best_dis
end


-- Who is in charge

-- The logic data of the bot if it can take part, false otherwise
function Melee:ready(unit)
	if not alive(unit) or not UsefulBots.stealth:holds_fire(unit) then
		return false
	end

	local damage_ext = unit:character_damage()
	if damage_ext and (damage_ext:need_revive() or damage_ext:dead() or damage_ext:arrested()) then
		return false
	end

	local brain = unit:brain()

	return brain and brain._logic_data or false
end

function Melee:ready_bots()
	local list = {}

	for _, u_data in pairs(managers.groupai:state():all_AI_criminals()) do
		local unit = u_data.unit
		local data = self:ready(unit)

		if data then
			table.insert(list, { key = unit:key(), unit = unit, data = data })
		end
	end

	return list
end

-- The claim of the guard: the one bot that deals with it (renewed by that bot every time it is busy with the guard)
function Melee:responder(guard, info)
	local key = guard:key()
	local now = TimerManager:game():time()
	local claim = self._claims[key]
	local old_bot = claim and claim.bot

	-- a guard that starts to call the police needs the nearest bot: the claim is chosen again
	local old_data = claim and self:ready(claim.unit)
	if claim and now - claim.t < self.CLAIM_T and claim.calling == info.calling and old_data and self:eligible(old_data, guard, info) then
		return claim
	end

	local failed = claim and claim.failed or {}
	local settings = UsefulBots.settings
	local g_pos = guard:movement():m_pos()
	local dominate_range = self:dominate_range()
	local charge_max = settings.stealth_civ_radius * 100
	local bots = self:ready_bots()
	for i = #bots, 1, -1 do
		if not self:eligible(bots[i].data, guard, info) then
			table.remove(bots, i)
		end
	end

	claim = { t = now, failed = failed, calling = info.calling }

	local best_dis

	-- 0. a guard that is calling the police: the nearest bot, no matter what it is doing, there is no time for anything else
	if info.calling then
		for _, bot in ipairs(bots) do
			local dis = mvec3_dis(bot.data.m_pos, g_pos)

			if dis <= self.FLANK_MAX and (not best_dis or dis < best_dis) then
				claim.bot, claim.unit, claim.role, best_dis = bot.key, bot.unit, "call", dis
			end
		end
	end

	-- 1. someone who can dominate it right now

	for _, bot in ipairs(bots) do
		local dis = mvec3_dis(bot.data.m_pos, g_pos)

		if not info.civilian and dis <= dominate_range and (not best_dis or dis < best_dis) and self:can_dominate(bot.data, guard, info, dis) and self:has_los(bot.data, guard) then
			claim.bot, claim.unit, claim.role, best_dis = bot.key, bot.unit, "dominate", dis
		end
	end

	-- 2. nobody can: a bot the guard has not noticed goes around it
	if not claim.bot and settings.stealth_flank then
		for _, bot in ipairs(bots) do
			local dis = mvec3_dis(bot.data.m_pos, g_pos)
			local failed_t = failed[bot.key]

			if dis <= self.FLANK_MAX and (not best_dis or dis < best_dis) and not (failed_t and now - failed_t < self.FAIL_T) and not self:detected_by(guard, bot.unit) then
				claim.bot, claim.unit, claim.role, best_dis = bot.key, bot.unit, "flank", dis
			end
		end
	end

	-- 3. the nearest bot within reach charges
	if not claim.bot then
		for _, bot in ipairs(bots) do
			local dis = mvec3_dis(bot.data.m_pos, g_pos)

			if dis <= charge_max and (not best_dis or dis < best_dis) then
				claim.bot, claim.unit, claim.role, best_dis = bot.key, bot.unit, "charge", dis
			end
		end
	end

	if not claim.bot then
		self._claims[key] = nil
		if old_bot then
			StreamHeist:log("Stealth defense: leaves a target alone (no bot can reach it in its domain and call budget, or act from here)")
		end
		return
	end

	self._claims[key] = claim

	if claim.bot ~= old_bot then
		StreamHeist:log("Stealth defense: %s is in charge of a guard (%s), %d guards to deal with, %d bots can take part", self:bot_name(claim.unit), claim.role, #self:threats(), #bots)
	end

	return claim
end

-- The guard this bot is in charge of (the nearest one if it is more than one)
function Melee:assignment(data)
	local key = data.unit:key()
	local best, best_info, best_claim, best_dis

	for _, threat in ipairs(self:threats()) do
		local dis = mvec3_dis(data.m_pos, threat.guard:movement():m_pos())

		-- a guard that is calling the police comes first, then the nearest one
		local better = not best or threat.info.calling and not best_info.calling or threat.info.calling == best_info.calling and dis < best_dis

		if better then
			local claim = self:responder(threat.guard, threat.info)

			if claim and claim.bot == key then
				best, best_info, best_claim, best_dis = threat.guard, threat.info, claim, dis
			end
		end
	end

	return best, best_info, best_claim, best_dis
end


-- Actions

function Melee:can_dominate(data, guard, info, dis)
	if not data.unit:base().upgrade_level or not data.unit:base():upgrade_level("player", "intimidate_enemies") then
		return false
	end

	-- the same rules as the domination of Useful Bots, that one is blocked in stealth otherwise
	data._sh_force_dominate = true
	local valid = TeamAILogicIdle.is_valid_intimidation_target(info.logic_data, data, dis)
	data._sh_force_dominate = nil

	return valid and true or false
end

function Melee:has_los(data, guard)
	return not World:raycast("ray", data.unit:movement():m_head_pos(), guard:movement():m_head_pos(), "slot_mask", managers.slot:get_mask("AI_visibility"), "ray_type", "ai_vision", "report")
end

function Melee:dominate(data, guard)
	if data.unit:movement():chk_action_forbidden("action") then
		return false
	end

	TeamAILogicIdle.intimidate_cop(data, guard)
	data._next_intimidate_t = data.t + tweak_data.player.movement_state.interaction_delay

	-- what the bot does with a guard it dominates is looked after in req/bot_interact.lua
	if UsefulBots.interact then
		pcall(UsefulBots.interact.on_dominate_try, UsefulBots.interact, data.unit, guard)
	end

	return true
end

-- Run at the guard, the objective is a normal one, the bot goes back to what it did once it is done
function Melee:charge(data, guard, st)
	local key = guard:key()
	-- Close-range permission to shout must never become permission to chase.
	if not st.info or not self:can_pursue(data, guard, st.info) then
		return false
	end

	if st.charge_key == key and data.objective and data.objective.sh_charge and st.charge_pos and mvec3_dis(st.charge_pos, guard:movement():m_pos()) < 100 then
		return false
	end

	local tracker = guard:movement():nav_tracker()
	if st.charge_key ~= key or not st.progress_pos then
		st.progress_pos, st.progress_t = mvector3.copy(data.m_pos), data.t
	end
	st.charge_key = key
	st.charge_t = data.t
	st.charge_pos = mvector3.copy(guard:movement():m_pos())

	self:stop_flank(data, st)
	UsefulBots.sneak:release(data.unit)

	data.brain:set_objective({
		type = "free",
		pos = mvector3.copy(tracker:field_position()),
		nav_seg = tracker:nav_segment(),
		haste = "run",
		pose = "stand",
		sh_charge = true
	})

	StreamHeist:log("Stealth defense: %s charges at a guard (%.1f m)", self:bot_name(data.unit), mvec3_dis(data.m_pos, guard:movement():m_pos()) / 100)

	return true
end

function Melee:strike(data, guard, st)
	local unit = data.unit
	local movement = unit:movement()
	st = st or movement._sh_melee or {}
	local action = movement._active_actions and movement._active_actions[3]

	-- a swing is under way: the bot stands still (see below), the hit comes a moment after the start
	if unit:anim_data().melee or st.strike_t and data.t < st.strike_t + 1 then
		return
	end

	-- the shoot action needs the guard as its target
	if not action or action:type() ~= "shoot" or not action._attention or action._attention.unit ~= guard then
		if unit:movement():chk_action_forbidden("action") or unit:anim_data().reload then
			return
		end

		local ok_att, err_att = pcall(CopLogicBase._set_attention, data, { unit = guard, u_key = guard:key(), reaction = AIAttentionObject.REACT_SHOOT }, AIAttentionObject.REACT_SHOOT)

		if not ok_att and not self._attention_error_logged then
			self._attention_error_logged = true

			StreamHeist:error("Stealth defense: could not aim a bot at the guard it dominated: %s", tostring(err_att))
		end

		local ok_req, requested = pcall(function()
			return unit:brain():action_request({ body_part = 3, type = "shoot" })
		end)

		if not ok_req and not self._shoot_request_error_logged then
			self._shoot_request_error_logged = true

			StreamHeist:error("Stealth defense: could not ask a bot for a shoot action: %s", tostring(requested))
		end

		if not st.no_action_t or data.t >= st.no_action_t then
			st.no_action_t = data.t + 2

			StreamHeist:log("Stealth defense: %s still has no shoot action to swing with (attention set: %s, action asked for: %s)", self:bot_name(unit), ok_att and "yes" or "no", ok_req and tostring(requested) or "error")
		end

		return
	end

	-- the melee weapon of the bot has to have an animation
	local melee_weapon = unit:base():melee_weapon()
	if melee_weapon ~= "weapon" and melee_weapon ~= "bash" and not tweak_data.weapon.npc_melee[melee_weapon] then
		if not self._no_melee_logged then
			self._no_melee_logged = true
			StreamHeist:warn("Stealth defense: bots can not melee with %s", tostring(melee_weapon))
		end

		return
	end

	local guard_pos = guard:movement():m_pos()
	local target_pos = guard:movement():m_head_pos()

	-- a dominated guard is bent over with its hands up, not standing the way m_head_pos() assumes (a fixed height offset, not its
	-- real current pose) - aimed at roughly chest height instead: 60% of the way from its feet to that (wrong, standing) head
	-- guess, close enough to hit reliably without needing its real bone position. This also lowers where the swing visibly aims,
	-- since this is the same position the shoot/melee action uses for its own aiming - a normal fight is never affected
	local guard_anim = guard:anim_data()
	local guard_brain = guard:brain()
	local guard_logic = guard_brain and guard_brain._logic_data
	local dominated = guard_anim.hands_up or guard_anim.surrender or (guard_logic and guard_logic.name == "intimidated") and true or false

	if dominated then
		target_pos = mvector3.copy(target_pos)

		mvector3.set_z(target_pos, guard_pos.z + (target_pos.z - guard_pos.z) * 0.6)
	end

	local dis = mvec3_dis(action._shoot_from_pos, target_pos)

	-- How far the guard is in front of the bot (1 = straight ahead)
	local dx, dy = guard_pos.x - data.m_pos.x, guard_pos.y - data.m_pos.y
	local flat = math.sqrt(dx * dx + dy * dy)
	local fwd = movement:m_fwd()
	local dot = flat > 1 and (fwd.x * dx + fwd.y * dy) / flat or 1

	-- The hit of this mod (anim_clbk_melee_strike in lua/copactionshoot.lua) does nothing at all unless the guard is within about
	-- a meter and IN FRONT of the bot when it comes, a moment after the swing started. A bot that ran on during the swing was past
	-- the guard by then, that is a swing without damage. So: a bot that does not face the guard stands still and turns first (1.5 s
	-- at most), and once the swing has started it stands still until the hit is over.
	if dis <= self.TURN_RANGE and dot < 0.7 and (not st.turn_t or data.t < st.turn_t + 1.5) then
		st.turn_t = st.turn_t or data.t

		UsefulBots.sneak:hold_still(data, true)
		st.hold_until = data.t + 0.8

		if not data.internal_data.turning then
			local success, result = pcall(CopLogicAttack._chk_request_action_turn_to_enemy, data, data.internal_data, data.m_pos, guard_pos)

			if not success and not self._turn_error_logged then
				self._turn_error_logged = true
				StreamHeist:error("Stealth defense: a bot could not turn to a guard: %s", tostring(result))
			end
		end

		return
	end

	-- The melee start of this mod (lua/copactionshoot.lua, it replaces the one of the game): the time, the distance to the target and
	-- its position. It only starts the swing from about a meter away (0.8 of the melee range of the weapon) and sends the network
	-- message itself. (The one of the game takes a single argument, whether the call was synchronised: calling this one like that
	-- crashed on its first line.) An error in there must not switch the whole defense off, it is logged once
	local success, started = pcall(action._chk_start_melee, action, TimerManager:game():time(), dis, target_pos)

	if not success then
		st.strike_t = data.t

		if not self._strike_error_logged then
			self._strike_error_logged = true
			StreamHeist:error("Stealth defense: the melee of a bot failed: %s", tostring(started))
		end

		return
	end

	if started then
		st.strike_t = data.t
		st.turn_t = nil
		st.swing_guard = guard
		st.swing_dis = dis
		st.swing_dot = dot

		UsefulBots.sneak:hold_still(data, true)
		st.hold_until = data.t + 1.3

		StreamHeist:log("Stealth defense: %s swings at a guard (%.1f m away, %d%% in front of it)", self:bot_name(unit), dis / 100, math.max(0, dot) * 100)
	end
end


-- Going around a guard

local tmp_vec1 = Vector3()

-- Spots behind the guard, in range of a domination, that the bot gets to unseen and where nobody sees it (the guards that
-- are alerted count as observers here: they notice a bot at once if it is in their view). Nearest first. Returns
-- { pos, mode } with mode "dash" (run there) or "walk" (crouched), nil if there is none right now
function Melee:plan_flank(data, guard)
	local sneak = UsefulBots.sneak
	local navman = managers.navigation
	local movement = guard:movement()
	local g_pos = movement:m_pos()
	local g_head = movement:m_head_pos()
	local fwd = movement:m_fwd()
	local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)

	if len < 0.01 then
		return
	end

	local back_x, back_y = -fwd.x / len, -fwd.y / len
	local range = self:dominate_range() * 0.9
	local candidates = {}

	local detection = sneak:detection_of(guard)
	local guard_angle_max = detection and detection.angle_max or 120

	for _ = 1, self.FLANK_SAMPLES do
		local radius = math.lerp(self.FLANK_MIN, range, math.random())

		-- a guard sees what is inside of its view angle, and the angle is wide close by: only the part of the arc behind the
		-- guard that is outside of it is of use (the exact check comes later, this just keeps the samples from being wasted)
		local arc = math.min(self.FLANK_ARC, 176 - math.lerp(180, guard_angle_max, math.clamp((radius - 150) / 700, 0, 1)))

		if arc > 2 then
			local a = math.rad((math.random() * 2 - 1) * arc)

			mvector3.set_static(tmp_vec1, g_pos.x + (back_x * math.cos(a) - back_y * math.sin(a)) * radius, g_pos.y + (back_x * math.sin(a) + back_y * math.cos(a)) * radius, g_pos.z)

			local tracker = navman:create_nav_tracker(tmp_vec1)
			local pos = mvector3.copy(tracker:field_position())
			navman:destroy_nav_tracker(tracker)

			local dis = mvec3_dis(pos, g_pos)

			if dis >= self.FLANK_MIN and dis <= range and math.abs(pos.z - g_pos.z) < 200 then
				-- the bot has to see the guard from there
				mvector3.set(tmp_vec1, pos)
				mvector3.set_z(tmp_vec1, pos.z + sneak:head_height(true))

				if UsefulBots.hold:in_room(UsefulBots.hold:anchor_room(data.unit:movement()), pos) and sneak:spot_reachable(data, pos) and not World:raycast("ray", tmp_vec1, g_head, "slot_mask", managers.slot:get_mask("AI_visibility"), "ray_type", "ai_vision", "report") then
					table.insert(candidates, { pos = pos, dis = mvec3_dis(data.m_pos, pos) })
				end
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.dis < b.dis
	end)

	local walk_speed = sneak:walk_speed(data, true)

	return sneak:with_extra_observers(sneak:alerted_observers(), function()
		for i = 1, math.min(#candidates, self.FLANK_TESTS) do
			local c = candidates[i]

			if sneak:dash_safe(data, c.pos, true) then
				return { pos = c.pos, mode = "dash" }
			end

			if not sneak:exposed(c.pos, true, c.dis / walk_speed) and sneak:path_clear(data.m_pos, c.pos, true, walk_speed) then
				return { pos = c.pos, mode = "walk" }
			end
		end
	end)
end

-- The sneaking state the bot has while it goes around a guard (the sneaking code has helpers that need it)
function Melee:sneak_state(data)
	local movement = data.unit:movement()

	if not movement._sh_sneak or movement._sh_sneak.kind ~= "flank" then
		UsefulBots.sneak:release(data.unit)
		movement._sh_sneak = { kind = "flank" }
	end
end

function Melee:flank_go(data, st, plan)
	local sneak = UsefulBots.sneak
	local crouch = plan.mode == "walk"

	self:sneak_state(data)
	sneak:hold_still(data, false)
	sneak:set_crouch_walk(data, crouch)

	st.held = nil
	st.flank_pos = mvector3.copy(plan.pos)
	st.flank_mode = plan.mode

	data.brain:set_objective({
		type = "free",
		pos = mvector3.copy(plan.pos),
		nav_seg = managers.navigation:get_nav_seg_from_pos(plan.pos, true),
		haste = crouch and "walk" or "run",
		pose = crouch and "crouch" or "stand",
		sh_flank = true
	})

	StreamHeist:log("Stealth defense: %s goes around a guard to dominate it from behind (%.1f m, %s)", self:bot_name(data.unit), mvec3_dis(data.m_pos, plan.pos) / 100, crouch and "crouched" or "running")

	return true
end

-- No safe way for now: stay where it is
function Melee:flank_hold(data, st)
	self:sneak_state(data)
	UsefulBots.sneak:hold_still(data, true)

	st.held = true
	st.flank_pos = nil
	st.flank_mode = nil
end

function Melee:stop_flank(data, st)
	if not st.flank_pos and not st.held and not st.plan_t then
		return
	end

	st.flank_pos, st.flank_mode, st.plan_t, st.plan_fail_t, st.held = nil

	UsefulBots.sneak:release(data.unit)

	if data.objective and data.objective.sh_flank then
		data.brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(data.unit))
	end
end

function Melee:fail_flank(data, st, claim, reason)
	claim.failed[data.unit:key()] = data.t
	claim.t = 0

	self:stop_flank(data, st)

	StreamHeist:log("Stealth defense: %s gives up going around a guard (%s)", self:bot_name(data.unit), reason)
end

function Melee:flank(data, guard, st, claim)
	local unit = data.unit

	-- noticed: sneaking up on the guard is over
	if self:detected_by(guard, unit) then
		self:fail_flank(data, st, claim, "it was noticed")
		return
	end

	-- the objective is done (the bot is there) or was replaced: the next plan sets a new one
	if st.flank_pos and not (data.objective and data.objective.sh_flank) then
		st.flank_pos = nil
		st.plan_t = nil
	end

	if st.flank_pos then
		UsefulBots.sneak:sync_attention(data)
	end

	if st.plan_t and data.t < st.plan_t + self.PLAN_T then
		return
	end

	st.plan_t = data.t

	local plan = self:plan_flank(data, guard)

	if plan then
		st.plan_fail_t = nil

		-- the guard moves: only go somewhere else if the spot is a different one
		if not st.flank_pos or st.flank_mode ~= plan.mode or mvec3_dis(st.flank_pos, plan.pos) > 100 then
			return self:flank_go(data, st, plan)
		end

		return
	end

	self:flank_hold(data, st)

	st.plan_fail_t = st.plan_fail_t or data.t
	if data.t > st.plan_fail_t + self.FLANK_WAIT then
		self:fail_flank(data, st, claim, "no safe way")
	end
end


-- Update, called from the logic updates of the bots. Returns true if the logic was left

function Melee:update(data)
	if self._failed then
		return
	end

	if not UsefulBots.settings.stealth_melee or not UsefulBots.stealth:holds_fire(data.unit) then
		data.unit:movement()._sh_kill = nil
		self:release(data)
		return
	end

	-- a guard that was dominated and is to be killed
	if data.unit:movement()._sh_kill then
		return self:safe("kill", self.update_kill, data)
	end

	return self:safe("update", self.update_active, data)
end

-- The bot goes to kill a guard it dominated: the pager was answered, the body is bagged after that (req/bot_interact.lua)
function Melee:start_kill(unit, guard)
	if not alive(unit) or not alive(guard) then
		return false, "the bot or the guard is gone"
	end

	if not UsefulBots.stealth:holds_fire(unit) then
		return false, "the bot is not awake in stealth or the heist is about to go loud"
	end

	local movement = unit:movement()

	if not movement._sh_kill then
		movement._sh_kill = { guard = guard, t0 = TimerManager:game():time() }

		StreamHeist:log("Stealth defense: %s goes to kill a guard it dominated (the body is bagged after that)", self:bot_name(unit))
	end

	return true
end

function Melee:update_kill(data)
	local unit = data.unit
	local movement = unit:movement()
	local kill = movement._sh_kill
	local guard = kill.guard
	local damage_ext = alive(guard) and guard:character_damage()

	if not damage_ext or damage_ext:dead() then
		movement._sh_kill = nil

		StreamHeist:log("Stealth defense: %s killed the guard it dominated", self:bot_name(unit))

		self:release(data)

		return
	end

	if data.t > kill.t0 + self.KILL_TIME then
		movement._sh_kill = nil

		StreamHeist:log("Stealth defense: %s could not kill the guard it dominated in time", self:bot_name(unit))

		self:release(data)

		return
	end

	local st = movement._sh_melee

	if not st then
		st = { tries = 0 }
		movement._sh_melee = st
	end

	-- a swing or a turn that was under way is over
	if st.hold_until and data.t >= st.hold_until then
		st.hold_until = nil
		st.swing_guard = nil

		UsefulBots.sneak:hold_still(data, false)
	end

	if st.next_t and data.t < st.next_t then
		return
	end

	st.next_t = data.t + 0.1
	movement._sh_engaged = data.t + 1

	local brain = guard:brain()

	st.info = { calling = false, call_started = false, civilian = false, logic_data = brain and brain._logic_data }

	local dis = mvec3_dis(data.m_pos, guard:movement():m_pos())
	local los = self:has_los(data, guard)

	-- what the bot is up to, for the log
	if not kill.log_t or data.t >= kill.log_t then
		kill.log_t = data.t + 2

		StreamHeist:log("Stealth defense: %s is after the guard it dominated (%.1f m, sight %s, chase possible %s)", self:bot_name(unit), dis / 100, los and "yes" or "no", self:can_pursue(data, guard, st.info) and "yes" or "no")
	end

	-- What this returns is what the logic update does next: true skips the update of the game. A bot that walks needs that update, and a bot
	-- that swings needs the shoot action it makes, so it is only true on the update that gives the bot a new objective, which is what the
	-- defense against every other guard does (charge says so). It returned true on every update: the bot stood 2.7 m from the guard for 20
	-- seconds, "charging" without a single step
	if dis <= self.RANGE and los then
		self:strike(data, guard, st)

		return
	end

	return self:charge(data, guard, st)
end

function Melee:update_active(data)
	local unit = data.unit
	local movement = unit:movement()
	local st = movement._sh_melee

	-- the bot was told to stand still for a turn or a swing: that is over now, and what came of the swing
	if st and st.hold_until and data.t >= st.hold_until then
		st.hold_until = nil
		UsefulBots.sneak:hold_still(data, false)

		if st.swing_guard then
			local guard = st.swing_guard
			st.swing_guard = nil

			local damage_ext = alive(guard) and guard:character_damage()

			if not damage_ext or damage_ext:dead() then
				StreamHeist:log("Stealth defense: the swing of %s killed the guard", self:bot_name(unit))
			else
				StreamHeist:log("Stealth defense: the swing of %s did not kill the guard (%d%% health left, it was %.1f m away and %d%% in front when the swing started)", self:bot_name(unit), damage_ext:health_ratio() * 100, st.swing_dis / 100, math.max(0, st.swing_dot) * 100)
			end
		end
	end

	if st and st.next_t and data.t < st.next_t then
		return
	end

	local guard, info, claim = self:assignment(data)
	local close, close_dis = self:close_guard(data)

	if not guard and not close then
		self:release(data)
		return
	end

	if not st then
		st = { tries = 0 }
		movement._sh_melee = st
	end

	st.next_t = data.t + (close and close_dis <= self.RANGE and 0.05 or 0.25)
	movement._sh_engaged = data.t + 1

	-- a guard that came up to the bot is meleed by whoever it came to
	if close and close_dis <= self.RANGE then
		self:strike(data, close, st)
		return
	end

	-- not in charge of a guard: it may come to us, that is all
	if not guard then
		return
	end

	local key = guard:key()
	if st.key ~= key then
		self:stop_flank(data, st)
		st.key = key
		st.tries = 0
		st.try_t = nil
		st.turn_t = nil
	end
	st.info = info
	-- A target outside the domain can still be shouted at from here. Cancel any
	-- obsolete movement first; leave the attempt counters intact for the shout.
	if not self:can_pursue(data, guard, info) and data.objective and (data.objective.sh_charge or data.objective.sh_flank) then
		self:stop_flank(data, st)
		if data.objective and data.objective.sh_charge then
			data.brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(unit))
		end
		return true
	end

	claim.t = data.t

	local dis = mvec3_dis(data.m_pos, guard:movement():m_pos())

	-- a civilian: shout, no melee
	if info.civilian then
		return self:stop_civilian_call(data, guard, st, dis)
	end

	local in_range = dis <= self:dominate_range() and self:has_los(data, guard)

	-- a guard that is calling the police: no sneaking around. Run at it, shout on the way (that does not stop the bot) and
	-- melee it once it is close (the check for that is above, the melee of a bot kills at once in stealth)
	if info.calling then
		if in_range and st.tries < self.DOMINATE_TRIES and (not st.try_t or data.t > st.try_t) and self:can_dominate(data, guard, info, dis) then
			if self:dominate(data, guard) then
				st.tries = st.tries + 1
				st.try_t = data.t + self.DOMINATE_WAIT

				StreamHeist:log("Stealth defense: %s tries to dominate a guard that is calling the police (try %d)", self:bot_name(unit), st.tries)
			end
		end

		return self:charge(data, guard, st)
	end

	if not in_range then
		-- out of range: go around it if the guard does not know about the bot, otherwise charge
		if UsefulBots.settings.stealth_flank and not self:detected_by(guard, unit) and not (claim.failed[unit:key()] and data.t - claim.failed[unit:key()] < self.FAIL_T) then
			return self:flank(data, guard, st, claim)
		end

		if st.try_t and data.t < st.try_t then
			return
		end

		return self:charge(data, guard, st)
	end

	-- in range: stop sneaking around, the bot stands still for the shout
	if st.flank_pos then
		UsefulBots.sneak:hold_still(data, true)
		st.flank_pos = nil
		st.held = true
	end

	if st.tries < self.DOMINATE_TRIES and (not st.try_t or data.t > st.try_t) and self:can_dominate(data, guard, info, dis) then
		if self:dominate(data, guard) then
			st.tries = st.tries + 1
			st.try_t = data.t + self.DOMINATE_WAIT

			StreamHeist:log("Stealth defense: %s tries to dominate a guard that is about to fire (try %d)", self:bot_name(unit), st.tries)
		end

		return
	end

	-- wait for the last try to take effect
	if st.try_t and data.t < st.try_t then
		return
	end

	return self:charge(data, guard, st)
end

-- Nothing to do (anymore), the bot goes back to what it did
function Melee:release(data)
	local movement = data.unit:movement()
	local st = movement._sh_melee

	if not st and not movement._sh_engaged then
		return
	end

	if st then
		self:stop_flank(data, st)
	end

	movement._sh_melee = nil
	movement._sh_engaged = nil
	UsefulBots.sneak:hold_still(data, false)

	if data.objective and (data.objective.sh_charge or data.objective.sh_flank) then
		data.brain:set_objective(managers.groupai:state():_determine_objective_for_criminal_AI(data.unit))
	end
end
