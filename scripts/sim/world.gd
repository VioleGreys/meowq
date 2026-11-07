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
const T_DESERT := 6
const T_MARSH := 7

const TERRAIN_NAMES := ["Равнины", "Лес", "Холмы", "Горы", "Город", "Море", "Пустыня", "Болота"]
const TERRAIN_MOVE := [1.0, 0.7, 0.6, 0.4, 0.85, 1.0, 0.8, 0.45]
const TERRAIN_DEFENSE := [0.0, 0.2, 0.3, 0.55, 0.35, 0.0, 0.0, 0.3]
const TERRAIN_COLORS := [
	Color(0.62, 0.68, 0.40), Color(0.30, 0.48, 0.28), Color(0.64, 0.56, 0.38),
	Color(0.62, 0.60, 0.58), Color(0.72, 0.52, 0.42), Color(0.2, 0.3, 0.4),
	Color(0.86, 0.78, 0.55), Color(0.42, 0.52, 0.42),
]

const MONTHS := ["января", "февраля", "марта", "апреля", "мая", "июня", "июля",
	"августа", "сентября", "октября", "ноября", "декабря"]
const MONTH_DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const START_YEAR := 1936


class Nation:
	extends RefCounted
	var id := 0
	var name := ""
	var tag := ""
	var full_name := ""
	var ideology := ""          # democracy / authoritarian / fascism / communism
	var leader := ""
	var leader_title := ""
	var flag := {}
	var population := 0.0       # млн, метрополия
	var manpower_rate := 0.015
	var major := false
	var neutral := false
	var color := Color.WHITE
	var capital := -1
	var alive := true
	var is_player := false
	var at_war := {}            # nation_id -> true
	# Дипломатия (этап 3)
	var faction := -1           # индекс в World.factions
	var overlord := -1          # для марионеток
	var guarantees := {}        # кому мы гарантируем независимость: id -> true
	var pacts := {}             # пакты о ненападении: id -> true
	var wargoals := {}          # обоснованные претензии: id -> true
	var justify_target := -1    # на кого сейчас обосновываем претензии
	var justify_days := 0       # сколько дней осталось
	var justify_total := 0
	var war_activity_day := 0   # последний день с захватом провинций (для белого мира)
	var stock := PackedFloat32Array([0, 0, 0, 0])        # склад снаряжения по типам
	var daily_output := PackedFloat32Array([0, 0, 0, 0]) # выпуск за последний день
	var lines: Array = []       # производственные линии: [тип снаряжения, заводов, эффективность]
	var trained_count := 0
	var stats_dirty := true     # технологии изменились — пересчитать кэш дивизий      # сколько дивизий ИИ уже заказал (для чередования шаблонов)
	var manpower := 0.0         # тысячи человек
	var research_points := 0.0  # накопленные за текущую технологию
	var current_research := ""
	var techs := {}             # tech_id -> true
	var bonus := {}             # bonus_key -> float
	var build_mode := "mil"     # "civ" или "mil"
	var build_progress := 0.0
	var training: Array = []    # в подготовке: [оставшиеся дни, шаблон]
	# Кэш, пересчитывается в экономической фазе (параллельно)
	var civ := 0
	var mil := 0
	var province_count := 0
	var division_count := 0
	var daily_research := 0.0
	var daily_manpower := 0.0

	func b(key: String) -> float:
		return float(bonus.get(key, 0.0))


class Faction:
	extends RefCounted
	var id := 0
	var name := ""
	var leader := 0
	var color := Color.WHITE
	var alive := true


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
	# Этап 4: шаблон, укомплектованность, снабжение, армия
	var tpl := 0                    # Military.T_*
	var eq := 1.0                   # укомплектованность снаряжением 0..1
	var supply := 1.0               # снабжение 0..1 (0 — окружена)
	var group := -1                 # армия игрока (World.groups), -1 — нет
	# кэш характеристик (Military.refresh_division), читается из потоков
	var atk := 10.0
	var def := 12.0
	var max_org := 40.0
	var spd := 0.28
	var hard := 0.0


## Армия игрока: группа дивизий с общим приказом.
class ArmyGroup:
	extends RefCounted
	var id := 0
	var owner := 0
	var name := ""
	var color := Color.WHITE
	var mode := "hold"              # hold — держать фронт, attack — наступать
	var enemy := -1                 # против кого (-1 — все противники)
	var objective := -1             # провинция-цель наступления
	var alive := true
	var front_pairs := PackedInt32Array()   # пары (наша провинция, чужая) для отрисовки фронта


