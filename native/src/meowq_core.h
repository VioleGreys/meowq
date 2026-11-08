// Нативное ядро симуляции «Фронты» (GDExtension, godot-cpp 4.3).
// Горячие циклы, которые в GDScript дороги: поиск в ширину по графу провинций.
// Методы не меняют состояние объекта — их можно вызывать из нескольких потоков.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot {

class MeowqCore : public RefCounted {
	GDCLASS(MeowqCore, RefCounted)

protected:
	static void _bind_methods();

public:
	// Сеть снабжения стороны side: расстояние (в провинциях) от узлов hubs по
	// суше через провинции союзников; -1 — вне сети.
	PackedInt32Array supply_bfs(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
			const PackedByteArray &land, const PackedInt32Array &ctrl, const PackedByteArray &ally,
			int nation_count, int side, const PackedInt32Array &hubs) const;

	// Расстояние по суше от провинции from до всех (без учёта владельца).
	PackedInt32Array land_dist(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
			const PackedByteArray &land, int from) const;

	// Путь в ширину для дивизии страны nation: по своим провинциям и провинциям
	// противника (war[nation*nc+c]==1) до ближайшей из goals. Путь без from.
	PackedInt32Array path_bfs(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
			const PackedByteArray &land, const PackedInt32Array &ctrl, const PackedByteArray &war,
			int nation_count, int nation, int from, const PackedInt32Array &goals) const;

	String version() const { return "meowq-core 2"; }
};

} // namespace godot
