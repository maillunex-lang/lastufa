class_name AfSurvival
extends RefCounted
## Physiological and psychological state of one character: needs, body
## temperature, stress, pain, injuries and the zombie infection ("пепельная
## лихорадка"). Pure simulation (no nodes), advanced by simulate(dt_minutes).

const INJURY_NAMES := {
	"bleeding": "Кровотечение",
	"fracture": "Перелом",
	"burn": "Ожог",
	"wound_infection": "Заражение раны",
	"bruise": "Ушиб",
}
## Infection stages. The player only sees symptoms, never the stage itself.
const INFECTION_STAGES := ["none", "incubation", "fever", "necrosis", "terminal"]
const STAGE_HOURS := {"fever": 30.0, "necrosis": 24.0, "terminal": 6.0}

var needs := {}            # need id -> value (0..max)
var health := 100.0
var body_temp := 36.6
var stress := 10.0
var stamina := 100.0
var injuries: Array = []   # [{type, severity 0..1, limb, treated, minutes}]
var infection := {"stage": "none", "minutes_in_stage": 0.0, "incubation_hours": 0.0, "suppressed_minutes": 0.0, "exposure": 0.0}
var sickness_minutes := 0.0
var painkiller_minutes := 0.0
var sleeping := false
var dead := false
var death_cause := ""

## Environment inputs set by the owner before simulate():
var ambient_temp := 10.0
var insulation := 0.0
var wet := 0.0            # 0..1
var exertion := 0.0       # 0 rest, 1 walk, 2 sprint
var threat_nearby := false
## Offline protection: needs and health never fall below these floors.
var protected_floor := -1.0


func reset() -> void:
	needs.clear()
	for def in Registry.all("need"):
		needs[_short(def["id"])] = float(def.get("start", def["max"]))
	health = 100.0
	body_temp = 36.6
	stress = 10.0
	stamina = 100.0
	injuries = []
	infection = {"stage": "none", "minutes_in_stage": 0.0, "incubation_hours": 0.0, "suppressed_minutes": 0.0, "exposure": 0.0}
	sickness_minutes = 0.0
	painkiller_minutes = 0.0
	sleeping = false
	dead = false
	death_cause = ""


static func _short(id: String) -> String:
	return id.get_slice(":", 1) if id.contains(":") else id


func need(id: String) -> float:
	return float(needs.get(id, 100.0))


func pain() -> float:
	var p := 0.0
	for inj in injuries:
		var w := {"fracture": 45.0, "burn": 30.0, "bleeding": 15.0, "wound_infection": 20.0, "bruise": 10.0}
		p += float(w.get(inj["type"], 10.0)) * float(inj["severity"])
	if infection["stage"] == "necrosis" or infection["stage"] == "terminal":
		p += 25.0
	if painkiller_minutes > 0.0:
		p *= 0.35
	return clampf(p, 0.0, 100.0)


func move_multiplier() -> float:
	var m := 1.0
	for inj in injuries:
		if inj["type"] == "fracture" and not inj["treated"] and inj["limb"] in ["left_leg", "right_leg"]:
			m *= 0.55
		elif inj["type"] == "fracture" and inj["limb"] in ["left_leg", "right_leg"]:
			m *= 0.8
	if need("energy") < 15.0:
		m *= 0.75
	if pain() > 60.0:
		m *= 0.8
	if body_temp < 35.0:
		m *= 0.8
	if infection["stage"] == "fever":
		m *= 0.9
	return m


