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
	var capitulate_at := 0.3    # капитуляция, когда своих очков победы меньше этой доли
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
	var stock := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0])        # склад по типам (Military.EQ_*)
	var daily_output := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0]) # выпуск за последний день
	var naval_share := 0.0      # доля заводов на судостроение (forces.json)
	var air_share := 0.1        # доля заводов на авиацию
	var trade_penalty := 0.0    # потери выпуска от рейдов подлодок (0..0.3)
	var ship_queue: Array = []  # заложенные корабли: типы Forces.SHIP_*
	var planned_wars := {}      # ИИ: с кем война запланирована фокусами (готовиться заранее)
	var pw_key := ""             # кэш planned_wars: фокус|выполнено (History)
	var pw_day := -100
	var improving := {}         # улучшение отношений: id страны -> true (не больше Relations.IMPROVE_SLOTS)
	var prep_divs := 0          # ИИ: сколько дивизий нужно для условий будущих событий фокусов
	var prep_day := -1          # день последней сверки плана подготовки (-1 — сверить)
	var focus_wait_until := 0   # ИИ ждёт: следующий пересмотр фокусов не раньше этого дня…
	var focus_wait_epoch := -1  # …если в мире ничего не изменилось (World.focus_epoch)
	var aggression := 0.0       # агрессивность: войны, аннексии, ультиматумы (тает ~5 % в месяц)
	var diplo := 0.0            # дипломатическая активность: гарантии, союзы, пакты, помощь, вступление за жертву
	var inv_target := -1        # ИИ: цель готовящейся высадки
	var inv_port := -1          # ИИ: порт посадки
	var lines: Array = []       # производственные линии: [тип снаряжения, заводов, эффективность]
	# распределение заводов (Military.plan_production): желаемые доли по типам,
	# выпуск и склад с прошлого пересмотра, расход снаряжения в день (среднее)
	# внешняя экономика (Economy): добыча, потребность линий, куплено/продано
	# (ед. в день), обеспеченность 0..1; курс — доля добычи на экспорт
	var res_prod := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var res_need := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var res_in := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var res_out := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var res_fill := PackedFloat32Array([1, 1, 1, 1, 1, 1])
	var res_synth := PackedFloat32Array([0, 0, 0, 0, 0, 0])  # синтетика (эффект synthetic)
	var trade_law := 2
	var law_day := -1
	var trade_civ := 0.0        # гражданских заводов уходит на оплату закупок
	var trade_civ_in := 0.0     # и приходит от продаж
	var trade_auto := true      # игрок: закупать ресурсы автоматически
	var trade_closed := false   # марионетка торгует только с сюзереном (Economy.CLOSED_PUPPETS, эффект closed_trade)
	var prod_split: Array = []
	var prod_auto := true       # игрок: распределять заводы автоматически
	var prod_acc := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0])
	var prod_stock := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0])
	var prod_day := -1
	var eq_use := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0])
	var trained_count := 0
	var stats_dirty := true
	var dormant := false        # появится по событию
	var capital_lonlat := Vector2.ZERO
	# Фокусы (этап 5)
	var focus_current := ""
	var focus_days := 0
	var focus_done := {}        # id -> true     # технологии изменились — пересчитать кэш дивизий      # сколько дивизий ИИ уже заказал (для чередования шаблонов)
	var manpower := 0.0         # тысячи человек
	var research_slots := 2     # слотов исследований (Tech.slots_for)
	var research: Array = []    # что в работе по слотам: id технологии или ""
	var research_progress := {} # tech_id -> накоплено дней работы (сохраняется при смене)
	var techs := {}             # tech_id -> true
	var bonus := {}             # bonus_key -> float
	var xp := PackedFloat64Array([0.0, 0.0, 0.0])  # боевой опыт: армия, флот, авиация (Doctrine)
	var doctrines := {}         # id ступени доктрины -> true
	var doctrine_pref := {}     # род сил -> историческая школа (nations.json)
	var air_design := PackedInt32Array([-1, -1])     # проект в производстве: истребители, бомбардировщики (Designs)
	var plane_cost := PackedFloat64Array([1.0, 1.0]) # цена выпуска самолёта по проекту (множитель)
	var no_attack := {}         # страна -> true: воюем, но ИИ не наступает (эффект no_attack — «Странная война»)
	var build_mode := "mil"     # "civ" или "mil"
	var build_progress := 0.0
	var training: Array = []    # в подготовке: [оставшиеся дни, шаблон]
	# Кэш, пересчитывается в экономической фазе (параллельно)
	var civ := 0
	var mil := 0
	var province_count := 0
	var division_count := 0
	var daily_manpower := 0.0

	var spirits := {}           # национальные черты: id -> множитель силы (1 — полная)
	var spirit_bonus := {}      # сумма бонусов черт (World.recalc_spirits)
	var volunteer_acc := 0.0    # накопленные дробные дивизии добровольцев (черты с volunteers)

	func b(key: String) -> float:
		return float(bonus.get(key, 0.0)) + float(spirit_bonus.get(key, 0.0))


class Faction:
	extends RefCounted
	var id := 0
	var name := ""
	var leader := 0
	var color := Color.WHITE
	var alive := true


