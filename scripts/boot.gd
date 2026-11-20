extends Node
## Стартовая сцена. Сборка скриптов игры (scenes/main.tscn тянет за собой
## почти все — ~1 с на ПК даже из APK, на телефоне в разы дольше) идёт в
## главном потоке, а рабочие потоки тем временем уже распаковывают картинки
## мира и карты (BootFiles.prefetch_all) — раньше распаковка начиналась только
## после сборки, в начале загрузки мира. Здесь — только маленькие скрипты без
## зависимостей (BootFiles, ImgPrefetch).

func _ready() -> void:
	if not "--procedural" in OS.get_cmdline_user_args():
		BootFiles.prefetch_all()
	var t1 := Time.get_ticks_usec()
	var scene: PackedScene = load("res://scenes/main.tscn")
	# замер запуска (main.gd, -- --boot и отчёт с телефона)
	Engine.set_meta("boot_compile_ms", (Time.get_ticks_usec() - t1) / 1000)
	get_tree().change_scene_to_packed.call_deferred(scene)
