extends SceneTree
## Потери дивизий: где, когда и от чего гибнут дивизии стран --tags. По месяцам:
## сколько было, сколько новых, сколько погибло по причинам (атака — разбита
## при своём наступлении; оборона — разбита в обороне; некуда отступить —
## разбита без пути отхода; без снабжения — истощилась в окружении; прочее —
## события, мир, переброска морем), районы гибели (ближайший город из списка
## ниже) и состояние дивизии за день до гибели (снабжение, организация, снаряжение).
##   godot --headless --path . --script res://tests/loss_diag.gd -- --from=1941-06-22 --until=1943-01-01 --tags=SOV,GER [--seed=N --top=6]

const AREAS := {
	"Мурманск": Vector2(33.1, 68.97), "Карелия": Vector2(33.0, 62.5), "Ленинград": Vector2(30.3, 59.94),
	"Прибалтика": Vector2(24.1, 56.95), "Минск": Vector2(27.56, 53.9), "Смоленск": Vector2(32.04, 54.78),
	"Москва": Vector2(37.62, 55.75), "Калинин": Vector2(35.9, 56.86), "Брянск": Vector2(34.36, 53.24),
	"Киев": Vector2(30.52, 50.45), "Львов": Vector2(24.03, 49.84), "Одесса": Vector2(30.73, 46.48),
	"Харьков": Vector2(36.23, 49.99), "Воронеж": Vector2(39.2, 51.67), "Донбасс": Vector2(37.8, 48.0),
	"Крым": Vector2(34.1, 44.95), "Ростов": Vector2(39.72, 47.22), "Сталинград": Vector2(44.5, 48.7),
	"Кубань": Vector2(39.0, 45.0), "Сев. Кавказ": Vector2(44.0, 44.0), "Закавказье": Vector2(46.0, 41.0),
	"Поволжье": Vector2(48.0, 53.0), "Урал": Vector2(60.0, 56.0), "Ср. Азия": Vector2(66.0, 42.0),
	"Сибирь": Vector2(85.0, 55.0), "Дальний Восток": Vector2(132.0, 46.0), "Монголия": Vector2(105.0, 47.0),
	"Китай": Vector2(115.0, 33.0), "Иран": Vector2(52.0, 33.0),
	"Франция": Vector2(2.35, 47.0), "Германия": Vector2(10.0, 51.0), "Польша": Vector2(20.0, 52.0),
	"Балканы": Vector2(21.0, 43.0), "Италия": Vector2(12.5, 42.0), "Сев. Африка": Vector2(15.0, 31.0),
	"Норвегия": Vector2(10.0, 62.0), "Финляндия": Vector2(26.0, 63.0), "Румыния": Vector2(26.0, 45.5),
	"Венгрия": Vector2(19.0, 47.3),
}

var w: World
var area_cache := {}


func area(p: int) -> String:
	if area_cache.has(p):
		return area_cache[p]
	var ll: Vector2 = w.p_lonlat[p]
	var best := ""
	var bd := 1e9
	for k in AREAS:
		var v: Vector2 = AREAS[k]
		var dx := (ll.x - v.x) * cos(deg_to_rad(ll.y))
		var dd := dx * dx + (ll.y - v.y) * (ll.y - v.y)
		if dd < bd:
			bd = dd
			best = k
	area_cache[p] = best
	return best


