extends SceneTree
## Пункты снабжения на старте 1936 г. — для сети железных дорог карты
## (tools/build_roads.py --supply): узлы районов (Supply.hubs_static), столицы стран
## и колоний (Depots._colcap). Пишет JSON {"hubs": [...], "caps": [...]}.
##   godot --headless --path . --script res://tools/dump_supply.gd -- --out=ФАЙЛ


func _init() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var w := World.new()
	MapLoader.load_world(w)
	Supply.hubs_static(w)
	var hubs: Array = []
	for h in w.r_hub:
		if h >= 0:
			hubs.append(h)
	var caps: Array = []
	for n in w.nations:
		if n.capital >= 0:
			caps.append(n.capital)
	var cc := Depots._colcap(w)
	for p in w.prov_count:
		if cc[p] == 1:
			caps.append(p)
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify({"hubs": hubs, "caps": caps}))
	f.close()
	print("узлов снабжения %d, столиц %d" % [hubs.size(), caps.size()])
	quit()
