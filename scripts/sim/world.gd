class_name World
extends RefCounted
## Полное состояние мира. Никаких ссылок на дерево сцен — поэтому его
## безопасно читать из рабочих потоков во время параллельных фаз симуляции.

const T_PLAINS := 0
const T_FOREST := 1
const T_HILLS := 2
const T_MOUNTAIN := 3
const T_URBAN := 4
const T_SEA := 5

const TERRAIN_NAMES := ["Равнины", "Лес", "Холмы", "Горы", "Город", "Море"]
const TERRAIN_MOVE := [1.0, 0.7, 0.6, 0.4, 0.85, 1.0]
const TERRAIN_DEFENSE := [0.0, 0.2, 0.3, 0.55, 0.35, 0.0]
const TERRAIN_COLORS := [
	Color(0.62, 0.68, 0.40), Color(0.30, 0.48, 0.28), Color(0.64, 0.56, 0.38),
	Color(0.62, 0.60, 0.58), Color(0.72, 0.52, 0.42), Color(0.2, 0.3, 0.4),
]

const MONTHS := ["января", "февраля", "марта", "апреля", "мая", "июня", "июля",
	"августа", "сентября", "октября", "ноября", "декабря"]
const MONTH_DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const START_YEAR := 1937


class Nation:
	extends RefCounted
	var id := 0
	var name := ""
	var color := Color.WHITE
	var capital := -1
	var alive := true
	var is_player := false
	var at_war := {}            # nation_id -> true
	var equipment := 0.0
	var manpower := 0.0         # тысячи человек
	var research_points := 0.0  # накопленные за текущую технологию
	var current_research := ""
	var techs := {}             # tech_id -> true
	var bonus := {}             # bonus_key -> float
	var build_mode := "mil"     # "civ" или "mil"
	var build_progress := 0.0
	var training: Array = []    # оставшиеся дни для каждой дивизии в подготовке
	# Кэш, пересчитывается в экономической фазе (параллельно)
	var civ := 0
	var mil := 0
	var province_count := 0
	var division_count := 0
	var daily_equipment := 0.0
	var daily_research := 0.0
	var daily_manpower := 0.0

	func b(key: String) -> float:
		return float(bonus.get(key, 0.0))


class Division:
	extends RefCounted
	var id := 0
	var owner := 0
	var prov := 0
	var path := PackedInt32Array()  # следующие провинции, path[0] — ближайшая
	var progress := 0.0             # 0..1 — сколько пройдено к path[0]
	var strength := 100.0           # 0..100
	var org := 40.0
	var alive := true
	var in_battle := false


var seed_value := 0
var width := 0
var height := 0
var id_image: Image
var height_image: Image
var province_ids := PackedInt32Array()  # width*height

var prov_count := 0
var land_count := 0
var p_land := PackedByteArray()
var p_center := PackedVector2Array()
var p_pixels := PackedInt32Array()
var p_adj: Array = []                   # Array[PackedInt32Array]
var p_terrain := PackedByteArray()
var p_owner := PackedInt32Array()
var p_controller := PackedInt32Array()
var p_vp := PackedInt32Array()
var p_civ := PackedInt32Array()
var p_mil := PackedInt32Array()
var p_manpower := PackedInt32Array()
var p_name := PackedStringArray()

var nations: Array = []
var nation_count := 0

# Кэши для параллельных фаз. Важно: из рабочих потоков читаем только
# плоские Packed-массивы, вынесенные в локальные переменные задачи. Каждое
# обращение world.some_array из чужого объекта копирует Variant и атомарно
# трогает общий счётчик ссылок — на нескольких ядрах это «пинг-понг»
# кэш-линии, который съедает весь выигрыш от параллельности.
var war := PackedByteArray()          # nation_count^2, 1 = война
var adj_start := PackedInt32Array()   # CSR-соседство: adj_list[adj_start[p] .. adj_start[p+1])
var adj_list := PackedInt32Array()
var p_move_mult := PackedFloat32Array()  # копии констант местности по провинциям:
var p_def_mult := PackedFloat32Array()   # константные Array/Dictionary скриптов из потоков не трогаем
var n_attack := PackedFloat32Array()
var n_defense := PackedFloat32Array()
var n_org := PackedFloat32Array()
var n_speed := PackedFloat32Array()
var divisions: Array = []
var next_div_id := 1
var day := 0
var prov_divs: Array = []   # province -> Array[Division]
var events: Array = []      # строки для журнала, забирает UI
var palette_dirty := true
var game_over := ""


# --- Время -------------------------------------------------------------------

func date_string() -> String:
	var d := day
	var year := START_YEAR + d / 365
	d = d % 365
	var m := 0
	while d >= MONTH_DAYS[m]:
		d -= MONTH_DAYS[m]
		m += 1
	return "%d %s %d" % [d + 1, MONTHS[m], year]


func log_event(text: String) -> void:
	events.append(text)


# --- Запросы (только чтение, потокобезопасны) ------------------------------

