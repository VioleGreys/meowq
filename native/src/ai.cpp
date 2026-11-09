// Версия ядра в meowq_core.cpp повышается при каждом изменении алгоритма.
// Военный план ИИ — перенос AIPlanner.plan_military (scripts/sim/ai.gd) один
// в один: тот же порядок обхода (словари GDScript хранят порядок вставки —
// здесь это вектор + флаги), те же формулы в double, те же вызовы ГСЧ.
#include "meowq_core.h"

#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <algorithm>
#include <climits>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

struct OrderedSet {
	std::vector<int32_t> order;
	std::vector<char> has;
	explicit OrderedSet(int n) : has(n, 0) {}
	void add(int32_t p) {
		if (!has[p]) {
			has[p] = 1;
			order.push_back(p);
		}
	}
	void keep_if(const std::vector<char> &ok) {
		std::vector<int32_t> o;
		for (int32_t p : order) {
			if (ok[p]) o.push_back(p);
			else has[p] = 0;
		}
		order.swap(o);
	}
};

} // namespace

Dictionary MeowqCore::plan_military(const Dictionary &tables, int nid, const PackedInt32Array &divs, int mode, int enemy,
		int objective, const PackedInt32Array &allowed_list, double ratio, int capital,
		const PackedInt32Array &nat_enemies, const Ref<RandomNumberGenerator> &rng) const {
	enum { AUTO = 0, HOLD = 1, ATTACK = 2 };
	const PackedInt32Array ctrl_a = tables["ctrl"], a_start_a = tables["adj_start"], a_list_a = tables["adj_list"];
	const PackedInt32Array vp_a = tables["vp"], owners_a = tables["owner"];
	const PackedByteArray land_a = tables["land"], war_a = tables["war"], ally_a = tables["ally"], coastal_a = tables["coastal"];
	const PackedFloat32Array def_a = tables["def"];
	const PackedInt32Array dv_id_a = tables["dv_id"], dv_owner_a = tables["dv_owner"], dv_prov_a = tables["dv_prov"];
	const PackedInt32Array dv_flags_a = tables["dv_flags"], pd_start_a = tables["pd_start"], pd_list_a = tables["pd_list"];
	const PackedFloat32Array dv_org_a = tables["dv_org"], dv_power_a = tables["dv_power"], dv_defw_a = tables["dv_defw"];
	const int nc = int(tables["nc"]);

	const int32_t *ctrl = ctrl_a.ptr(), *a_start = a_start_a.ptr(), *a_list = a_list_a.ptr(), *vp = vp_a.ptr();
	const int32_t *owners = owners_a.ptr();
	const uint8_t *land = land_a.ptr(), *war = war_a.ptr(), *ally = ally_a.ptr(), *coastal = coastal_a.ptr();
	const float *def_tab = def_a.ptr();
	const int32_t *dv_id = dv_id_a.ptr(), *dv_owner = dv_owner_a.ptr(), *dv_prov = dv_prov_a.ptr();
	const int32_t *dv_flags = dv_flags_a.ptr(), *pd_start = pd_start_a.ptr(), *pd_list = pd_list_a.ptr();
	const float *dv_org = dv_org_a.ptr(), *dv_power = dv_power_a.ptr(), *dv_defw = dv_defw_a.ptr();
	const bool has_ally = ally_a.size() > 0;
	const int pc = int(land_a.size());
	// ёмкость снабжения провинций (Supply): не скапливать войска сверх неё
	const PackedFloat32Array supcap_a = tables.has("supcap") ? PackedFloat32Array(tables["supcap"]) : PackedFloat32Array();
	const bool has_cap = supcap_a.size() == pc;
	const float *supcap = supcap_a.ptr();
	auto capd = [&](int32_t p) { return std::max(1, int(std::floor(double(supcap[p])))); };
	const int64_t ndv = dv_owner_a.size();

	Dictionary result;
	Array orders;
	result["orders"] = orders;

	bool at_war = false;
	for (int64_t k = 0; k < nat_enemies.size(); k++) {
		const int32_t e = nat_enemies[k];
		if (enemy < 0 || e == enemy || (has_ally && ally[int64_t(enemy) * nc + e] == 1)) {
			at_war = true;
			break;
		}
	}
	const bool attack_allowed = at_war && (mode == ATTACK || mode == AUTO);

	// фронт
	OrderedSet fronts(pc), targets(pc);
	PackedInt32Array fpairs;
	for (int p = 0; p < pc; p++) {
		if (ctrl[p] != nid) continue;
		for (int32_t k = a_start[p]; k < a_start[p + 1]; k++) {
			const int32_t q = a_list[k];
			if (land[q] == 0) continue;
			const int32_t c = ctrl[q];
			if (c < 0 || c == nid) continue;
			const bool hostile = war[int64_t(nid) * nc + c] == 1;
			const bool matches = enemy < 0 || c == enemy || (has_ally && ally[int64_t(enemy) * nc + c] == 1);
			if (at_war) {
				if (hostile && matches) {
					fronts.add(p);
					targets.add(q);
					fpairs.push_back(p);
					fpairs.push_back(q);
				}
			} else if (matches && (enemy >= 0 || mode == AUTO) && (!has_ally || ally[int64_t(nid) * nc + c] == 0)) {
				fronts.add(p);
				fpairs.push_back(p);
				fpairs.push_back(q);
			}
		}
	}
	if (allowed_list.size() > 0) {
		std::vector<char> allowed(pc, 0);
		for (int64_t k = 0; k < allowed_list.size(); k++) allowed[allowed_list[k]] = 1;
		fronts.keep_if(allowed);
		std::vector<char> near(pc, 0);
		for (int32_t t : targets.order) {
			for (int32_t k = a_start[t]; k < a_start[t + 1]; k++) {
				if (allowed[a_list[k]]) {
					near[t] = 1;
					break;
				}
			}
		}
		targets.keep_if(near);
		PackedInt32Array fp;
		for (int64_t i = 0; i + 1 < fpairs.size(); i += 2) {
			if (allowed[fpairs[i]]) {
				fp.push_back(fpairs[i]);
				fp.push_back(fpairs[i + 1]);
			}
		}
		fpairs = fp;
	}
	result["fronts"] = fpairs;
	if (fronts.order.empty()) {
		if (mode == AUTO) fronts.add(capital);
		else return result;
	}
	// в войну столица и крупные порты всегда под охраной
	if (mode == AUTO && at_war && ctrl[capital] == nid) {
		fronts.add(capital);
		for (int p = 0; p < pc; p++)
			if (ctrl[p] == nid && coastal[p] == 1 && vp[p] >= 5 && owners[p] == nid) fronts.add(p);
	}

	std::vector<int32_t> idle;
	std::vector<char> in_group(ndv, 0);
	for (int64_t k = 0; k < divs.size(); k++) {
		const int32_t i = divs[k];
		in_group[i] = 1;
		if ((dv_flags[i] & 1) == 1) idle.push_back(i);
	}
	if (idle.empty()) return result;

	// расстояние до цели наступления (по суше)
	std::vector<int32_t> obj_dist;
	if (objective >= 0) {
		obj_dist.assign(pc, 1 << 20);
		obj_dist[objective] = 0;
		std::vector<int32_t> queue{ objective };
		for (size_t head = 0; head < queue.size(); head++) {
			const int32_t p = queue[head];
			for (int32_t k = a_start[p]; k < a_start[p + 1]; k++) {
				const int32_t q = a_list[k];
				if (land[q] == 1 && obj_dist[q] > obj_dist[p] + 1) {
					obj_dist[q] = obj_dist[p] + 1;
					queue.push_back(q);
				}
			}
		}
	}

	std::vector<char> used(ndv, 0);
	if (attack_allowed) {
		struct Entry {
			double score;
			int32_t t;
			double es;
		};
		std::vector<Entry> target_list;
		for (int32_t t : targets.order) {
			double enemy_str = 0.0;
			for (int32_t k = pd_start[t]; k < pd_start[t + 1]; k++) {
				const int32_t e = pd_list[k];
				const int32_t eo = dv_owner[e];
				if (eo != nid && war[int64_t(nid) * nc + eo] == 1) enemy_str += double(dv_defw[e]);
			}
			const double def_mult = 1.0 + double(def_tab[t]);
			double score = enemy_str * def_mult - vp[t] * 6.0 + double(rng->randf()) * 20.0;
			if (objective >= 0) score += obj_dist[t] * 25.0;
			// охват: цель, которую можно атаковать с нескольких наших участков, важнее
			int dirs = 0;
			for (int32_t k = a_start[t]; k < a_start[t + 1]; k++)
				if (fronts.has[a_list[k]]) dirs++;
			if (dirs > 1) score -= double(dirs - 1) * 15.0;
			target_list.push_back({ score, t, enemy_str * def_mult });
		}
		std::sort(target_list.begin(), target_list.end(), [](const Entry &a, const Entry &b) {
			return a.score < b.score || (a.score == b.score && a.t < b.t);
		});
		std::vector<int32_t> left(pc, INT_MIN);   // сколько наших дивизий останется в провинции
		std::vector<int32_t> group, chosen;
		for (const Entry &entry : target_list) {
			const int32_t t = entry.t;
			const double need = entry.es * ratio;
			group.clear();
			for (int32_t k = a_start[t]; k < a_start[t + 1]; k++) {
				const int32_t q = a_list[k];
				for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++) {
					const int32_t i = pd_list[m];
					if (dv_owner[i] == nid && in_group[i] && (dv_flags[i] & 1) == 1 && !used[i] && double(dv_org[i]) > 0.6)
						group.push_back(i);
				}
			}
			if (group.empty()) continue;
			std::sort(group.begin(), group.end(), [dv_power](int32_t a, int32_t b) {
				return dv_power[a] > dv_power[b] || (dv_power[a] == dv_power[b] && a < b);
			});
			chosen.clear();
			double power = 0.0;
			for (int32_t i : group) {
				const int32_t pv = dv_prov[i];
				if (left[pv] == INT_MIN) left[pv] = pd_start[pv + 1] - pd_start[pv];
				if (left[pv] <= 1) continue;   // последняя дивизия участок не бросает
				chosen.push_back(i);
				left[pv] -= 1;
				power += double(dv_power[i]);
				if (power > need && (entry.es <= 0.0 || chosen.size() >= 2)) break;
			}
			if (power > need && !chosen.empty()) {
				for (int32_t i : chosen) {
					used[i] = 1;
					Array o;
					o.push_back(i);
					PackedInt32Array path;
					path.push_back(t);
					o.push_back(path);
					orders.push_back(o);
				}
			} else {
				for (int32_t i : chosen) left[dv_prov[i]] += 1;
			}
		}
	}

	// ротация: измотанные дивизии (организация < 30 %) на передовой отходят на
	// соседнюю тыловую провинцию, если на участке остаётся кто-то из наших
	std::vector<int32_t> rotated;
	if (at_war) {
		std::vector<int32_t> ours_left(pc, INT_MIN);
		for (int32_t i : idle) {
			if (used[i] || double(dv_org[i]) >= 0.3) continue;
			const int32_t pv = dv_prov[i];
			if (!fronts.has[pv]) continue;
			if (ours_left[pv] == INT_MIN) {
				int cnt = 0;
				for (int32_t m = pd_start[pv]; m < pd_start[pv + 1]; m++)
					if (dv_owner[pd_list[m]] == nid) cnt++;
				ours_left[pv] = cnt;
			}
			if (ours_left[pv] <= 1) continue;
			int32_t rear = -1;
			for (int32_t k = a_start[pv]; k < a_start[pv + 1]; k++) {
				const int32_t q = a_list[k];
				if (land[q] == 1 && ctrl[q] == nid && !fronts.has[q]) {
					rear = q;
					break;
				}
			}
			if (rear < 0) continue;
			used[i] = 1;
			ours_left[pv] -= 1;
			rotated.push_back(i);
			Array o;
			o.push_back(i);
			PackedInt32Array path;
			path.push_back(rear);
			o.push_back(path);
			orders.push_back(o);
		}
	}

	// остальные — по фронту, больше туда, где больше противника
	std::vector<int32_t> per_front(pc, 0);
	for (int64_t k = 0; k < divs.size(); k++) {
		const int32_t i = divs[k];
		const int32_t pv = dv_prov[i];
		if ((dv_flags[i] & 4) == 0 && fronts.has[pv]) per_front[pv] += 1;
	}
	for (int32_t i : rotated) per_front[dv_prov[i]] -= 1;
	std::vector<double> weight(pc, 0.0);
	double wsum = 0.0;
	for (int32_t f : fronts.order) {
		double threat = 0.0;
		for (int32_t k = a_start[f]; k < a_start[f + 1]; k++) {
			const int32_t q = a_list[k];
			for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++) {
				const int32_t eo = dv_owner[pd_list[m]];
				if (eo != nid && (!has_ally || ally[int64_t(nid) * nc + eo] == 0))
					threat += (war[int64_t(nid) * nc + eo] == 1 || !at_war) ? 1.0 : 0.3;
			}
		}
		weight[f] = 1.0 + threat + vp[f] * 0.15;
		wsum += weight[f];
	}
	std::vector<int32_t> desired(pc, 0);
	for (int32_t f : fronts.order) {
		desired[f] = std::max(1, int(std::round(divs.size() * weight[f] / wsum)));
		if (has_cap) desired[f] = std::min(desired[f], capd(f));
	}

	// поиск пути к ближайшему участку (как Pathfinder.nearest_goal)
	std::vector<char> goal(pc, 0);
	std::vector<int32_t> parent(pc, -1), queue;
	const uint8_t *war_row = war + int64_t(nid) * nc;
	for (int32_t i : idle) {
		if (used[i]) continue;
		const int32_t pv = dv_prov[i];
		if (fronts.has[pv] && per_front[pv] <= desired[pv] + 1) continue;
		std::vector<int32_t> goals;
		for (int32_t f : fronts.order)
			if (per_front[f] < desired[f] && f != pv) goals.push_back(f);
		if (goals.empty()) continue;
		for (int32_t g : goals) goal[g] = 1;
		std::fill(parent.begin(), parent.end(), -1);
		queue.clear();
		parent[pv] = pv;
		queue.push_back(pv);
		int32_t found = -1;
		for (size_t head = 0; head < queue.size(); head++) {
			const int32_t p = queue[head];
			if (goal[p]) { found = p; break; }
			for (int32_t k = a_start[p]; k < a_start[p + 1]; k++) {
				const int32_t q = a_list[k];
				if (parent[q] >= 0 || land[q] == 0) continue;
				const int32_t c = ctrl[q];
				if (c != nid && (c < 0 || war_row[c] == 0)) continue;
				parent[q] = p;
				queue.push_back(q);
			}
		}
		for (int32_t g : goals) goal[g] = 0;
		if (found < 0) continue;
		int len = 0;
		for (int32_t cur = found; cur != pv; cur = parent[cur]) len++;
		PackedInt32Array path;
		path.resize(len);
		int32_t *w = path.ptrw();
		for (int32_t cur = found; cur != pv; cur = parent[cur]) w[--len] = cur;
		per_front[found] += 1;
		if (fronts.has[pv]) per_front[pv] -= 1;
		used[i] = 1;
		Array o;
		o.push_back(i);
		o.push_back(path);
		orders.push_back(o);
	}
	// перегруз: лишние дивизии из провинции фронта сверх снабжения — во вторую
	// линию (ближайшая наша провинция у фронта с запасом снабжения)
	if (has_cap) {
		OrderedSet reserve(pc);
		std::vector<int32_t> rcount(pc, 0);
		for (int32_t f : fronts.order) {
			for (int32_t k = a_start[f]; k < a_start[f + 1]; k++) {
				const int32_t q = a_list[k];
				if (land[q] == 1 && ctrl[q] == nid && !fronts.has[q] && !reserve.has[q]) {
					reserve.add(q);
					int cnt = 0;
					for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++)
						if (dv_owner[pd_list[m]] == nid) cnt++;
					rcount[q] = cnt;
				}
			}
		}
		for (int32_t i : idle) {
			if (used[i]) continue;
			const int32_t pv = dv_prov[i];
			if (!fronts.has[pv] || per_front[pv] <= capd(pv)) continue;
			std::vector<int32_t> goals;
			for (int32_t q : reserve.order)
				if (rcount[q] < capd(q)) goals.push_back(q);
			if (goals.empty()) break;
			for (int32_t g : goals) goal[g] = 1;
			std::fill(parent.begin(), parent.end(), -1);
			queue.clear();
			parent[pv] = pv;
			queue.push_back(pv);
			int32_t found = -1;
			for (size_t head = 0; head < queue.size(); head++) {
				const int32_t p = queue[head];
				if (goal[p]) { found = p; break; }
				for (int32_t k = a_start[p]; k < a_start[p + 1]; k++) {
					const int32_t q = a_list[k];
					if (parent[q] >= 0 || land[q] == 0) continue;
					const int32_t c = ctrl[q];
					if (c != nid && (c < 0 || war_row[c] == 0)) continue;
					parent[q] = p;
					queue.push_back(q);
				}
			}
			for (int32_t g : goals) goal[g] = 0;
			if (found < 0) continue;
			int len = 0;
			for (int32_t cur = found; cur != pv; cur = parent[cur]) len++;
			PackedInt32Array path;
			path.resize(len);
			int32_t *w = path.ptrw();
			for (int32_t cur = found; cur != pv; cur = parent[cur]) w[--len] = cur;
			rcount[found] += 1;
			per_front[pv] -= 1;
			used[i] = 1;
			Array o;
			o.push_back(i);
			o.push_back(path);
			orders.push_back(o);
		}
	}
	return result;
}
