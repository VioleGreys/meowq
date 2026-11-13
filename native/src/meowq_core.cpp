#include "meowq_core.h"

#include <godot_cpp/core/class_db.hpp>
#include <vector>

using namespace godot;

void MeowqCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("supply_bfs", "adj_start", "adj_list", "land", "ctrl", "ally", "nation_count", "side", "hubs"), &MeowqCore::supply_bfs);
	ClassDB::bind_method(D_METHOD("supply_field", "t"), &MeowqCore::supply_field);
	ClassDB::bind_method(D_METHOD("plan_update", "alive", "transit", "next", "battle", "prov", "owner", "ctrl", "adj_start", "adj_list", "land", "hostile", "nc", "plan", "gain", "active", "rear"), &MeowqCore::plan_update);
	ClassDB::bind_method(D_METHOD("climate", "t"), &MeowqCore::climate);
	ClassDB::bind_method(D_METHOD("supply_divs", "t"), &MeowqCore::supply_divs);
	ClassDB::bind_method(D_METHOD("land_dist", "adj_start", "adj_list", "land", "from"), &MeowqCore::land_dist);
	ClassDB::bind_method(D_METHOD("path_bfs", "adj_start", "adj_list", "land", "ctrl", "war", "nation_count", "nation", "from", "goals"), &MeowqCore::path_bfs);
	ClassDB::bind_method(D_METHOD("gather_f64", "a", "idx"), &MeowqCore::gather_f64);
	ClassDB::bind_method(D_METHOD("gather_i32", "a", "idx"), &MeowqCore::gather_i32);
	ClassDB::bind_method(D_METHOD("gather_u8", "a", "idx"), &MeowqCore::gather_u8);
	ClassDB::bind_method(D_METHOD("recovery", "alive", "transit", "sup", "org", "morg", "str", "eq", "ent", "next", "battle", "owner", "prov", "tpl", "ctrl", "ally", "nc", "stock", "manpower", "rbonus", "tpl_eq", "tpl_men", "pool", "tpl_sc"), &MeowqCore::recovery);
	ClassDB::bind_method(D_METHOD("supply_apply", "alive", "sup", "prov", "tpl", "owner", "side_of", "dist", "caps", "prov_count", "t_mot"), &MeowqCore::supply_apply);
	ClassDB::bind_method(D_METHOD("march", "alive", "transit", "next", "owner", "prov", "prog", "spd", "org", "morg", "sup", "land", "ctrl", "war", "nc", "move_mult"), &MeowqCore::march);
	ClassDB::bind_method(D_METHOD("snapshot", "next", "battle", "transit", "resv", "inv", "str", "org", "morg", "atk", "eq", "sup", "prov", "prov_count", "day", "def", "ent", "plan", "plan_max"), &MeowqCore::snapshot);
	ClassDB::bind_method(D_METHOD("plan_military", "tables", "nid", "divs", "mode", "enemy", "objective", "allowed", "ratio", "capital", "enemies", "rng"), &MeowqCore::plan_military);
	ClassDB::bind_method(D_METHOD("counters", "head", "nx", "alive", "owner", "str", "org", "morg", "sup", "tpl"), &MeowqCore::counters);
	ClassDB::bind_method(D_METHOD("label_regions", "ctrl", "land", "adj_start", "adj_list", "pixels", "centers", "caps"), &MeowqCore::label_regions);
	ClassDB::bind_method(D_METHOD("relink", "alive", "transit", "prov", "owner", "prov_count", "nation_count"), &MeowqCore::relink);
	ClassDB::bind_method(D_METHOD("sea_bfs", "adj_start", "adj_list", "land", "from"), &MeowqCore::sea_bfs);
	ClassDB::bind_method(D_METHOD("sea_path", "adj_start", "adj_list", "land", "from", "to"), &MeowqCore::sea_path);
	ClassDB::bind_method(D_METHOD("own_reach", "adj_start", "adj_list", "land", "ctrl", "n", "start", "nation_count"), &MeowqCore::own_reach);
	ClassDB::bind_method(D_METHOD("place_factory", "owner", "ctrl", "civ", "mil", "pop", "terrain", "nid", "max_factories", "t_urban"), &MeowqCore::place_factory);
	ClassDB::bind_method(D_METHOD("combat", "provs", "att_start", "att_list", "seeds", "str", "org", "eq", "def", "atk", "ent", "landing", "sup", "tpl", "hard", "owner", "battle", "pl_head", "d_nx", "war", "nc", "def_mult", "terrain", "region", "cas", "tmul", "prov", "tpl_width", "fw", "armor", "pierce", "armor_cut", "tpl_sc", "coord"), &MeowqCore::combat);
	ClassDB::bind_method(D_METHOD("income", "ctrl", "owner", "civ", "mil", "manpower", "nc"), &MeowqCore::income);
	ClassDB::bind_method(D_METHOD("front_regions", "ctrl", "adj_start", "adj_list", "war", "nc", "region", "n"), &MeowqCore::front_regions);
	ClassDB::bind_method(D_METHOD("ports_open", "ports", "adj_start", "adj_list", "land", "zone_has_fleet"), &MeowqCore::ports_open);
	ClassDB::bind_method(D_METHOD("air_reach", "land", "ctrl", "ally", "nc", "n", "region", "centers", "range"), &MeowqCore::air_reach);
	ClassDB::bind_method(D_METHOD("air_region", "t", "i"), &MeowqCore::air_region);
	ClassDB::bind_method(D_METHOD("ports_hub", "ports", "ctrl", "adj_start", "adj_list", "land", "zone_has_fleet",
			"zidx", "zoff", "zown", "zpow", "ally", "war", "nc", "any_fleets"), &MeowqCore::ports_hub);
	ClassDB::bind_method(D_METHOD("cap_totals", "owner", "ctrl", "vp", "side", "nc"), &MeowqCore::cap_totals);
	ClassDB::bind_method(D_METHOD("version"), &MeowqCore::version);
}