class Division:
	extends RefCounted
	## Числовое состояние дивизии живёт в плоских массивах мира (World.d_*,
	## индекс — slot): горячие фазы дня считаются по массивам (и в C++), а
	## свойства объекта — удобный доступ для остального кода.
	var w: World
	var slot := -1
	var id := 0
	var group := -1                 # армия игрока (World.groups), -1 — нет
	var transit_total := 0
	var transit_from := -1
	var transit_target := -1
	var transfer := false           # переправа между своими портами (не штурм)
	var _path := PackedInt32Array()
	## следующие провинции, path[0] — ближайшая. Менять только присваиванием
	## (d.path = ...), не на месте: зеркалится в World.d_next.
	var path: PackedInt32Array:
		get:
			return _path
		set(v):
			_path = v
			w.ds_next(slot, v[0] if v.size() > 0 else -1)
	var strength: float:  # 0..100
		get:
			return w.d_str[slot]
		set(v):
			w.ds_str(slot, v)
	var org: float:
		get:
			return w.d_org[slot]
		set(v):
			w.ds_org(slot, v)
	var eq: float:  # укомплектованность снаряжением 0..1
		get:
			return w.d_eq[slot]
		set(v):
			w.ds_eq(slot, v)
	var supply: float:  # снабжение 0..1 (0 — окружена)
		get:
			return w.d_sup[slot]
		set(v):
			w.ds_sup(slot, v)
	var entrench: float:  # окапывание 0..1
		get:
			return w.d_ent[slot]
		set(v):
			w.ds_ent(slot, v)
	var progress: float:  # 0..1 — сколько пройдено к path[0]
		get:
			return w.d_prog[slot]
		set(v):
			w.ds_prog(slot, v)
	var max_org: float:  # кэш характеристик (Military.refresh_division)
		get:
			return w.d_morg[slot]
		set(v):
			w.ds_morg(slot, v)
	var atk: float:
		get:
			return w.d_atk[slot]
		set(v):
			w.ds_atk(slot, v)
	var def: float:
		get:
			return w.d_def[slot]
		set(v):
			w.ds_def(slot, v)
	var spd: float:
		get:
			return w.d_spd[slot]
		set(v):
			w.ds_spd(slot, v)
	var hard: float:
		get:
			return w.d_hard[slot]
		set(v):
			w.ds_hard(slot, v)
	var owner: int:
		get:
			return w.d_owner[slot]
		set(v):
			w.ds_owner(slot, v)
	var prov: int:
		get:
			return w.d_prov[slot]
		set(v):
			w.ds_prov(slot, v)
	var tpl: int:  # Military.T_*
		get:
			return w.d_tpl[slot]
		set(v):
			w.ds_tpl(slot, v)
	var transit_days: int:  # > 0 — в море (высадка), см. Forces
		get:
			return w.d_transit[slot]
		set(v):
			w.ds_transit(slot, v)
	var plan: float:  # планирование 0…1 (атака × (1 + PLAN_MAX × план), Simulation.PLAN_*)
		get:
			return w.d_plan[slot]
		set(v):
			w.d_plan[slot] = v
	var reserved_until: int:  # ИИ держит дивизию под десант до этого дня
		get:
			return w.d_resv[slot]
		set(v):
			w.ds_resv(slot, v)
	var inv_plan: int:  # участвует в плане высадки (World.invasions)
		get:
			return w.d_inv[slot]
		set(v):
			w.ds_inv(slot, v)
	var alive: bool:
		get:
			return w.d_alive[slot] == 1
		set(v):
			w.ds_alive(slot, 1 if v else 0)
	var in_battle: bool:
		get:
			return w.d_battle[slot] == 1
		set(v):
			w.ds_battle(slot, 1 if v else 0)
	var landing: bool:  # высаживается с моря: атака ослаблена
		get:
			return w.d_land[slot] == 1
		set(v):
			w.ds_land(slot, 1 if v else 0)


## Флот: корабли по типам (Forces.SHIP_*), стоит в морской зоне (провинция-море).
class Fleet:
	extends RefCounted
	var id := 0
	var owner := 0
	var name := ""
	var ships := PackedInt32Array([0, 0, 0, 0])   # линкоры, крейсеры, эсминцы, подлодки
	var zone := -1
	var home := -1                  # морская зона у главного порта
	var path := PackedInt32Array()
	var mission := "patrol"         # patrol — господство и бои, raid — рейды на торговлю, port — в порту
	var alive := true
	var in_battle := false
	var task_until := 0             # прикрывает высадку до этого дня (ИИ не уводит в порт)
	var readiness := 1.0            # готовность 0..1: падает в боях, восстанавливается на военно-морской базе
	var share := 1.0                # доля новых кораблей своего рода (флоты по базам, squadrons)
	var quality := 1.0              # множитель боевой силы от технологий (Forces.refresh_quality)


## План морской высадки: подготовка 30–60 дней, войска ждут в порту посадки.
class InvasionPlan:
	extends RefCounted
	var id := 0
	var owner := 0
	var port := -1                  # провинция посадки
	var target := -1                # цель на вражеском побережье
	var divs: Array = []            # id дивизий
	var days_left := 0
	var total := 0
	var alive := true