func simulate(dt: float) -> void:
	if dead or dt <= 0.0:
		return
	var hours := dt / 60.0
	# --- needs
	for def in Registry.all("need"):
		var id := _short(def["id"])
		var v := need(id)
		var maxv := float(def["max"])
		if id == "energy" and sleeping:
			v += float(def.get("sleep_recovery_per_hour", 10.0)) * hours
		else:
			var rate := float(def["decay_per_hour"])
			if id in ["satiety", "hydration", "energy"]:
				rate *= 1.0 + exertion * 0.35
			if id == "hydration" and ambient_temp > 25.0:
				rate *= 1.4
			if id == "satiety" and body_temp < 36.0:
				rate *= 1.3
			if sleeping:
				rate *= 0.6
			v -= rate * hours
		v = clampf(v, 0.0, maxv)
		if v <= 0.0:
			_damage(float(def.get("damage_per_hour_at_zero", 0.0)) * hours, "истощение" if id != "hydration" else "обезвоживание")
		needs[id] = v
	# --- body temperature: approaches a target based on ambient conditions
	var effective_ambient := ambient_temp + insulation - wet * 6.0 + exertion * 3.0
	var target := 36.6
	if effective_ambient < 12.0:
		target -= (12.0 - effective_ambient) * 0.09
	elif effective_ambient > 30.0:
		target += (effective_ambient - 30.0) * 0.08
	if infection["stage"] == "fever":
		target += 2.6
	elif infection["stage"] == "necrosis":
		target += 1.5
	if sickness_minutes > 0.0:
		target += 1.2
	body_temp = lerpf(body_temp, clampf(target, 30.0, 42.0), 1.0 - exp(-hours * 0.8))
	if body_temp < 35.0:
		_damage((35.0 - body_temp) * 3.0 * hours, "переохлаждение")
	if body_temp > 40.0:
		_damage((body_temp - 40.0) * 4.0 * hours, "гипертермия")
	# --- injuries
	for inj in injuries.duplicate():
		inj["minutes"] = float(inj["minutes"]) + dt
		match inj["type"]:
			"bleeding":
				if not inj["treated"]:
					_damage(float(inj["severity"]) * 18.0 * hours, "кровопотеря")
					# light bleeding may stop on its own
					if float(inj["severity"]) < 0.3 and randf() < 0.15 * hours:
						injuries.erase(inj)
				else:
					injuries.erase(inj)
			"wound_infection":
				if not inj["treated"]:
					inj["severity"] = minf(1.0, float(inj["severity"]) + 0.02 * hours)
					sickness_minutes = maxf(sickness_minutes, 60.0)
					_damage(float(inj["severity"]) * 2.0 * hours, "сепсис")
				elif float(inj["minutes"]) > 48.0 * 60.0:
					injuries.erase(inj)
			"fracture":
				var heal_h := 24.0 * 21.0 if inj["treated"] else 24.0 * 60.0
				if float(inj["minutes"]) > heal_h * 60.0:
					injuries.erase(inj)
			"bruise", "burn":
				if float(inj["minutes"]) > 24.0 * 60.0 * (3.0 if inj["type"] == "bruise" else 10.0):
					injuries.erase(inj)
	# --- infection
	_simulate_infection(dt)
	# --- stress & stamina
	var stress_target := 10.0
	if threat_nearby:
		stress_target += 35.0
	if need("satiety") < 20.0 or need("hydration") < 20.0:
		stress_target += 15.0
	stress_target += pain() * 0.3
	if infection["stage"] != "none" and infection["stage"] != "incubation":
		stress_target += 20.0
	stress = lerpf(stress, clampf(stress_target, 0.0, 100.0), 1.0 - exp(-hours * (1.5 if threat_nearby else 0.4)))
	if sickness_minutes > 0.0:
		sickness_minutes = maxf(0.0, sickness_minutes - dt)
		_damage(0.8 * hours, "болезнь")
	painkiller_minutes = maxf(0.0, painkiller_minutes - dt)
	# --- natural regeneration when needs are met
	if not dead and need("satiety") > 40.0 and need("hydration") > 40.0 and _active_bleeding() == 0.0 and infection["stage"] in ["none", "incubation"]:
		health = minf(100.0, health + (2.5 if sleeping else 0.8) * hours)
	if protected_floor >= 0.0:
		for id in needs:
			needs[id] = maxf(float(needs[id]), protected_floor)
		health = maxf(health, protected_floor)


func _active_bleeding() -> float:
	var s := 0.0
	for inj in injuries:
		if inj["type"] == "bleeding" and not inj["treated"]:
			s += float(inj["severity"])
	return s


func _simulate_infection(dt: float) -> void:
	var stage := str(infection["stage"])
	if stage == "none":
		return
	if float(infection["suppressed_minutes"]) > 0.0:
		infection["suppressed_minutes"] = maxf(0.0, float(infection["suppressed_minutes"]) - dt)
		return
	infection["minutes_in_stage"] = float(infection["minutes_in_stage"]) + dt
	var hours_in := float(infection["minutes_in_stage"]) / 60.0
	match stage:
		"incubation":
			if hours_in >= float(infection["incubation_hours"]):
				_set_stage("fever")
		"fever":
			if hours_in >= STAGE_HOURS["fever"]:
				_set_stage("necrosis")
		"necrosis":
			_damage(3.0 * dt / 60.0, "пепельная лихорадка")
			if hours_in >= STAGE_HOURS["necrosis"]:
				_set_stage("terminal")
		"terminal":
			_damage(12.0 * dt / 60.0, "пепельная лихорадка")
			if hours_in >= STAGE_HOURS["terminal"]:
				_die("обращение")


func _set_stage(s: String) -> void:
	infection["stage"] = s
	infection["minutes_in_stage"] = 0.0


