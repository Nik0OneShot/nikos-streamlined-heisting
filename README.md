check the original github repo for its original description: https://github.com/segabl/pd2-streamlined-heisting


intended to be used with: https://github.com/Nik0OneShot/nikos-streamlined-heisting-complements/tree/master


this is basically just my own version of hoppips streamlined heisting, because i absolutely despise some of the changes made and think they could've been done differently. an example of this would be in regards to bulldozers and their new visor / glass health - bulldozers in vanilla were pushovers with absolutely no fear associated with them, in comparison to payday the heist where they did. perhaps they have some fear on death sentence due to decks like kingpin and green dozers, but they die so quickly that it doesn't really matter. in this, they're a lot stronger - more capable - and in doing so, have become bullet sponges.

the problem is they deal lots of damage, are relatively fast all things considered, and take way too many bullets to kill. visor and then glass health combined forces you to play the absolute meta to be able to deal with them, which i don't think i need to state why is unfun. and, mind you, this isn't even me mentioning the fact that the visor and glass health isn't REALLY health. it's just dividing all damage you deal to it down to minuscule factions... 

	self.tank_armor_damage_mul = 1 / hp_mul
	self.tank_glass_damage_mul = 1 / math.max(1, hp_mul * 0.5)

seriously, what the fuck.

now you'd imagine that bulldozers w/o heads would be easier to kill, right? because their bodies will always take damage? well, no, their armor now actually stops bullets entirely. a good design choice, plus the armor is breakable, but again...bullet sponge. and don't even get me started on the fucking halloween headless dozers and the fact that, despite having no head and therefore no headshot multiplier ('uhm acktually they do have one but its pixel width and you only get awarded a nice 4x damage boost instead of being awarded an instant kill for shooting something that is literally pixel width'), they have the exact same health as all the other bulldozers.

	self.tank.HEALTH_INIT = 200
	self.tank_hw.HEALTH_INIT = 200
	self.tank_medic.HEALTH_INIT = 200
	self.tank_mini.HEALTH_INIT = 400

thats 2000 health, plus difficulty scaling by the way. you can be dealing with, at maximum, 2000 * 8 for a spectacular health pool of **16000 FUCKING HEALTH.** don't want to play meta? TOO BAD. what a fucking joke.

oh, and thats just bulldozers. bulldozers, enemies you'll find to be rather common, but what about mini bosses? how are they improved? are they still dogshit? in my opinion, they're worse now.

in vanilla, minibosses take headshot damage, plus some are able to be stunned or just melted to death. they're pushovers, but they make a rather cool feeling to their presence, especially considering that they tend to use weapons that other npcs can't. for instance, chavez having akimbo pistols, sosa having the little friend and having his big entrance being a scarface reference, one of them literally having a flamethrower. they're cool, weak, but still cool.

streamlined heisting makes them overstay their welcome by making them absurdly tanky, for example, heres chavez.

```
Hooks:PostHook(CharacterTweakData, "_init_chavez_boss", "sh__init_chavez_boss", function(self, presets)
  self.chavez_boss.HEALTH_INIT = 400
	self.chavez_boss.player_health_scaling_mul = 1.25
	self.chavez_boss.headshot_dmg_mul = 0.75
	self.chavez_boss.no_headshot_add_mul = true
	self.chavez_boss.damage.explosion_damage_mul = 0.5
	self.chavez_boss.damage.hurt_severity = presets.hurt_severities.no_hurts
	self.chavez_boss.use_animation_on_fire_damage = false
	self.chavez_boss.move_speed = presets.move_speed.fast
	self.chavez_boss.no_run_start = true
	self.chavez_boss.no_run_stop = true
end)
```

chavez now has 4000 health, plus difficulty scaling, plus it increases for EVERY HUMAN PLAYER IN THE HEIST. and you know what the craziest part is? he not only takes **LESS EXPLOSION DAMAGE**, but ***HAS NO FUCKING HEADSHOT MULTIPLIERS!***

you have to be fucking KIDDING. TELL ME A SINGLE PART OF CHAVEZ WHERE HIS HEAD IS INCAPABLE OF BEING SHOT AT? TELL ME A SINGLE PART OF HIS BODY WHERE HE REDUCES ANY AND ALL FORMS OF EXPLOSIVES? TELL ME A SINGLE PART OF HIM THAT PREVENTS HIM FROM SUFFERING FROM FIRE? WHAT THE FUCK ARE YOU THINKING. same person who programmed this complains about what jules did regarding one down, by the way.

all you had to do to make minibosses more effective at their job is to literally remove their hurt severities. that is all you have to do. you don't need to increase their health, you don't need to make them tanky, because if you do that they overstay their welcome and they become **ANNOYING.**

anyway, theres also other things that i think should be changed but i don't really want to detail them here. i'll probably update this readme in the future if i think it's notable to mention, but yeah. streamlined heisting is fun, i just wish the developer actually played his own mod so he could see how genuinely dogshit it is to endure some of these enemies.
