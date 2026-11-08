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


## Путь к ближайшей провинции из goal (Dictionary province -> true).
static func nearest_goal(world: World, nation: int, from: int, goal: Dictionary) -> PackedInt32Array:
	if goal.has(from):
		return PackedInt32Array()
	return _bfs(world, nation, from, goal)


static func _bfs(world: World, nation: int, from: int, goal: Dictionary) -> PackedInt32Array:
	var native: Object = Native.core
	if native != null:
		return native.call("path_bfs", world.adj_start, world.adj_list, world.p_land, world.p_controller,
				world.war, world.nation_count, nation, from, PackedInt32Array(goal.keys()))
	var land := world.p_land
	var ctrl := world.p_controller
	var war := world.war
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