var seed_value := 0
var width := 0
var height := 0
var id_image: Image
var height_image: Image
var province_ids := PackedInt32Array()  # width*height (только процедурная карта)
var ai_wars := true                     # ИИ сам объявляет войны (на исторической карте — нет до этапов 3/5)
var nation_tags := PackedStringArray()
var ideology_names := {}

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
var p_manpower := PackedInt32Array()     # призывной резерв провинции, тыс.
var p_population := PackedInt32Array()   # население, тыс.
var p_colony := PackedByteArray()
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
var tpl_terrain := PackedFloat32Array()   # Military.TERRAIN_MULT построчно (шаблон*8 + местность)
var p_coastal := PackedByteArray()
var p_supply_cap := PackedFloat32Array()  # пропускная способность снабжения провинции (дивизий)
var ally := PackedByteArray()             # nation_count^2: 1 — одна сторона (фракция/сюзерен)
var supply_dist: Array = []               # по странам: PackedInt32Array, переходов до узла снабжения (-1 — нет)
var groups: Array = []                    # Array[ArmyGroup]
var divisions: Array = []
var next_div_id := 1
var day := 0
var prov_divs: Array = []   # province -> Array[Division]
var events: Array = []      # строки для журнала, забирает UI
var palette_dirty := true
var game_over := ""

# Дипломатия
var diplomacy := false          # историческая дипломатия (фракции, претензии); на процедурной карте — нет
var tension := 0.0              # мировая напряжённость, 0..100 %
var factions: Array = []        # Array[Faction]
var pending_peace: Array = []   # [проигравший, победитель] — ждут решения игрока


# --- Время -------------------------------------------------------------------

func date_string() -> String:
	var d := day
	var year := START_YEAR
	while d >= _year_days(year):
		d -= _year_days(year)
		year += 1
	var m := 0
	while d >= _month_days(m, year):
		d -= _month_days(m, year)
		m += 1
	return "%d %s %d г." % [d + 1, MONTHS[m], year]


static func _leap(y: int) -> bool:
	return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0


static func _year_days(y: int) -> int:
	return 366 if _leap(y) else 365


static func _month_days(m: int, y: int) -> int:
	return 29 if m == 1 and _leap(y) else MONTH_DAYS[m]


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
	p_coastal.resize(prov_count)
	p_supply_cap.resize(prov_count)
	for p in prov_count:
		p_coastal[p] = 0
		if p_land[p] == 0:
			p_supply_cap[p] = 0.0
			continue
		for q in p_adj[p]:
			if p_land[q] == 0:
				p_coastal[p] = 1
		var pop := float(p_population[p]) if p_population.size() == prov_count else 0.0
		var cap := 2.0 + minf(3.0, pop / 600.0) + (1.0 if p_terrain[p] == T_URBAN else 0.0)
		match p_terrain[p]:
			T_MOUNTAIN, T_MARSH, T_DESERT:
				cap -= 1.0
			T_FOREST, T_HILLS:
				cap -= 0.5
		p_supply_cap[p] = maxf(1.0, cap)
	Military.build_tables(self)
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


## То же для всех стран за один проход: Array из [гражд., воен., призывники, провинций].
func compute_all_income() -> Array:
	var civ := PackedInt32Array()
	var mil := PackedInt32Array()
	var mp := PackedInt32Array()
	var provs := PackedInt32Array()
	civ.resize(nation_count)
	mil.resize(nation_count)
	mp.resize(nation_count)
	provs.resize(nation_count)
	for p in prov_count:
		var c := p_controller[p]
		if c < 0:
			continue
		provs[c] += 1
		if p_owner[p] == c:
			civ[c] += p_civ[p]
			mil[c] += p_mil[p]
			mp[c] += p_manpower[p]
		else:
			civ[c] += p_civ[p] / 2
			mil[c] += p_mil[p] / 2
			mp[c] += p_manpower[p] / 5
	var res: Array = []
	for n in nation_count:
		res.append([civ[n], mil[n], mp[n], provs[n]])
	return res


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
	if province_ids.is_empty():
		var c := id_image.get_pixel(x, y)
		return int(round(c.r * 255.0)) + int(round(c.g * 255.0)) * 256
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


func spawn_division(owner: int, prov: int, tpl: int = 0) -> Division:
	var d := Division.new()
	d.id = next_div_id
	next_div_id += 1
	d.owner = owner
	d.prov = prov
	d.tpl = tpl
	Military.refresh_division(self, d)
	d.org = d.max_org
	divisions.append(d)
	prov_divs[prov].append(d)
	nations[owner].division_count += 1
	return d


## Низкоуровневое состояние войны между двумя странами (без союзников).
## Полное объявление войны со сторонами — Diplomacy.declare_war.
func set_war(a: int, b: int) -> void:
	if a == b or is_at_war(a, b):
		return
	nations[a].at_war[b] = true
	nations[b].at_war[a] = true
	war[a * nation_count + b] = 1
	war[b * nation_count + a] = 1


func declare_war(a: int, b: int) -> void:
	if a == b or is_at_war(a, b):
		return
	set_war(a, b)
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