PackedInt32Array MeowqCore::supply_bfs(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &land, const PackedInt32Array &ctrl, const PackedByteArray &ally,
		int nation_count, int side, const PackedInt32Array &hubs) const {
	const int n = int(land.size());
	PackedInt32Array out;
	out.resize(n);
	int32_t *dist = out.ptrw();
	for (int i = 0; i < n; i++) dist[i] = -1;
	const int32_t *as = adj_start.ptr();
	const int32_t *al = adj_list.ptr();
	const uint8_t *ld = land.ptr();
	const int32_t *ct = ctrl.ptr();
	const uint8_t *al_row = ally.ptr() + int64_t(side) * nation_count;
	std::vector<int32_t> queue;
	queue.reserve(n);
	// порядок обхода совпадает с GDScript-версией — результат одинаковый
	for (int64_t i = 0; i < hubs.size(); i++) {
		int32_t h = hubs[i];
		dist[h] = 0;
		queue.push_back(h);
	}
	for (size_t head = 0; head < queue.size(); head++) {
		const int32_t p = queue[head];
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (dist[q] >= 0 || ld[q] == 0) continue;
			const int32_t c = ct[q];
			if (c < 0 || al_row[c] == 0) continue;
			dist[q] = dist[p] + 1;
			queue.push_back(q);
		}
	}
	return out;
}

PackedInt32Array MeowqCore::land_dist(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &land, int from) const {
	const int n = int(land.size());
	PackedInt32Array out;
	out.resize(n);
	int32_t *dist = out.ptrw();
	for (int i = 0; i < n; i++) dist[i] = 1 << 20;
	if (from < 0 || from >= n) return out;
	const int32_t *as = adj_start.ptr();
	const int32_t *al = adj_list.ptr();
	const uint8_t *ld = land.ptr();
	std::vector<int32_t> queue;
	queue.reserve(n);
	dist[from] = 0;
	queue.push_back(from);
	for (size_t head = 0; head < queue.size(); head++) {
		const int32_t p = queue[head];
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] == 1 && dist[q] > dist[p] + 1) {
				dist[q] = dist[p] + 1;
				queue.push_back(q);
			}
		}
	}
	return out;
}

PackedInt32Array MeowqCore::path_bfs(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &land, const PackedInt32Array &ctrl, const PackedByteArray &war,
		int nation_count, int nation, int from, const PackedInt32Array &goals) const {
	PackedInt32Array path;
	const int n = int(land.size());
	if (from < 0 || from >= n) return path;
	std::vector<uint8_t> goal(n, 0);
	for (int64_t i = 0; i < goals.size(); i++) {
		int32_t g = goals[i];
		if (g >= 0 && g < n) goal[g] = 1;
	}
	if (goal[from]) return path;
	const int32_t *as = adj_start.ptr();
	const int32_t *al = adj_list.ptr();
	const uint8_t *ld = land.ptr();
	const int32_t *ct = ctrl.ptr();
	const uint8_t *war_row = war.ptr() + int64_t(nation) * nation_count;
	std::vector<int32_t> parent(n, -1);
	std::vector<int32_t> queue;
	queue.reserve(256);
	parent[from] = from;
	queue.push_back(from);
	int32_t found = -1;
	for (size_t head = 0; head < queue.size(); head++) {
		const int32_t p = queue[head];
		if (goal[p]) { found = p; break; }
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (parent[q] >= 0 || ld[q] == 0) continue;
			const int32_t c = ct[q];
			if (c != nation && (c < 0 || war_row[c] == 0)) continue;
			parent[q] = p;
			queue.push_back(q);
		}
	}
	if (found < 0) return path;
	int len = 0;
	for (int32_t cur = found; cur != from; cur = parent[cur]) len++;
	path.resize(len);
	int32_t *w = path.ptrw();
	for (int32_t cur = found; cur != from; cur = parent[cur]) w[--len] = cur;
	return path;
}

template <typename A>
static A gather_impl(const A &a, const PackedInt32Array &idx) {
	A r;
	r.resize(idx.size());
	auto *w = r.ptrw();
	const auto *src = a.ptr();
	const int32_t *ix = idx.ptr();
	for (int64_t j = 0; j < idx.size(); j++) w[j] = src[ix[j]];
	return r;
}

PackedFloat64Array MeowqCore::gather_f64(const PackedFloat64Array &a, const PackedInt32Array &idx) const { return gather_impl(a, idx); }
PackedInt32Array MeowqCore::gather_i32(const PackedInt32Array &a, const PackedInt32Array &idx) const { return gather_impl(a, idx); }
PackedByteArray MeowqCore::gather_u8(const PackedByteArray &a, const PackedInt32Array &idx) const { return gather_impl(a, idx); }