## Авиакрыло: истребители или бомбардировщики над воздушным районом.
class AirWing:
	extends RefCounted
	var id := 0
	var owner := 0
	var name := ""
	var kind := 0                   # 0 — истребители, 1 — бомбардировщики
	var planes := 0.0
	var region := -1
	var design := -1                # проект самолётов (World.plane_designs), -1 — нынешний у владельца
	var mission := "sup"            # sup — превосходство, cas — поддержка войск, bomb — бомбёжка заводов, naval — удары по флоту
	var alive := true


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
var terrain_image: Image                # подложка рельефа (может не быть)
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
var p_adm0 := PackedStringArray()       # код современной страны (Natural Earth) — для исторических областей
var p_lonlat := PackedVector2Array()
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
var p_def_mult := PackedFloat32Array()   # оборона провинции: местность + укрепления + зима (refresh_def_mult)
var p_fort := PackedFloat32Array()       # укрепления провинции (forts.json): добавка к обороне
var _def_month := -1                     # месяц, для которого посчитана зимняя добавка   # константные Array/Dictionary скриптов из потоков не трогаем
var n_attack := PackedFloat32Array()
var n_defense := PackedFloat32Array()
var n_org := PackedFloat32Array()
var n_speed := PackedFloat32Array()
# качество флота и авиации по странам (технологии): корабли — страна×4 рода,
# авиация — страна×4 (истребители, поддержка войск, бомбардировки, удары по флоту)
var n_ship := PackedFloat64Array()
var n_air := PackedFloat64Array()
var n_air_def := PackedFloat64Array()
var res_prov := PackedInt32Array()       # провинции с ресурсами (Economy)
var res_ctrl := PackedInt32Array()        # кэш: хозяин провинции с ресурсами при последнем пересчёте добычи
var res_val := PackedFloat32Array()       # их добыча: i*6 + ресурс
var contracts: Array = []                 # поставки: [покупатель, продавец, ресурс, ед., до дня, —, со след. месяца]
var trade_score := PackedFloat32Array()
var trade_adj := PackedByteArray()       # соседство стран N×N (Economy.refresh_geo, раз в месяц)
var p_mass := PackedInt32Array()          # номер материка (связной суши) провинции; −1 — море
var trade_mass: Dictionary = {}           # узел «материк*N + страна» -> соседние узлы (Economy.refresh_geo)
var trade_block := PackedByteArray()     # морская блокада: [покупатель*N + продавец] = 1 — путь отрезан (Economy.refresh_blockade)
var trade_coast := PackedByteArray()     # выход к морю
var trade_geo_day := -100
var embargoes := {}                       # продавец*100000 + покупатель → эмбарго (Economy.embargo)
var spec_gid := -1                        # фоновая группа упреждающих расчётов (Spec)
var rel_job := {}                          # шкала сил/естественные отношения на завтра (Relations.spec)
var prod_job := {}                         # доли заводов на завтра (Military.spec)
var reach_job := {}                       # сухопутные соседи на завтра (Forces.spec)
var trade_job := {}                       # фоновые строки рейтинга на завтра (Economy.start_rank)
var trade_tab := {}                       # снимок для рейтинга (Economy.trade_tables, раз в месяц)   # рейтинг покупателей у продавца: s*N + b (раз в месяц)
var templates: Array = []               # шаблоны дивизий (Military.make_template): 0–5 общие, дальше — проекты стран
var tpl_eq := PackedFloat64Array()       # templates[t]["eq"][k] — шаблон*7 + k
var tpl_cls := PackedInt32Array()        # класс шаблона (Military.T_*) — значок и роль
var tpl_motor := PackedInt32Array()      # 1 — моторизован (снабжение ×1,5)
var tpl_men := PackedFloat64Array()
var tpl_terrain := PackedFloat32Array()   # Military.TERRAIN_MULT построчно (шаблон*8 + местность)
var p_coastal := PackedByteArray()
var p_supply_cap := PackedFloat32Array()  # пропускная способность снабжения провинции (дивизий)
var p_supply_base := PackedFloat32Array() # она же без повреждений от бомбёжек
var p_bomb := PackedFloat32Array()        # повреждения от стратегических бомбёжек 0..1 (Forces)
var bombed := {}                          # провинция -> true: есть повреждения (чинятся каждый день)
var ally := PackedByteArray()             # nation_count^2: 1 — одна сторона (фракция/сюзерен)
var supply_regions := true               # снабжение по узлам районов (Supply), иначе — по удалённости от узлов
var reg_adj_start := PackedInt32Array()   # соседство районов по суше (Supply._static)
var reg_adj_list := PackedInt32Array()
var p_supcap := PackedFloat32Array()      # ёмкость снабжения провинции в «дивизиях» (Supply → AIPlanner)
var sup_job := {}                         # поле подачи на завтра (Supply.spec)
var sup_args: Array = []                  # стороны, источники, столицы сегодняшней фазы снабжения
var supply_dist: Array = []               # по странам: PackedInt32Array, переходов до узла снабжения (-1 — нет)
var groups: Array = []                    # Array[ArmyGroup]
# Флот и авиация (этап 6)
var fleets: Array = []                    # Array[Fleet]
var wings: Array = []                     # Array[AirWing]
var plane_designs: Array = []             # проекты самолётов (Designs.add): словари характеристик
var region_count := 0
var p_region := PackedInt32Array()        # воздушный район провинции
var p_air_src := PackedInt32Array()       # район из map.json (стратегический регион); пусто — сетка
var air_region_names := PackedStringArray()
var region_center := PackedVector2Array() # центр района (пиксели карты)
var region_name := PackedStringArray()
var region_anchor := PackedInt32Array()   # главная провинция района (для значков)
var region_provs: Array = []              # район -> PackedInt32Array провинций
var trade_cache := {}
var air_range_cache := {}
# Снимок дивизий для параллельных фаз (World.k_snapshot): плоские
# массивы вместо объектов — потоки не дерутся за счётчики ссылок.
var dv_id := PackedInt32Array()
var dv_owner := PackedInt32Array()
var dv_prov := PackedInt32Array()
var dv_flags := PackedInt32Array()      # 1 — свободна (без пути и боя, не в море, не в резерве), 2 — в бою
var dv_str := PackedFloat32Array()
var dv_org := PackedFloat32Array()      # доля организации 0..1
var dv_power := PackedFloat32Array()    # атакующая сила с учётом силы, снаряжения, снабжения
var dv_defw := PackedFloat32Array()     # «вес» защитника для оценки целей
var pd_start := PackedInt32Array()      # CSR: дивизии провинции p — pd_list[pd_start[p] .. pd_start[p+1])
var pd_list := PackedInt32Array()                 # страна -> [день, районы в радиусе авиации]                     # страна -> Dictionary торговых зон (пересчёт раз в 30 дней)
var cas_mult := PackedFloat32Array()      # region*nation_count + n: множитель боя от авиации
var air_sup := PackedFloat32Array()       # region*nation_count + n: превосходство в воздухе 0..1
var invasions: Array = []                 # Array[InvasionPlan]
var naval_bases := PackedInt32Array()    # кэш Forces.base_list
var port_list := PackedInt32Array()      # провинции-порты (Forces.refresh_ports)
var p_naval_base := PackedByteArray()     # 1 — военно-морская база (стоянка и ремонт флота)
var p_port := PackedByteArray()           # 1 — постоянный порт (город vp≥3 на побережье или база)
var beachheads := {}                      # провинция -> последний день временного порта на плацдарме
var zone_fleets := {}                     # морская зона -> Array[Fleet] (кэш на день)
# Состояние дивизий (SoA, индекс — Division.slot, порядок = world.divisions).
var d_str := PackedFloat64Array()
var d_org := PackedFloat64Array()
var d_eq := PackedFloat64Array()
var d_sup := PackedFloat64Array()
var d_ent := PackedFloat64Array()
var d_prog := PackedFloat64Array()
var d_morg := PackedFloat64Array()
var d_atk := PackedFloat64Array()
var d_def := PackedFloat64Array()
var d_spd := PackedFloat64Array()
var d_hard := PackedFloat64Array()
var d_owner := PackedInt32Array()
var d_prov := PackedInt32Array()
var d_tpl := PackedInt32Array()
var d_transit := PackedInt32Array()
var d_resv := PackedInt32Array()
var d_plan := PackedFloat64Array()        # планирование наступления 0…1 (k_plan)
var d_inv := PackedInt32Array()
var d_next := PackedInt32Array()      # path[0] или -1
var d_id := PackedInt32Array()
var d_alive := PackedByteArray()
var d_battle := PackedByteArray()
var d_land := PackedByteArray()
var divisions: Array = []
var next_div_id := 1
var day := 0
# Кто стоит в провинции: двусвязные списки по слотам дивизий (живые и не в
# море). Обновляются сами в ds_prov/ds_transit/ds_alive; раз в день —
# пересборка в порядке слотов (rebuild_prov_divs). Читать — divs_in(p).
var pl_head := PackedInt32Array()
var pl_tail := PackedInt32Array()
var d_nx := PackedInt32Array()
var d_pv := PackedInt32Array()
var d_inl := PackedByteArray()
var events: Array = []      # строки для журнала, забирает UI
var palette_dirty := true
var game_over := ""

# Дипломатия
var diplomacy := false          # историческая дипломатия (фракции, претензии); на процедурной карте — нет
var tension := 0.0              # мировая напряжённость, 0..100 %
var factions: Array = []        # Array[Faction]
var pending_peace: Array = []
# История (этап 5)
var historical := true          # исторический ИИ: фокусы и события по истории, без случайной агрессии
var flags := {}
var focus_trees := {}           # тег -> Array фокусов (Dictionary); "_generic" — для остальных
var focus_index := {}           # тег -> {id: фокус} — History.focus_def
var spirit_defs := {}           # национальные черты (spirits.json): id -> {name, desc, bonus}
var focus_epoch := 0            # растёт при войнах, мире, союзах, событиях — будит ждущих ИИ
var event_defs := {}            # id -> Dictionary
var areas := {}
var capitulation_rules: Array = []
var event_queue: Array = []     # [id события, номер страны-инициатора] — ждут условий
var scheduled: Array = []       # [день, номер страны, эффекты] — отложенные эффекты («через N дней»)
var events_fired := {}
var pending_events: Array = []  # [id события] — ждут выбора игрока (игра идёт, если игрок снял паузу)
var pending_since := {}         # id события -> день, когда оно пришло игроку
const EVENT_ANSWER_DAYS := 14   # срок ответа на событие с выбором; потом вариант выбирается сам
var info_events: Array = []     # [id события] — уже применены (без выбора), игроку показать лист
# отношения (Relations): репутация A→B в rep[A * rep_n + B], 0–100
var rep := PackedFloat32Array()
var rep_n := 0
var aid := {}                   # from * 100000 + to -> день помощи
var trade_bonus := {}           # from * 100000 + to -> добавка к торговому влиянию, %
var event_from := {}            # id события -> кто его вызвал (номер страны)
var event_snap := {}            # id события -> {ключ шанса: %} — условия на день завершения фокуса
var ev_ctx := {}                # контекст выполняемого события: {"target", "from"}
var threat := {}                # строй -> {"pct", "parts": {армия, экономика, наука, союз, агрессия}} — Relations.update_threat
var chance_log: Array = []      # [день, id события, шанс %, исторический ли исход, чего не хватало] — для проверки баланса
var info_option := {}           # id события -> применённый вариант