func _init() -> void:
	w = World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	sim.log_losses = true
	var until := "1943-01-01"
	var from := "1941-06-22"
	var tags := ["SOV", "GER"]
	var top := 6
	var stacks := 0   # раз в неделю: самые большие стопки первой страны --tags
	var detail := 0   # печатать дни, когда в одной провинции погибло не меньше N дивизий
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--from="):
			from = a.split("=")[1]
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
		if a.begins_with("--stacks="):
			stacks = int(a.split("=")[1])
		if a.begins_with("--detail="):
			detail = int(a.split("=")[1])
		if a.begins_with("--top="):
			top = int(a.split("=")[1])
	var end_day := w.day_of(until)
	var from_day := w.day_of(from)
	var ids := []
	for tg in tags:
		ids.append(w.nation_tags.find(tg))
	# id → [владелец, провинция, снабжение, орг. доля, снаряжение, сила]
	var prev := {}
	var month := {}   # по стране: статистика текущего месяца
	var total := {}
	for n in ids:
		month[n] = _blank()
		total[n] = _blank()
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.loss_log.clear()
		sim.tick()
		for e in w.events:
			if w.day >= from_day and ("капитулирует" in e or "объявляет войну" in e):
				print("  %s — %s" % [w.date_short(), e])
		w.events.clear()
		var cur := {}
		for d in w.divisions:
			if d.alive and ids.has(d.owner):
				cur[d.id] = [d.owner, d.prov, d.supply, d.org / maxf(d.max_org, 0.01), d.eq, d.strength]
		if w.day >= from_day and detail > 0:
			var byp := {}
			var stack := {}
			for id in prev:
				stack[prev[id][1]] = int(stack.get(prev[id][1], 0)) + 1
				if not cur.has(id):
					var k: String = "%s %s" % [w.nation_tags[prev[id][0]], w.p_name[prev[id][1]]]
					if not byp.has(k):
						byp[k] = [0, 0.0, 0.0, prev[id][1]]
					byp[k][0] += 1
					byp[k][1] += prev[id][2]
					byp[k][2] += prev[id][3]
			for k in byp:
				if byp[k][0] >= detail:
					var pp: int = byp[k][3]
					var nb: Array = []
					for j in range(w.adj_start[pp], w.adj_start[pp + 1]):
						var q: int = w.adj_list[j]
						nb.append("%s(%s)" % [w.p_name[q], w.nation_tags[w.p_controller[q]] if w.p_controller[q] >= 0 else "-"])
					print("    %s %s: погибло %d из %d, сн%d%% орг%d%%, контроль %s; соседи: %s" % [w.date_short(), k, byp[k][0], stack[pp],
						roundi(100 * byp[k][1] / byp[k][0]), roundi(100 * byp[k][2] / byp[k][0]),
						w.nation_tags[w.p_controller[pp]] if w.p_controller[pp] >= 0 else "-", ", ".join(nb)])
		if w.day >= from_day:
			for id in prev:
				if cur.has(id):
					continue
				var pv: Array = prev[id]
				var why: String = sim.loss_log.get(id, "прочее")
				for st in [month[pv[0]], total[pv[0]]]:
					st.dead += 1
					st.why[why] = int(st.why.get(why, 0)) + 1
					var ar := area(pv[1])
					st.area[ar] = int(st.area.get(ar, 0)) + 1
					st.sup += pv[2]
					st.org += pv[3]
					st.eq += pv[4]
					if pv[2] < 0.25:
						st.cut += 1
			for id in cur:
				if not prev.has(id):
					month[cur[id][0]].born += 1
					total[cur[id][0]].born += 1
		prev = cur
		if stacks > 0 and w.day >= from_day and w.day % 7 == 0:
			var cnt := {}
			for id in cur:
				if cur[id][0] == ids[0]:
					cnt[cur[id][1]] = int(cnt.get(cur[id][1], 0)) + 1
			var ks: Array = cnt.keys()
			ks.sort_custom(func(a, b): return cnt[a] > cnt[b])
			var parts: Array = []
			for pp in ks.slice(0, stacks):
				var su := 0.0
				for id in cur:
					if cur[id][0] == ids[0] and cur[id][1] == pp:
						su += cur[id][2]
				parts.append("%s %d (сн%d%%)" % [w.p_name[pp], cnt[pp], roundi(100 * su / cnt[pp])])
			print("  стопки %s %s: %s" % [w.date_short(), tags[0], ", ".join(parts)])
		if w.day >= from_day and w.date_short().begins_with("01."):
			for i in ids.size():
				var n: int = ids[i]
				var c := 0
				for id in cur:
					if cur[id][0] == n:
						c += 1
				_print(w.date_short(), tags[i], c, month[n], top)
				month[n] = _blank()
	print("--- итого с %s по %s" % [from, until])
	for i in ids.size():
		_print("всего", tags[i], -1, total[ids[i]], 20)
	quit(0)


func _blank() -> Dictionary:
	return {"dead": 0, "born": 0, "why": {}, "area": {}, "sup": 0.0, "org": 0.0, "eq": 0.0, "cut": 0}


func _print(date: String, tag: String, count: int, st: Dictionary, top: int) -> void:
	var why: Array = []
	for k in st.why:
		why.append("%s %d" % [k, st.why[k]])
	var ar: Array = st.area.keys()
	ar.sort_custom(func(a, b): return st.area[a] > st.area[b])
	var parts: Array = []
	for k in ar.slice(0, top):
		parts.append("%s %d" % [k, st.area[k]])
	var dn: int = maxi(st.dead, 1)
	print("%s %s%s +%d −%d [%s] сн%d%% орг%d%% осн%d%% отрез.%d | %s" % [date, tag,
		(" %dд" % count) if count >= 0 else "", st.born, st.dead, ", ".join(why),
		roundi(100 * st.sup / dn), roundi(100 * st.org / dn), roundi(100 * st.eq / dn), st.cut, ", ".join(parts)])
