// Нативное ядро симуляции «Фронты» (GDExtension, godot-cpp 4.3).
// Горячие циклы, которые в GDScript дороги: поиск в ширину по графу провинций.
// Методы не меняют состояние объекта — их можно вызывать из нескольких потоков.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>

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

	PackedFloat64Array gather_f64(const PackedFloat64Array &a, const PackedInt32Array &idx) const;
	PackedInt32Array gather_i32(const PackedInt32Array &a, const PackedInt32Array &idx) const;
	PackedByteArray gather_u8(const PackedByteArray &a, const PackedInt32Array &idx) const;

	// --- ядра горячих фаз дня (см. World.k_* — тот же алгоритм на GDScript) ---
	Array recovery(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedFloat64Array &sup,
			const PackedFloat64Array &org, const PackedFloat64Array &morg, const PackedFloat64Array &str,
			const PackedFloat64Array &eq, const PackedFloat64Array &ent, const PackedInt32Array &next,
			const PackedByteArray &battle, const PackedInt32Array &owner, const PackedInt32Array &prov,
			const PackedInt32Array &tpl, const PackedInt32Array &ctrl, const PackedByteArray &ally, int nc,
			const PackedFloat32Array &stock, const PackedFloat64Array &manpower, const PackedFloat64Array &rbonus,
			const PackedFloat64Array &tpl_eq, const PackedFloat64Array &tpl_men, const PackedInt32Array &pool,
			const PackedFloat64Array &tpl_sc) const;
	PackedFloat64Array supply_apply(const PackedByteArray &alive, const PackedFloat64Array &sup_in, const PackedInt32Array &prov, const PackedInt32Array &tpl,
			const PackedInt32Array &owner, const PackedInt32Array &side_of, const PackedInt32Array &dist,
			const PackedFloat32Array &caps, int prov_count, int t_mot) const;
	Array march(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedInt32Array &next,
			const PackedInt32Array &owner, const PackedInt32Array &prov, const PackedFloat64Array &prog,
			const PackedFloat64Array &spd, const PackedFloat64Array &org, const PackedFloat64Array &morg,
			const PackedFloat64Array &sup, const PackedByteArray &land, const PackedInt32Array &ctrl,
			const PackedByteArray &war, int nc, const PackedFloat32Array &move_mult) const;
	Array snapshot(const PackedInt32Array &next, const PackedByteArray &battle, const PackedInt32Array &transit,
			const PackedInt32Array &resv, const PackedInt32Array &inv, const PackedFloat64Array &str,
			const PackedFloat64Array &org, const PackedFloat64Array &morg, const PackedFloat64Array &atk,
			const PackedFloat64Array &eq, const PackedFloat64Array &sup, const PackedInt32Array &prov,
			int prov_count, int day, const PackedFloat64Array &def, const PackedFloat64Array &ent,
			const PackedFloat64Array &plan, double plan_max) const;

	// военный план ИИ (AIPlanner.plan_military), native/src/ai.cpp
	Dictionary plan_military(const Dictionary &tables, int nid, const PackedInt32Array &divs, int mode, int enemy,
			int objective, const PackedInt32Array &allowed_list, double ratio, int capital,
			const PackedInt32Array &nat_enemies, const Ref<RandomNumberGenerator> &rng) const;

	// стопки фишек для отрисовки (UnitLayer.rebuild): по провинциям, страны в
	// порядке первого появления в списке провинции
	Array counters(const PackedInt32Array &head, const PackedInt32Array &nx, const PackedByteArray &alive,
			const PackedInt32Array &owner, const PackedFloat64Array &str, const PackedFloat64Array &org,
			const PackedFloat64Array &morg, const PackedFloat64Array &sup, const PackedInt32Array &tpl) const;

	// подписи стран (UnitLayer._rebuild_labels): для каждой страны — связный кусок
	// её территории (лучше со столицей, иначе самый большой): по 8 чисел
	// [пиксели, сумма x, сумма y, мин x, мин y, макс x, макс y, есть] на страну
	PackedFloat64Array label_regions(const PackedInt32Array &ctrl, const PackedByteArray &land,
			const PackedInt32Array &adj_start, const PackedInt32Array &adj_list, const PackedInt32Array &pixels,
			const PackedVector2Array &centers, const PackedInt32Array &caps) const;

	Array relink(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedInt32Array &prov,
			const PackedInt32Array &owner, int prov_count, int nation_count) const;

	PackedInt32Array sea_bfs(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
			const PackedByteArray &land, int from) const;
	PackedInt32Array sea_path(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
			const PackedByteArray &land, int from, int to) const;
	Array own_reach(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
			const PackedByteArray &land, const PackedInt32Array &ctrl, int n, int start, int nation_count) const;

	int place_factory(const PackedInt32Array &owner, const PackedInt32Array &ctrl, const PackedInt32Array &civ,
			const PackedInt32Array &mil, const PackedInt32Array &pop, const PackedByteArray &terrain, int nid,
			int max_factories, int t_urban) const;

	Array combat(const PackedInt32Array &provs, const PackedInt32Array &att_start, const PackedInt32Array &att_list,
			const PackedInt64Array &seeds, const PackedFloat64Array &str, const PackedFloat64Array &org,
			const PackedFloat64Array &eq, const PackedFloat64Array &def, const PackedFloat64Array &atk,
			const PackedFloat64Array &ent, const PackedByteArray &landing, const PackedFloat64Array &sup,
			const PackedInt32Array &tpl, const PackedFloat64Array &hard, const PackedInt32Array &owner,
			const PackedByteArray &battle, const PackedInt32Array &pl_head, const PackedInt32Array &d_nx,
			const PackedByteArray &war, int nc, const PackedFloat32Array &def_mult, const PackedByteArray &terrain,
			const PackedInt32Array &region, const PackedFloat32Array &cas, const PackedFloat32Array &tmul,
			const PackedInt32Array &prov, const PackedFloat32Array &tpl_width, const PackedFloat32Array &fw,
			const PackedFloat64Array &armor, const PackedFloat64Array &pierce, double armor_cut,
			const PackedFloat64Array &tpl_sc) const;

	PackedInt32Array income(const PackedInt32Array &ctrl, const PackedInt32Array &owner, const PackedInt32Array &civ,
			const PackedInt32Array &mil, const PackedInt32Array &manpower, int nc) const;

	PackedInt32Array front_regions(const PackedInt32Array &ctrl, const PackedInt32Array &adj_start,
			const PackedInt32Array &adj_list, const PackedByteArray &war, int nc, const PackedInt32Array &region, int n) const;
	PackedByteArray ports_open(const PackedInt32Array &ports, const PackedInt32Array &adj_start,
			const PackedInt32Array &adj_list, const PackedByteArray &land, const PackedByteArray &zone_has_fleet) const;

	PackedByteArray air_reach(const PackedByteArray &land, const PackedInt32Array &ctrl, const PackedByteArray &ally,
			int nc, int n, const PackedInt32Array &region, const PackedVector2Array &centers, double range) const;

	// Снабжение по принципу жанра (Supply): поле подачи узлов и раздача по дивизиям.
	Array supply_field(const Dictionary &t) const;
	Array supply_divs(const Dictionary &t) const;
	Array climate(const Dictionary &t) const;
	// Планирование наступления (World.k_plan).
	PackedFloat64Array plan_update(const PackedByteArray &alive, const PackedInt32Array &transit,
			const PackedInt32Array &next, const PackedByteArray &battle, const PackedInt32Array &prov,
			const PackedInt32Array &owner, const PackedInt32Array &ctrl, const PackedInt32Array &adj_start,
			const PackedInt32Array &adj_list, const PackedByteArray &land, const PackedByteArray &hostile, int nc,
			const PackedFloat64Array &plan_in, double gain, double active, double rear) const;
	String version() const { return "meowq-core 43"; }
	// Воздушный бой района i снимка t (Forces.air_begin): пачки по 100, обнаружение,
	// день и ночь, превосходство; двойник — Forces.air_region_gd.
	PackedFloat64Array air_region(const Dictionary &t, int i) const;
	// Итоги проверки капитуляций (Simulation._check_capitulation): по странам
	// [очки всего ×nc, очки удержанные ×nc, своих неоккупированных провинций ×nc];
	// side — [корень стороны, фракция корня] на страну.
	// Узлы снабжения из портов (Simulation._phase_supply): 1 — порт работает
	// (есть море без флотов или не блокирован: господство стороны ≥ 0,3 хоть в
	// одной соседней зоне), 0 — блокирован. Флоты зон — zidx/zoff/zown/zpow
	// (без стоящих в порту), двойник — Simulation._blockaded.
	PackedByteArray ports_hub(const PackedInt32Array &ports, const PackedInt32Array &ctrl,
			const PackedInt32Array &adj_start, const PackedInt32Array &adj_list, const PackedByteArray &land,
			const PackedByteArray &zone_has_fleet, const PackedInt32Array &zidx, const PackedInt32Array &zoff,
			const PackedInt32Array &zown, const PackedFloat64Array &zpow, const PackedByteArray &ally,
			const PackedByteArray &war, int nc, bool any_fleets) const;
	PackedInt32Array cap_totals(const PackedInt32Array &owner, const PackedInt32Array &ctrl,
			const PackedInt32Array &vp, const PackedInt32Array &side, int nc) const;
};

} // namespace godot