## Какое событие показать игроку: сначала ждущие выбора, потом уже применённые.
## [id, только для прочтения] или [] — показывать нечего.
func event_front() -> Array:
	if not pending_events.is_empty():
		return [pending_events[0], false]
	if not info_events.is_empty():
		return [info_events[0], true]
	return []   # [проигравший, победитель] — ждут решения игрока


# --- Время -------------------------------------------------------------------

## Номер дня по дате «ГГГГ-ММ-ДД» (день 0 — 1 января 1936 г.).
var _day_of_cache := {}


## Месяц (0–11) дня игры.
func month_of(at: int) -> int:
	var d := at
	var year := START_YEAR
	while d >= _year_days(year):
		d -= _year_days(year)
		year += 1
	var m := 0
	while d >= _month_days(m, year):
		d -= _month_days(m, year)
		m += 1
	return m


## Оборона провинций: местность + укрепления + зима. Зима (как погода в жанре):
## декабрь–март севернее 60° — +0,4, севернее 55° — +0,25, декабрь–февраль
## 48–55° — +0,12. Пересчёт раз в месяц; одинаково для GDScript и C++ (массив).
func refresh_def_mult() -> void:
	var m := month_of(day)
	if m == _def_month and p_def_mult.size() == prov_count:
		return
	_def_month = m
	p_def_mult.resize(prov_count)
	var deep := m == 11 or m <= 2
	var mid := m == 11 or m <= 1
	for p in prov_count:
		var v: float = TERRAIN_DEFENSE[p_terrain[p]] + (p_fort[p] if p < p_fort.size() else 0.0)
		if p_land[p] == 1:
			var lat := p_lonlat[p].y
			if deep and lat >= 60.0:
				v += 0.4   # полярная зима: Карелия, Финляндия, север России
			elif deep and lat >= 55.0:
				v += 0.25
			elif mid and lat >= 48.0:
				v += 0.12
		p_def_mult[p] = v


func day_of(date: String) -> int:
	# даты условий фокусов и событий проверяются каждый день — разбирать один раз
	var cached = _day_of_cache.get(date)
	if cached != null:
		return cached
	var r := _day_of_parse(date)
	_day_of_cache[date] = r
	return r


func _day_of_parse(date: String) -> int:
	var parts := date.split("-")
	if parts.size() < 3:
		return 0
	var y := int(parts[0])
	var m := int(parts[1]) - 1
	var d := int(parts[2]) - 1
	var total := 0
	for yy in range(START_YEAR, y):
		total += _year_days(yy)
	for mm in m:
		total += _month_days(mm, y)
	return total + d


## Короткая дата «29.09.1938» (для телеграмм и документов).
func date_short(at: int = -1) -> String:
	var d := day if at < 0 else at
	var year := START_YEAR
	while d >= _year_days(year):
		d -= _year_days(year)
		year += 1
	var m := 0
	while d >= _month_days(m, year):
		d -= _month_days(m, year)
		m += 1
	return "%02d.%02d.%d" % [d + 1, m + 1, year]


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


## Пропускная способность снабжения провинции с учётом повреждений от бомбёжек.
func apply_bomb(p: int) -> void:
	p_supply_cap[p] = maxf(0.5, p_supply_base[p] * (1.0 - Forces.BOMB_SUPPLY * p_bomb[p]))


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
	if p_fort.size() != prov_count:
		p_fort.resize(prov_count)
	for p in prov_count:
		p_move_mult[p] = TERRAIN_MOVE[p_terrain[p]]
	_def_month = -1
	refresh_def_mult()
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
	p_supply_base = p_supply_cap.duplicate()
	if p_bomb.size() != prov_count:
		p_bomb.resize(prov_count)
		p_bomb.fill(0.0)
	for p in bombed:
		apply_bomb(int(p))
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
	# качество флота и авиации меняется только с бонусами (stats_dirty)
	var changed := n_ship.size() != nation_count * 4
	for n in nations:
		changed = changed or n.stats_dirty
	if not changed:
		return
	n_ship.resize(nation_count * 4)
	n_air.resize(nation_count * 4)
	n_air_def.resize(nation_count)
	for n in nations:
		var nav: float = 1.0 + n.b("naval")
		n_ship[n.id * 4] = nav + n.b("ship_bb")
		n_ship[n.id * 4 + 1] = nav + n.b("ship_cr")
		n_ship[n.id * 4 + 2] = nav + n.b("ship_dd")
		n_ship[n.id * 4 + 3] = nav + n.b("ship_ss")
		var air: float = 1.0 + n.b("air")
		n_air[n.id * 4] = air + n.b("air_fighter")
		n_air[n.id * 4 + 1] = air + n.b("air_cas")
		n_air[n.id * 4 + 2] = air + n.b("air_bomb")
		n_air[n.id * 4 + 3] = air + n.b("air_naval")
		n_air_def[n.id] = clampf(n.b("air_def"), 0.0, 0.6)


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
	if Native.core != null:
		var r: PackedInt32Array = Native.core.call("income", p_controller, p_owner, p_civ, p_mil, p_manpower, nation_count)
		var out: Array = []
		for n in nation_count:
			out.append([r[n * 4], r[n * 4 + 1], r[n * 4 + 2], r[n * 4 + 3]])
		return out
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
	var h := pl_head[prov]
	while h >= 0:
		if is_at_war(nation, d_owner[h]):
			return true
		h = d_nx[h]
	return false


## Дивизии в провинции (живые, не в море) — новый массив, порядок списка.
func divs_in(p: int) -> Array:
	var res: Array = []
	var h := pl_head[p]
	while h >= 0:
		res.append(divisions[h])
		h = d_nx[h]
	return res


func divs_count(p: int) -> int:
	var n := 0
	var h := pl_head[p]
	while h >= 0:
		n += 1
		h = d_nx[h]
	return n


func _link(i: int) -> void:
	var p := d_prov[i]
	var t := pl_tail[p]
	d_pv[i] = t
	d_nx[i] = -1
	if t >= 0:
		d_nx[t] = i
	else:
		pl_head[p] = i
	pl_tail[p] = i
	d_inl[i] = 1


