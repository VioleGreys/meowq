extends SceneTree
## Акклиматизация: суровость провинций, уровни стран, штрафы и бонусы дивизиям.
##   godot --headless --path . --script res://tests/climate_check.gd

var errors := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var tag := func(t: String) -> int: return w.nation_tags.find(t)
	w.day = w.day_of("1937-07-15")
	w.refresh_def_mult()
	Climate.daily(w)
	print("Уровни стран (жара / холод):")
	var line: Array = []
	for t in ["FIN", "SOV", "GER", "ITA", "ENG", "EGY", "SAU", "SWI"]:
		var n: int = tag.call(t)
		if n >= 0:
			line.append("%s %.2f/%.2f" % [t, w.n_hot[n], w.n_cold[n]])
	print("  ", ", ".join(line))
	check(w.n_cold[tag.call("FIN")] > 1.0, "Финляндия — коренные в холоде (бонус)")
	check(w.n_cold[tag.call("GER")] < 0.6 and w.n_hot[tag.call("GER")] == 0.0, "Германия не привычна ни к жаре, ни к северу")
	var egy: int = tag.call("EGY")
	if egy >= 0:
		check(w.n_hot[egy] > 1.0, "Египет — коренные в пустыне")
	# пустыня летом
	var desert := -1
	for p in w.prov_count:
		if w.p_land[p] == 1 and w.p_terrain[p] == World.T_DESERT and w.p_lonlat[p].y > 20.0:
			desert = p
			break
	check(desert >= 0 and is_equal_approx(w.p_hot[desert], 1.0), "пустыня в июле — жара 1 (%s)" % w.p_name[desert])
	print("Немецкая дивизия в пустыне летом:")
	var ger: int = tag.call("GER")
	var d := w.spawn_division(ger, desert, Military.T_INF)
	Climate.daily(w)
	var i := d.slot
	check(w.d_spd_eff[i] < w.d_spd[i] * 0.65 and w.d_atk_eff[i] < w.d_atk[i] * 0.8, "без акклиматизации медленнее и слабее (скорость ×%.2f, бой ×%.2f)" % [w.d_spd_eff[i] / w.d_spd[i], w.d_cmul[i]])
	check(w.d_str[i] < 100.0, "истощение: дивизия теряет людей (%.1f%%)" % w.d_str[i])
	for k in 90:
		Climate.daily(w)
	i = d.slot
	check(w.d_acl_hot[i] >= 0.99 and is_equal_approx(w.d_cmul[i], 1.0), "за 3 месяца — акклиматизация %.0f%%, штрафа нет" % (w.d_acl_hot[i] * 100.0))
	print("Финская дивизия зимой у себя:")
	w.day = w.day_of("1938-01-15")
	w.refresh_def_mult()
	var fin: int = tag.call("FIN")
	var cap: int = w.nations[fin].capital
	var f := w.spawn_division(fin, cap, Military.T_INF)
	var g2 := w.spawn_division(ger, cap, Military.T_INF)
	Climate.daily(w)
	check(w.d_cmul[f.slot] > 1.0, "финны в зиму сильнее (×%.2f)" % w.d_cmul[f.slot])
	check(w.d_cmul[g2.slot] < 1.0, "немцы в финскую зиму слабее (×%.2f)" % w.d_cmul[g2.slot])
	print("Итог: ", "OK" if errors == 0 else "ошибок %d" % errors)
	quit()