func is_at_war(a: int, b: int) -> bool:
	if a < 0 or b < 0 or a == b:
		return false
	return war[a * nation_count + b] == 1


func can_enter(nation: int, prov: int) -> bool:
	if p_land[prov] == 0:
		return false
	var c := p_controller[prov]
	return c == nation or is_at_war(nation, c)


func build_caches() -> void:
	nation_count = nations.size()
	adj_start.resize(prov_count + 1)
	adj_list = PackedInt32Array()
	for p in prov_count:
		adj_start[p] = adj_list.size()
		adj_list.append_array(p_adj[p])
	adj_start[prov_count] = adj_list.size()
	p_move_mult.resize(prov_count)
	p_def_mult.resize(prov_count)
	for p in prov_count:
		p_move_mult[p] = TERRAIN_MOVE[p_terrain[p]]
		p_def_mult[p] = TERRAIN_DEFENSE[p_terrain[p]]
	war.resize(nation_count * nation_count)
	war.fill(0)
	for n in nations:
		for o in n.at_war:
			war[n.id * nation_count + o] = 1
	refresh_stats()


func refresh_stats() -> void:
	n_attack.resize(nation_count)
	n_defense.resize(nation_count)
	n_org.resize(nation_count)
	n_speed.resize(nation_count)
	for n in nations:
		n_attack[n.id] = 10.0 * (1.0 + n.b("attack"))
		n_defense[n.id] = 12.0 * (1.0 + n.b("defense"))
		n_org[n.id] = 40.0 * (1.0 + n.b("org"))
		n_speed[n.id] = 0.28 * (1.0 + n.b("speed"))


## Доход страны за день: [гражд., воен., призывники, провинций]. Метод самого
## World — внутри него доступ к полям прямой, без копий Variant.
func compute_income(nid: int) -> Array:
	var civ := 0
	var mil := 0
	var mp := 0
	var provs := 0
	for p in prov_count:
		if p_controller[p] != nid:
			continue
		provs += 1
		if p_owner[p] == nid:
			civ += p_civ[p]
			mil += p_mil[p]
			mp += p_manpower[p]
		else:  # оккупированные провинции работают вполсилы
			civ += p_civ[p] / 2
			mil += p_mil[p] / 2
			mp += p_manpower[p] / 5
	return [civ, mil, mp, provs]


func has_enemies(nation: int, prov: int) -> bool:
	for d in prov_divs[prov]:
		if d.alive and is_at_war(nation, d.owner):
			return true
	return false


func terrain_of(p: int) -> int:
	return p_terrain[p]


func province_at_pixel(px: Vector2) -> int:
	var x := int(px.x)
	var y := int(px.y)
	if x < 0 or y < 0 or x >= width or y >= height:
		return -1
	return province_ids[y * width + x]


func neighbours_of_nation(n: int) -> Dictionary:
	var res := {}
	for p in prov_count:
		if p_controller[p] != n:
			continue
		for k in range(adj_start[p], adj_start[p + 1]):
			var q := adj_list[k]
			var c := p_controller[q]
			if c >= 0 and c != n and p_land[q] == 1:
				res[c] = true
	return res


func division_attack(n: int) -> float:
	return n_attack[n]


func division_defense(n: int) -> float:
	return n_defense[n]


func division_max_org(n: int) -> float:
	return n_org[n]


func division_speed(n: int) -> float:
	return n_speed[n]


# --- Изменения (только из главного потока) ---------------------------------

func rebuild_prov_divs() -> void:
	if prov_divs.size() != prov_count:
		prov_divs.resize(prov_count)
	for p in prov_count:
		prov_divs[p] = []
	var alive_list: Array = []
	for d in divisions:
		if d.alive:
			alive_list.append(d)
			prov_divs[d.prov].append(d)
	divisions = alive_list
	for n in nations:
		n.division_count = 0
	for d in divisions:
		nations[d.owner].division_count += 1


func spawn_division(owner: int, prov: int) -> Division:
	var d := Division.new()
	d.id = next_div_id
	next_div_id += 1
	d.owner = owner
	d.prov = prov
	d.org = division_max_org(owner)
	divisions.append(d)
	prov_divs[prov].append(d)
	nations[owner].division_count += 1
	return d


func declare_war(a: int, b: int) -> void:
	if a == b or is_at_war(a, b):
		return
	nations[a].at_war[b] = true
	nations[b].at_war[a] = true
	war[a * nation_count + b] = 1
	war[b * nation_count + a] = 1
	log_event("%s объявляет войну: %s!" % [nations[a].name, nations[b].name])


func end_wars_of(nid: int) -> void:
	for other in nations[nid].at_war:
		nations[other].at_war.erase(nid)
		war[other * nation_count + nid] = 0
		war[nid * nation_count + other] = 0
	nations[nid].at_war.clear()


func divisions_of(n: int) -> Array:
	var res: Array = []
	for d in divisions:
		if d.alive and d.owner == n:
			res.append(d)
	return res


func player_nation() -> int:
	for n in nations:
		if n.is_player:
			return n.id
	return -1