func _unlink(i: int) -> void:
	var p := d_prov[i]
	var a := d_pv[i]
	var b := d_nx[i]
	if a >= 0:
		d_nx[a] = b
	else:
		pl_head[p] = b
	if b >= 0:
		d_pv[b] = a
	else:
		pl_tail[p] = a
	d_inl[i] = 0


## Членство в списке провинции: живая и не в море.
func _sync_link(i: int) -> void:
	if pl_head.size() != prov_count:
		return   # списков ещё нет (или это «запись мёртвых»)
	var want := d_alive[i] == 1 and d_transit[i] <= 0
	if want and d_inl[i] == 0:
		_link(i)
	elif not want and d_inl[i] == 1:
		_unlink(i)


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

## Уплотнить массивы дивизий и пересобрать списки провинций в порядке слотов.
func rebuild_prov_divs() -> void:
	compact_divisions()
	var counts := k_relink()
	for n in nations:
		n.division_count = counts[n.id]


## Пересборка списков провинций (ядро; C++ — MeowqCore.relink). Возвращает
## число дивизий по странам.
## Стопки фишек для отрисовки: по провинциям, страны в порядке первого
## появления в списке провинции. [prov, owner, n, tpl, str_sum, org_sum, min_sup]
## (org — сумма org/max_org). C++ — MeowqCore.counters, результаты совпадают.
func k_counters() -> Array:
	if Native.core != null:
		return Native.core.call("counters", pl_head, d_nx, d_alive, d_owner, d_str, d_org, d_morg, d_sup, Native.gather_i32(tpl_cls, d_tpl))
	var d_cls := Native.gather_i32(tpl_cls, d_tpl)
	var o_prov := PackedInt32Array()
	var o_owner := PackedInt32Array()
	var o_n := PackedInt32Array()
	var o_tpl := PackedInt32Array()
	var o_str := PackedFloat64Array()
	var o_org := PackedFloat64Array()
	var o_sup := PackedFloat64Array()
	var g_owner := PackedInt32Array()
	var g_n := PackedInt32Array()
	var g_str := PackedFloat64Array()
	var g_org := PackedFloat64Array()
	var g_sup := PackedFloat64Array()
	var g_tc := PackedInt32Array()
	for p in prov_count:
		var h := pl_head[p]
		if h < 0:
			continue
		g_owner.clear()
		g_n.clear()
		g_str.clear()
		g_org.clear()
		g_sup.clear()
		g_tc.clear()
		while h >= 0:
			if d_alive[h] != 0:
				var o := d_owner[h]
				var k := g_owner.find(o)
				if k < 0:
					k = g_owner.size()
					g_owner.append(o)
					g_n.append(0)
					g_str.append(0.0)
					g_org.append(0.0)
					g_sup.append(1.0)
					g_tc.resize(g_tc.size() + 8)
				g_n[k] += 1
				g_str[k] += d_str[h]
				g_org[k] += d_org[h] / maxf(1.0, d_morg[h])
				g_sup[k] = minf(g_sup[k], d_sup[h])
				g_tc[k * 8 + clampi(d_cls[h], 0, 7)] += 1
			h = d_nx[h]
		for k in g_owner.size():
			var main_t := 0
			for t in range(1, 8):
				if g_tc[k * 8 + t] > g_tc[k * 8 + main_t]:
					main_t = t
			o_prov.append(p)
			o_owner.append(g_owner[k])
			o_n.append(g_n[k])
			o_tpl.append(main_t)
			o_str.append(g_str[k])
			o_org.append(g_org[k])
			o_sup.append(g_sup[k])
	return [o_prov, o_owner, o_n, o_tpl, o_str, o_org, o_sup]


func k_relink() -> PackedInt32Array:
	if Native.core != null:
		var r: Array = Native.core.call("relink", d_alive, d_transit, d_prov, d_owner, prov_count, nations.size())
		pl_head = r[0]
		pl_tail = r[1]
		d_nx = r[2]
		d_pv = r[3]
		d_inl = r[4]
		return r[5]
	pl_head.resize(prov_count)
	pl_head.fill(-1)
	pl_tail.resize(prov_count)
	pl_tail.fill(-1)
	var n := d_id.size()
	d_nx.resize(n)
	d_pv.resize(n)
	d_inl.resize(n)
	var counts := PackedInt32Array()
	counts.resize(nations.size())
	for i in n:
		counts[d_owner[i]] += 1
		if d_alive[i] == 1 and d_transit[i] <= 0:
			_link(i)
		else:
			d_inl[i] = 0
			d_nx[i] = -1
			d_pv[i] = -1
	return counts


func spawn_division(owner: int, prov: int, tpl: int = 0) -> Division:
	var d := Division.new()
	d.w = self
	d.slot = _d_append()
	d.id = next_div_id
	d_id[d.slot] = d.id
	next_div_id += 1
	d.owner = owner
	d.prov = prov
	d.tpl = tpl
	Military.refresh_division(self, d)
	d.org = d.max_org
	divisions.append(d)
	_sync_link(d.slot)
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
	if not contracts.is_empty():
		Economy.on_war(self, a, b)   # война рвёт поставки сразу


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


# --- Доступ к состоянию дивизий (запись в свой массив — без копирования) ---

func ds_str(i: int, v) -> void:
	d_str[i] = v


func ds_org(i: int, v) -> void:
	d_org[i] = v


func ds_eq(i: int, v) -> void:
	d_eq[i] = v


func ds_sup(i: int, v) -> void:
	d_sup[i] = v


func ds_ent(i: int, v) -> void:
	d_ent[i] = v


func ds_prog(i: int, v) -> void:
	d_prog[i] = v


func ds_morg(i: int, v) -> void:
	d_morg[i] = v


func ds_atk(i: int, v) -> void:
	d_atk[i] = v


func ds_def(i: int, v) -> void:
	d_def[i] = v


func ds_spd(i: int, v) -> void:
	d_spd[i] = v


func ds_hard(i: int, v) -> void:
	d_hard[i] = v


func ds_owner(i: int, v) -> void:
	d_owner[i] = v


func ds_prov(i: int, v) -> void:
	if d_inl[i] == 1 and d_prov[i] != v:
		_unlink(i)
		d_prov[i] = v
		_link(i)
	else:
		d_prov[i] = v


func ds_tpl(i: int, v) -> void:
	d_tpl[i] = v


func ds_transit(i: int, v) -> void:
	d_transit[i] = v
	_sync_link(i)


func ds_resv(i: int, v) -> void:
	d_resv[i] = v


func ds_inv(i: int, v) -> void:
	d_inv[i] = v


func ds_next(i: int, v) -> void:
	d_next[i] = v


func ds_id(i: int, v) -> void:
	d_id[i] = v


func ds_alive(i: int, v) -> void:
	d_alive[i] = v
	_sync_link(i)


func ds_battle(i: int, v) -> void:
	d_battle[i] = v


func ds_land(i: int, v) -> void:
	d_land[i] = v


