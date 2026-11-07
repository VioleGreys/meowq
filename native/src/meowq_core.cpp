#include "meowq_core.h"

#include <godot_cpp/core/class_db.hpp>
#include <vector>

using namespace godot;

void MeowqCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("supply_bfs", "adj_start", "adj_list", "land", "ctrl", "ally", "nation_count", "side", "hubs"), &MeowqCore::supply_bfs);
	ClassDB::bind_method(D_METHOD("land_dist", "adj_start", "adj_list", "land", "from"), &MeowqCore::land_dist);
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
