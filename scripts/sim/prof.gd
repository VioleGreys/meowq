class_name Prof
extends RefCounted
## Лёгкий профилировщик участков кода (только главный поток): Prof.on = true,
## затем t0 := Time.get_ticks_usec() ... Prof.add("метка", t0); итог — Prof.acc.

static var on := false
static var acc := {}


static func add(label: String, t0: int) -> void:
	if on:
		acc[label] = int(acc.get(label, 0)) + Time.get_ticks_usec() - t0