## Новая запись дивизии в массивах (значения по умолчанию).
func _d_append() -> int:
	d_str.append(100.0)
	d_org.append(40.0)
	d_eq.append(1.0)
	d_sup.append(1.0)
	d_ent.append(0.0)
	d_prog.append(0.0)
	d_morg.append(40.0)
	d_atk.append(10.0)
	d_def.append(12.0)
	d_spd.append(0.28)
	d_hard.append(0.0)
	d_owner.append(0)
	d_prov.append(0)
	d_tpl.append(0)
	d_transit.append(0)
	d_resv.append(0)
	d_plan.append(0.0)
	d_inv.append(-1)
	d_next.append(-1)
	d_id.append(0)
	d_alive.append(1)
	d_battle.append(0)
	d_land.append(0)
	d_nx.append(-1)
	d_pv.append(-1)
	d_inl.append(0)
	return d_id.size() - 1


## Убрать погибшие дивизии из списка и массивов (порядок живых сохраняется).
func compact_divisions() -> void:
	var n := d_alive.size()
	var dead := d_alive.count(0)
	if dead == 0:
		return
	var keep := PackedInt32Array()
	keep.resize(n - dead)
	var alive_list: Array = []
	alive_list.resize(n - dead)
	var j := 0
	for i in n:
		if d_alive[i] == 1:
			keep[j] = i
			alive_list[j] = divisions[i]
			j += 1
		else:
			_bury(divisions[i])
	d_str = Native.gather_f64(d_str, keep)
	d_org = Native.gather_f64(d_org, keep)
	d_eq = Native.gather_f64(d_eq, keep)
	d_sup = Native.gather_f64(d_sup, keep)
	d_ent = Native.gather_f64(d_ent, keep)
	d_prog = Native.gather_f64(d_prog, keep)
	d_morg = Native.gather_f64(d_morg, keep)
	d_atk = Native.gather_f64(d_atk, keep)
	d_def = Native.gather_f64(d_def, keep)
	d_spd = Native.gather_f64(d_spd, keep)
	d_hard = Native.gather_f64(d_hard, keep)
	d_owner = Native.gather_i32(d_owner, keep)
	d_prov = Native.gather_i32(d_prov, keep)
	d_tpl = Native.gather_i32(d_tpl, keep)
	d_transit = Native.gather_i32(d_transit, keep)
	d_resv = Native.gather_i32(d_resv, keep)
	d_plan = Native.gather_f64(d_plan, keep)
	d_inv = Native.gather_i32(d_inv, keep)
	d_next = Native.gather_i32(d_next, keep)
	d_id = Native.gather_i32(d_id, keep)
	d_alive = Native.gather_u8(d_alive, keep)
	d_battle = Native.gather_u8(d_battle, keep)
	d_land = Native.gather_u8(d_land, keep)
	for k in alive_list.size():
		alive_list[k].slot = k
	divisions = alive_list


func clear_divisions() -> void:
	divisions.clear()
	d_nx = PackedInt32Array()
	d_pv = PackedInt32Array()
	d_inl = PackedByteArray()
	pl_head.resize(prov_count)
	pl_head.fill(-1)
	pl_tail.resize(prov_count)
	pl_tail.fill(-1)
	d_str = PackedFloat64Array()
	d_org = PackedFloat64Array()
	d_eq = PackedFloat64Array()
	d_sup = PackedFloat64Array()
	d_ent = PackedFloat64Array()
	d_prog = PackedFloat64Array()
	d_morg = PackedFloat64Array()
	d_atk = PackedFloat64Array()
	d_def = PackedFloat64Array()
	d_spd = PackedFloat64Array()
	d_hard = PackedFloat64Array()
	d_owner = PackedInt32Array()
	d_prov = PackedInt32Array()
	d_tpl = PackedInt32Array()
	d_transit = PackedInt32Array()
	d_resv = PackedInt32Array()
	d_plan = PackedFloat64Array()
	d_inv = PackedInt32Array()
	d_next = PackedInt32Array()
	d_id = PackedInt32Array()
	d_alive = PackedByteArray()
	d_battle = PackedByteArray()
	d_land = PackedByteArray()


## Разорвать ссылки дивизий на мир (иначе цикл «мир ↔ дивизия» не освобождается).
func dispose() -> void:
	for d in divisions:
		d.w = null
	divisions.clear()


static var _grave: World = null


## Погибшая дивизия после уплотнения массивов: ссылки на неё (выбор в
## интерфейсе, списки боёв) читают отдельную запись «мёртвых», а не чужой слот.
func _bury(d: Division) -> void:
	if _grave == null:
		_grave = World.new()
	var g := _grave
	var s := d.slot
	var k := g._d_append()
	g.ds_str(k, d_str[s])
	g.ds_org(k, d_org[s])
	g.ds_eq(k, d_eq[s])
	g.ds_owner(k, d_owner[s])
	g.ds_prov(k, d_prov[s])
	g.ds_tpl(k, d_tpl[s])
	g.ds_id(k, d_id[s])
	g.ds_alive(k, 0)
	d.w = g
	d.slot = k


# --- Горячие фазы дня по массивам дивизий (ядра) -----------------------------
# Каждое ядро есть в двух вариантах: здесь (GDScript, меняет массивы мира на
# месте) и в C++ (MeowqCore, native/src/kernels.cpp — возвращает новые массивы).
# Формулы и порядок обхода обязаны совпадать до бита: sim_bench сравнивает.

## Восстановление: организация, окапывание, окружение, пополнение со складов.
## stock — склады стран подряд (страна*7 + тип), manpower — призывники стран.
## Возвращает слоты дивизий, погибших в окружении.
func k_recovery(stock: PackedFloat32Array, manpower: PackedFloat64Array, rbonus: PackedFloat64Array) -> Array:
	if Native.core != null:
		var r: Array = Native.core.call("recovery", d_alive, d_transit, d_sup, d_org, d_morg, d_str, d_eq, d_ent,
				d_next, d_battle, d_owner, d_prov, d_tpl, p_controller, ally, nation_count, stock, manpower, rbonus,
				tpl_eq, tpl_men)
		d_org = r[0]
		d_str = r[1]
		d_eq = r[2]
		d_ent = r[3]
		return [r[4], r[5], r[6]]
	var dead := PackedInt32Array()
	var nc := nation_count
	for i in d_id.size():
		if d_alive[i] == 0 or d_transit[i] > 0:
			continue
		var sup := d_sup[i]
		if sup <= 0.0:
			# окружение: организация не восстанавливается, части тают
			d_org[i] = maxf(0.0, d_org[i] - d_morg[i] * 0.02)
			d_str[i] = maxf(0.0, d_str[i] - 0.6)
			d_eq[i] = maxf(0.0, d_eq[i] - 0.004)
			if d_str[i] <= 5.0:
				dead.append(i)
			continue
		d_ent[i] = minf(1.0, d_ent[i] + 0.05) if d_next[i] < 0 else 0.0
		if d_battle[i] != 0:
			continue
		var rate := 0.06 if d_next[i] < 0 else 0.03
		d_org[i] = minf(d_morg[i], d_org[i] + d_morg[i] * rate * (0.3 + 0.7 * sup))
		var o := d_owner[i]
		var c := p_controller[d_prov[i]]
		if c != o and ally[o * nc + c] != 1:
			continue
		# пополнение (Military.reinforce)
		if sup < 0.3 or (d_eq[i] >= 1.0 and d_str[i] >= 100.0):
			continue
		var t := d_tpl[i]
		var rr := 0.04 * (1.0 + rbonus[o]) * sup
		if d_eq[i] < 1.0:
			var want := minf(1.0 - d_eq[i], rr)
			for k in 7:
				var e := tpl_eq[t * 7 + k]
				if e > 0:
					want = minf(want, stock[o * 7 + k] / e)
			if want > 0.0:
				for k in 7:
					stock[o * 7 + k] -= tpl_eq[t * 7 + k] * want
				d_eq[i] += want
		if d_str[i] < 100.0:
			var add := minf(100.0 - d_str[i], rr * 100.0)
			var men := add / 100.0 * tpl_men[t]
			if manpower[o] >= men:
				manpower[o] -= men
				d_str[i] += add
	return [stock, manpower, dead]


