class_name Tech
extends RefCounted

const LIST := [
	{"id": "inf1", "name": "Стрелковое оружие I", "cost": 60.0, "req": "", "bonus": {"attack": 0.10}, "desc": "+10% атака"},
	{"id": "inf2", "name": "Стрелковое оружие II", "cost": 120.0, "req": "inf1", "bonus": {"attack": 0.15}, "desc": "+15% атака"},
	{"id": "art1", "name": "Полевая артиллерия", "cost": 160.0, "req": "inf2", "bonus": {"attack": 0.20}, "desc": "+20% атака"},
	{"id": "def1", "name": "Полевые укрепления", "cost": 70.0, "req": "", "bonus": {"defense": 0.15}, "desc": "+15% защита"},
	{"id": "def2", "name": "Глубокая оборона", "cost": 130.0, "req": "def1", "bonus": {"defense": 0.20}, "desc": "+20% защита"},
	{"id": "org1", "name": "Штабная доктрина", "cost": 90.0, "req": "", "bonus": {"org": 0.20}, "desc": "+20% организация"},
	{"id": "org2", "name": "Радиосвязь", "cost": 150.0, "req": "org1", "bonus": {"org": 0.20, "attack": 0.05}, "desc": "+20% орг., +5% атака"},
	{"id": "mot1", "name": "Моторизация", "cost": 110.0, "req": "", "bonus": {"speed": 0.15}, "desc": "открывает моторизованные дивизии, +15% скорость"},
	{"id": "mot2", "name": "Механизированные части", "cost": 180.0, "req": "mot1", "bonus": {"speed": 0.2, "attack": 0.05}, "desc": "+20% скорость, +5% атака"},
	{"id": "mnt1", "name": "Горные части", "cost": 70.0, "req": "", "bonus": {}, "desc": "открывает горнострелковые дивизии"},
	{"id": "armor1", "name": "Танковые дивизии", "cost": 130.0, "req": "mot1", "bonus": {}, "desc": "открывает танковые дивизии"},
	{"id": "armor2", "name": "Средние танки", "cost": 200.0, "req": "armor1", "bonus": {"attack": 0.1, "speed": 0.1}, "desc": "+10% атака, +10% скорость"},
	{"id": "ind1", "name": "Конвейер", "cost": 80.0, "req": "", "bonus": {"industry": 0.15}, "desc": "+15% выпуск снаряжения"},
	{"id": "ind2", "name": "Поточное производство", "cost": 150.0, "req": "ind1", "bonus": {"industry": 0.20}, "desc": "+20% выпуск снаряжения"},
	{"id": "con1", "name": "Строительная техника", "cost": 70.0, "req": "", "bonus": {"construction": 0.25}, "desc": "+25% скорость стройки"},
	{"id": "con2", "name": "Сборные конструкции", "cost": 140.0, "req": "con1", "bonus": {"construction": 0.25}, "desc": "+25% скорость стройки"},
	{"id": "res1", "name": "Научные институты", "cost": 60.0, "req": "", "bonus": {"research": 0.20}, "desc": "+20% скорость науки"},
	{"id": "rec1", "name": "Всеобщая мобилизация", "cost": 70.0, "req": "", "bonus": {"manpower": 0.40}, "desc": "+40% прирост призывников"},
	{"id": "med1", "name": "Полевая медицина", "cost": 80.0, "req": "", "bonus": {"reinforce": 0.50}, "desc": "+50% пополнение"},
]


static func get_tech(id: String) -> Dictionary:
	for t in LIST:
		if t["id"] == id:
			return t
	return {}


static func available(nation) -> Array:
	var res: Array = []
	for t in LIST:
		if nation.techs.has(t["id"]):
			continue
		if t["req"] != "" and not nation.techs.has(t["req"]):
			continue
		res.append(t)
	return res


static func complete(nation, id: String) -> void:
	var t := get_tech(id)
	if t.is_empty():
		return
	nation.techs[id] = true
	nation.stats_dirty = true
	for k in t["bonus"]:
		nation.bonus[k] = float(nation.bonus.get(k, 0.0)) + float(t["bonus"][k])
