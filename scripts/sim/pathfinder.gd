class_name Pathfinder
extends RefCounted
## Поиск пути в ширину по графу провинций. Только чтение мира и локальные
## массивы — можно вызывать одновременно из многих потоков. Все массивы мира
## один раз выносятся в локальные переменные (см. комментарий в World).


## Путь от from до to (без from, с to). Пустой массив — пути нет.
static func find_path(world: World, nation: int, from: int, to: int) -> PackedInt32Array:
	if from == to or not world.can_enter(nation, to):
		return PackedInt32Array()
	return _bfs(world, nation, from, {to: true})


## Пути к to сразу из многих провинций (приказ выделенным войскам): один
## обратный поиск в ширину от цели вместо поиска для каждой дивизии.
## Возвращает источник → путь (без источника, с to); нет пути — нет ключа.
static func paths_to(world: World, nation: int, to: int, sources: PackedInt32Array) -> Dictionary:
	var res := {}
	if not world.can_enter(nation, to):
		return res
	var land := world.p_land
	var ctrl := world.p_controller
	var war := world.pass_table()   # можно войти: своя, вражеская, союзная
	var nc := world.nation_count
	var a_start := world.adj_start
	var a_list := world.adj_list
	var next := PackedInt32Array()   # следующий шаг к цели
	next.resize(world.prov_count)
	next.fill(-1)
	next[to] = to
	var queue := PackedInt32Array([to])
	var head := 0
	while head < queue.size():
		var q := queue[head]
		head += 1
		for k in range(a_start[q], a_start[q + 1]):
			var p := a_list[k]
			if next[p] >= 0 or land[p] == 0:
				continue
			next[p] = q   # из p можно шагнуть в q (q — проходима)
			var c := ctrl[p]
			if c == nation or (c >= 0 and war[nation * nc + c] == 1):
				queue.append(p)   # через p можно идти дальше
	for src in sources:
		if src == to or next[src] < 0 or res.has(src):
			continue
		var path := PackedInt32Array()
		var cur := next[src]
		while true:
			path.append(cur)
			if cur == to:
				break
			cur = next[cur]
		res[src] = path
	return res


## Путь к ближайшей провинции из goal (Dictionary province -> true).
static func nearest_goal(world: World, nation: int, from: int, goal: Dictionary) -> PackedInt32Array:
	if goal.has(from):
		return PackedInt32Array()
	return _bfs(world, nation, from, goal)


static func _bfs(world: World, nation: int, from: int, goal: Dictionary) -> PackedInt32Array:
	var native: Object = Native.core
	if native != null:
		return native.call("path_bfs", world.adj_start, world.adj_list, world.p_land, world.p_controller,
				world.pass_table(), world.nation_count, nation, from, PackedInt32Array(goal.keys()))
	var land := world.p_land
	var ctrl := world.p_controller
	var war := world.pass_table()
	var nc := world.nation_count
	var a_start := world.adj_start
	var a_list := world.adj_list
	var parent := PackedInt32Array()
	parent.resize(world.prov_count)
	parent.fill(-1)
	parent[from] = from
	var queue := PackedInt32Array([from])
	var head := 0
	var found := -1
	while head < queue.size():
		var p := queue[head]
		head += 1
		if goal.has(p):
			found = p
			break
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if parent[q] >= 0 or land[q] == 0:
				continue
			var c := ctrl[q]
			if c != nation and (c < 0 or war[nation * nc + c] == 0):
				continue
			parent[q] = p
			queue.append(q)
	if found < 0:
		return PackedInt32Array()
	var path := PackedInt32Array()
	var cur := found
	while cur != from:
		path.append(cur)
		cur = parent[cur]
	path.reverse()
	return path