## Снабжение дивизий: side_of — номер стороны страны (-1 — нет сети),
## dist — расстояния до узлов по сторонам подряд (сторона*prov_count + p).
func k_supply(side_of: PackedInt32Array, dist: PackedInt32Array) -> void:
	# моторизованность по шаблону: 1 — да (порог t_mot = 1 в ядре)
	var mot := Native.gather_i32(tpl_motor, d_tpl)
	if Native.core != null:
		d_sup = Native.core.call("supply_apply", d_alive, d_sup, d_prov, mot, d_owner, side_of, dist, p_supply_cap, prov_count, 1)
		return
	var demand := PackedFloat32Array()
	demand.resize(prov_count)
	var n := d_id.size()
	for i in n:
		if d_alive[i] == 1:
			demand[d_prov[i]] += 1.5 if mot[i] >= 1 else 1.0
	for i in n:
		if d_alive[i] == 0:
			continue
		var s := side_of[d_owner[i]]
		var p := d_prov[i]
		var h: int = dist[s * prov_count + p] if s >= 0 else -1
		if h < 0:
			d_sup[i] = 0.0
			continue
		var reach := 1.0 if h <= 5 else maxf(0.35, 1.0 - (h - 5) * 0.06)
		var cap := minf(1.0, p_supply_cap[p] / maxf(1.0, demand[p]))
		d_sup[i] = reach * cap


## Сбор боёв и шаг движения. Сбрасывает «в бою», считает новый прогресс
## идущих дивизий. Возвращает [пути сброшены (нельзя войти), атакующие по
## порядку, идущие по порядку].
func k_march() -> Array:
	if Native.core != null:
		var r: Array = Native.core.call("march", d_alive, d_transit, d_next, d_owner, d_prov, d_prog, d_spd, d_org,
				d_morg, d_sup, p_land, p_controller, war, nation_count, p_move_mult)
		d_battle.fill(0)
		d_prog = r[0]
		d_next = r[1]
		return [r[2], r[3], r[4]]
	d_battle.fill(0)
	var n := d_id.size()
	var nc := nation_count
	# кто стоит в провинциях: CSR по слотам
	var start := PackedInt32Array()
	start.resize(prov_count + 1)
	for i in n:
		if d_alive[i] == 1 and d_transit[i] <= 0:
			start[d_prov[i] + 1] += 1
	for p in prov_count:
		start[p + 1] += start[p]
	var list := PackedInt32Array()
	list.resize(start[prov_count])
	var fill := start.duplicate()
	for i in n:
		if d_alive[i] == 1 and d_transit[i] <= 0:
			list[fill[d_prov[i]]] = i
			fill[d_prov[i]] += 1
	var cleared := PackedInt32Array()
	var attackers := PackedInt32Array()
	var movers := PackedInt32Array()
	for i in n:
		var t := d_next[i]
		if t < 0 or d_transit[i] > 0:
			continue
		var o := d_owner[i]
		var c := p_controller[t]
		if p_land[t] == 0 or (c != o and (c < 0 or o < 0 or c == o or war[o * nc + c] == 0)):
			cleared.append(i)
			d_next[i] = -1
			d_prog[i] = 0.0
			continue
		var hostile := false
		for k in range(start[t], start[t + 1]):
			var e := d_owner[list[k]]
			if o >= 0 and e >= 0 and e != o and war[o * nc + e] == 1:
				hostile = true
				break
		if hostile:
			attackers.append(i)
			continue
		movers.append(i)
		var speed: float = d_spd[i] * p_move_mult[t]
		var org_factor := 0.5 + 0.5 * clampf(d_org[i] / maxf(1.0, d_morg[i]), 0.0, 1.0)
		d_prog[i] = d_prog[i] + speed * org_factor * (0.5 + 0.5 * d_sup[i])
	return [cleared, attackers, movers]


## Снимок для ИИ (dv_*, CSR pd_start/pd_list) прямо из массивов дивизий.
func k_snapshot() -> void:
	dv_id = d_id
	dv_owner = d_owner
	dv_prov = d_prov
	if Native.core != null:
		var r: Array = Native.core.call("snapshot", d_next, d_battle, d_transit, d_resv, d_inv, d_str, d_org, d_morg,
				d_atk, d_eq, d_sup, d_prov, prov_count, day)
		dv_flags = r[0]
		dv_str = r[1]
		dv_org = r[2]
		dv_power = r[3]
		dv_defw = r[4]
		pd_start = r[5]
		pd_list = r[6]
		return
	var n := d_id.size()
	dv_flags.resize(n)
	dv_str.resize(n)
	dv_org.resize(n)
	dv_power.resize(n)
	dv_defw.resize(n)
	var counts := PackedInt32Array()
	counts.resize(prov_count + 1)
	for i in n:
		var f := 0
		if d_next[i] < 0 and d_battle[i] == 0 and d_transit[i] <= 0 and d_resv[i] < day and d_inv[i] < 0:
			f |= 1
		if d_battle[i] != 0:
			f |= 2
		if d_transit[i] > 0:
			f |= 4
		dv_flags[i] = f
		var st := d_str[i]
		dv_str[i] = st
		var orgf := clampf(d_org[i] / maxf(1.0, d_morg[i]), 0.0, 1.0)
		dv_org[i] = orgf
		dv_power[i] = st * (d_atk[i] / 10.0) * (0.4 + 0.6 * d_eq[i]) * (0.5 + 0.5 * d_sup[i])
		dv_defw[i] = st * orgf * (0.4 + 0.6 * d_eq[i])
		if d_transit[i] <= 0:
			counts[d_prov[i] + 1] += 1
	pd_start.resize(prov_count + 1)
	pd_start[0] = 0
	for p in prov_count:
		pd_start[p + 1] = pd_start[p] + counts[p + 1]
	pd_list.resize(pd_start[prov_count])
	var fill := pd_start.duplicate()
	for i in n:
		if dv_flags[i] & 4 == 0:
			var p := d_prov[i]
			pd_list[fill[p]] = i
			fill[p] += 1