## Called when a zombie hit lands. chance is the zombie's infect_chance.
func expose_to_infection(chance: float) -> bool:
	infection["exposure"] = float(infection["exposure"]) + chance
	if infection["stage"] != "none":
		return false
	if randf() < chance:
		infection["stage"] = "incubation"
		infection["minutes_in_stage"] = 0.0
		infection["incubation_hours"] = randf_range(14.0, 36.0)
		return true
	return false


func symptoms() -> PackedStringArray:
	var out := PackedStringArray()
	match str(infection["stage"]):
		"fever":
			out.append("Сильный жар, ломота")
		"necrosis":
			out.append("Почернение вокруг раны, спутанность сознания")
		"terminal":
			out.append("Судороги. Мысли путаются.")
	if sickness_minutes > 0.0:
		out.append("Тошнота")
	if body_temp < 35.5:
		out.append("Переохлаждение")
	if body_temp > 38.0 and infection["stage"] != "fever":
		out.append("Повышенная температура")
	return out


func add_injury(type: String, severity: float, limb: String = "torso") -> void:
	for inj in injuries:
		if inj["type"] == type and inj["limb"] == limb and not inj["treated"]:
			inj["severity"] = minf(1.0, float(inj["severity"]) + severity * 0.6)
			return
	injuries.append({"type": type, "severity": clampf(severity, 0.05, 1.0), "limb": limb, "treated": false, "minutes": 0.0})


## Applies the "use" block of an item definition. Returns a short message.
func apply_use(use: Dictionary) -> String:
	var msgs := PackedStringArray()
	if use.has("hunger"):
		needs["satiety"] = clampf(need("satiety") + float(use["hunger"]), 0.0, 100.0)
	if use.has("thirst"):
		needs["hydration"] = clampf(need("hydration") + float(use["thirst"]), 0.0, 100.0)
	if use.has("stress"):
		stress = clampf(stress + float(use["stress"]), 0.0, 100.0)
	if use.has("health"):
		health = clampf(health + float(use["health"]), 0.0, 100.0)
	if use.has("pain_relief_hours"):
		painkiller_minutes = maxf(painkiller_minutes, float(use["pain_relief_hours"]) * 60.0)
		msgs.append("боль утихает")
	if use.has("sickness_chance") and randf() < float(use["sickness_chance"]):
		sickness_minutes = maxf(sickness_minutes, randf_range(6.0, 14.0) * 60.0)
		msgs.append("вас мутит")
	if use.has("cures"):
		for cure in use["cures"]:
			for inj in injuries:
				if inj["type"] == cure and not inj["treated"]:
					inj["treated"] = true
					msgs.append("%s: обработано" % INJURY_NAMES.get(cure, cure))
					break
	if use.has("infection_exposure_reduce") and infection["stage"] == "none":
		infection["exposure"] = float(infection["exposure"]) * (1.0 - float(use["infection_exposure_reduce"]))
	if use.has("infection_delay_hours") and infection["stage"] != "none":
		infection["suppressed_minutes"] = float(infection["suppressed_minutes"]) + float(use["infection_delay_hours"]) * 60.0
		msgs.append("жар отступает")
	return ", ".join(msgs)


func _damage(amount: float, cause: String) -> void:
	if amount <= 0.0 or dead:
		return
	health -= amount
	if health <= 0.0:
		if protected_floor >= 0.0:
			health = protected_floor
			return
		_die(cause)


func take_hit(amount: float, cause: String) -> void:
	stress = minf(100.0, stress + amount * 0.6)
	_damage(amount, cause)


func _die(cause: String) -> void:
	health = 0.0
	dead = true
	death_cause = cause


func to_dict() -> Dictionary:
	return {"needs": needs, "health": health, "body_temp": body_temp, "stress": stress, "stamina": stamina,
		"injuries": injuries, "infection": infection, "sickness_minutes": sickness_minutes,
		"painkiller_minutes": painkiller_minutes, "sleeping": sleeping, "dead": dead, "death_cause": death_cause}


func from_dict(d: Dictionary) -> void:
	reset()
	for id in d.get("needs", {}):
		needs[id] = float(d["needs"][id])
	health = float(d.get("health", 100.0))
	body_temp = float(d.get("body_temp", 36.6))
	stress = float(d.get("stress", 10.0))
	stamina = float(d.get("stamina", 100.0))
	injuries = d.get("injuries", [])
	var inf: Dictionary = d.get("infection", {})
	for k in inf:
		infection[k] = inf[k]
	sickness_minutes = float(d.get("sickness_minutes", 0.0))
	painkiller_minutes = float(d.get("painkiller_minutes", 0.0))
	sleeping = bool(d.get("sleeping", false))
	dead = bool(d.get("dead", false))
	death_cause = str(d.get("death_cause", ""))