## Бои: provs — провинции сражений по порядку, att_start/att_list — атакующие
## (слоты) каждой; seeds — зерно ГСЧ сражения. Сначала потери считаются по
## состоянию до боя, потом применяются по порядку провинций.
func k_combat(provs: PackedInt32Array, att_start: PackedInt32Array, att_list: PackedInt32Array, seeds: PackedInt64Array,
		plan_max: float = 0.0) -> void:
	# атака с учётом планирования — только у наступающих
	var atk := d_atk
	if plan_max > 0.0 and d_plan.size() == d_atk.size():
		atk = d_atk.duplicate()
		for i in att_list:
			atk[i] = d_atk[i] * (1.0 + plan_max * d_plan[i])
	if Native.core != null:
		var r: Array = Native.core.call("combat", provs, att_start, att_list, seeds, d_str, d_org, d_eq, d_def, atk,
				d_ent, d_land, d_sup, d_tpl, d_hard, d_owner, d_battle, pl_head, d_nx, war, nation_count, p_def_mult,
				p_terrain, p_region, cas_mult, tpl_terrain)
		d_org = r[0]
		d_str = r[1]
		d_eq = r[2]
		d_battle = r[3]
		return
	var nc := nation_count
	var all_deltas: Array = []
	for b in provs.size():
		var p := provs[b]
		var a0 := att_start[b]
		var a1 := att_start[b + 1]
		var att_owner := d_owner[att_list[a0]]
		var defenders := PackedInt32Array()
		var h := pl_head[p]
		while h >= 0:
			var eo := d_owner[h]
			if att_owner >= 0 and eo >= 0 and att_owner != eo and war[att_owner * nc + eo] == 1:
				defenders.append(h)
			h = d_nx[h]
		if defenders.is_empty():
			all_deltas.append(PackedFloat64Array())
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = seeds[b]
		var terrain_def: float = p_def_mult[p]
		var terr: int = p_terrain[p]
		var sa := _side_power(att_list.slice(a0, a1), terr, false, atk)
		var sd := _side_power(defenders, terr, true, atk)
		var reg := p_region[p]
		var att_power: float = sa[0] * cas_mult[reg * nc + att_owner]
		var att_hard: float = sa[1]
		var def_power: float = sd[0] * cas_mult[reg * nc + d_owner[defenders[0]]]
		var def_hard: float = sd[1]
		att_power *= rng.randf_range(0.8, 1.2) * (1.0 - terrain_def * 0.6)
		def_power *= rng.randf_range(0.8, 1.2)
		att_power *= 1.0 - def_hard * 0.6 * (1.0 - att_hard)
		def_power *= 1.0 - att_hard * 0.6 * (1.0 - def_hard)
		var to_def := att_power / defenders.size()
		var to_att := def_power / (a1 - a0)
		var dl := PackedFloat64Array()
		for e in defenders:
			dl.append(e)
			dl.append(to_def * 0.55)
			dl.append(to_def * 0.12)
		for k in range(a0, a1):
			dl.append(att_list[k])
			dl.append(to_att * 0.5)
			dl.append(to_att * 0.10)
		all_deltas.append(dl)
	for dl: PackedFloat64Array in all_deltas:
		for j in range(0, dl.size(), 3):
			var i := int(dl[j])
			d_battle[i] = 1
			d_org[i] = maxf(0.0, d_org[i] - dl[j + 1])
			d_str[i] = maxf(0.0, d_str[i] - dl[j + 2])
			d_eq[i] = maxf(0.0, d_eq[i] - dl[j + 2] / 100.0 * 0.9)   # потери техники


## Сила стороны (как Military.side_power, по массивам): [сила, бронированность].
func _side_power(slots: PackedInt32Array, terr: int, defending: bool, atk: PackedFloat64Array) -> PackedFloat64Array:
	var power := 0.0
	var hard := 0.0
	var wsum := 0.0
	for i in slots:
		var w: float = d_str[i] / 100.0
		var base: float = d_def[i] * (1.0 + 0.3 * d_ent[i]) if defending else atk[i] * (0.5 if d_land[i] == 1 else 1.0)
		power += base * w * (0.4 + 0.6 * d_eq[i]) * (0.5 + 0.5 * d_sup[i]) * tpl_terrain[d_tpl[i] * 8 + terr]
		hard += d_hard[i] * w
		wsum += w
	return PackedFloat64Array([power, hard / maxf(wsum, 0.01)])


## Планирование наступления (как в жанре): дивизия, стоящая на фронте (сосед —
## противник или будущий противник: hostile N×N), копит план на gain в день до 1;
## идущая, атакующая, в пути — теряет active в день; стоящая в тылу — rear.
## C++ — MeowqCore.plan_update, результаты совпадают.
func k_plan(hostile: PackedByteArray, gain: float, active: float, rear: float) -> void:
	if d_plan.size() != d_alive.size():
		d_plan.resize(d_alive.size())
	if Native.core != null:
		d_plan = Native.core.call("plan_update", d_alive, d_transit, d_next, d_battle, d_prov, d_owner, p_controller,
				adj_start, adj_list, p_land, hostile, nation_count, d_plan, gain, active, rear)
		return
	var nc := nation_count
	var ctrl := p_controller
	for i in d_alive.size():
		if d_alive[i] == 0:
			continue
		var v := d_plan[i]
		if d_next[i] >= 0 or d_transit[i] > 0 or d_battle[i] != 0:
			v = maxf(0.0, v - active)
		else:
			var p := d_prov[i]
			var o := d_owner[i]
			var front := false
			for k in range(adj_start[p], adj_start[p + 1]):
				var q := adj_list[k]
				var c := ctrl[q]
				if p_land[q] == 1 and c >= 0 and hostile[o * nc + c] == 1:
					front = true
					break
			v = minf(1.0, v + gain) if front else maxf(0.0, v - rear)
		d_plan[i] = v


## Пересчитать бонусы национальных черт страны (после добавления, снятия, ослабления).
func recalc_spirits(nat: Nation) -> void:
	nat.spirit_bonus = {}
	for id in nat.spirits:
		var k: float = nat.spirits[id]
		var bon: Dictionary = spirit_defs.get(id, {}).get("bonus", {})
		for key in bon:
			nat.spirit_bonus[key] = float(nat.spirit_bonus.get(key, 0.0)) + float(bon[key]) * k
	# экономический курс — как черта
	var law: Dictionary = Economy.LAWS[clampi(nat.trade_law, 0, Economy.LAWS.size() - 1)]["bonus"]
	for key in law:
		nat.spirit_bonus[key] = float(nat.spirit_bonus.get(key, 0.0)) + float(law[key])
	nat.stats_dirty = true
