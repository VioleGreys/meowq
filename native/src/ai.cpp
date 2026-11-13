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
	// воюем, но не наступаем (Nation.no_attack): nc×nc, пусто — запретов нет
	const PackedByteArray nohit_a = tables.has("nohit") ? PackedByteArray(tables["nohit"]) : PackedByteArray();
	const bool has_nohit = nohit_a.size() > 0;
	const uint8_t *nohit = nohit_a.ptr();
	const float *supcap = supcap_a.ptr();
	auto capd = [&](int32_t p) { return std::max(1, int(std::floor(double(supcap[p])))); };
	// снабжение дивизий и климат (акклиматизация страны) — для выбора целей атаки
	const PackedFloat64Array dv_sup_a = tables.has("dv_sup") ? PackedFloat64Array(tables["dv_sup"]) : PackedFloat64Array();
	const bool has_sup = dv_sup_a.size() == dv_owner_a.size();
	const double *dv_sup = dv_sup_a.ptr();
	const PackedFloat32Array p_hot_a = tables.has("p_hot") ? PackedFloat32Array(tables["p_hot"]) : PackedFloat32Array();
	const PackedFloat32Array p_cold_a = tables.has("p_cold") ? PackedFloat32Array(tables["p_cold"]) : PackedFloat32Array();
	const PackedFloat64Array n_hot_a = tables.has("n_hot") ? PackedFloat64Array(tables["n_hot"]) : PackedFloat64Array();
	const PackedFloat64Array n_cold_a = tables.has("n_cold") ? PackedFloat64Array(tables["n_cold"]) : PackedFloat64Array();
	const bool has_clim = p_hot_a.size() == pc && p_cold_a.size() == pc && n_hot_a.size() > nid && n_cold_a.size() > nid;
	const float *p_hot = p_hot_a.ptr(), *p_cold = p_cold_a.ptr();
	const double *n_hot = n_hot_a.ptr(), *n_cold = n_cold_a.ptr();
	const double SUP_BAD = 0.5, SUP_EXH = 0.25, CLIM_ATK = 0.25, REGROUP_ORG = 0.1, ROTATE_ORG = 0.3, ESCAPE_RATIO = 3.0, SUPPORT_BONUS = 20.0;
	const int FILL_DEPTH = 6;
	auto sup_mult = [&](double sv) { return sv >= SUP_BAD ? 1.0 : (sv >= SUP_EXH ? 0.75 : 0.5); };
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
					if (!has_nohit || nohit[int64_t(nid) * nc + c] == 0) targets.add(q);
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
	// направление главного удара: лучшие цели атаки (3), к ним стягиваем силы
	std::vector<char> main_axis(pc, 0);
	bool has_axis = false;
	if (attack_allowed) {
		struct Entry {
			double score;
			int32_t t;
			double es;
			int dirs;
		};
		std::vector<Entry> target_list;
		for (int32_t t : targets.order) {
			double enemy_str = 0.0;
			int pocketed = 0;
			for (int32_t k = pd_start[t]; k < pd_start[t + 1]; k++) {
				const int32_t e = pd_list[k];
				const int32_t eo = dv_owner[e];
				if (eo != nid && war[int64_t(nid) * nc + eo] == 1) {
					// снабжение врага: голодающие и окружённые слабее (как в бою)
					double es = 1.0;
					if (has_sup) {
						es = sup_mult(dv_sup[e]);
						if (dv_sup[e] < SUP_EXH) pocketed++;
					}
					enemy_str += double(dv_defw[e]) * es;
				}
			}
			// местность и укрепления — как в бою (как ai.gd)
			const double def_mult = 1.0 / std::max(0.1, 1.0 - 0.6 * double(def_tab[t]));
			// климат: неакклиматизированные атакуют слабее — нужен больший перевес
			double clim = 0.0;
			if (has_clim)
				clim = std::min(1.0, double(p_hot[t]) * (1.0 - std::min(1.0, n_hot[nid])) + double(p_cold[t]) * (1.0 - std::min(1.0, n_cold[nid])));
			const double climf = 1.0 - CLIM_ATK * clim;
			double score = enemy_str * def_mult * 5.0 - vp[t] * 6.0 + double(rng->randf()) * 20.0 + clim * 30.0 - double(pocketed) * 12.0;
			if (objective >= 0) score += obj_dist[t] * 25.0;
			// охват: цель, которую можно атаковать с нескольких наших участков, важнее
			int dirs = 0, hostile_n = 0, closing = 0, sup_n = 0;
			double sup_sum = 0.0;
			for (int32_t k = a_start[t]; k < a_start[t + 1]; k++) {
				const int32_t q = a_list[k];
				if (fronts.has[q]) {
					dirs++;
					if (has_sup)
						for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++)
							if (dv_owner[pd_list[m]] == nid) { sup_sum += dv_sup[pd_list[m]]; sup_n++; }
				} else if (land[q] == 1 && ctrl[q] >= 0 && war[int64_t(nid) * nc + ctrl[q]] == 1) {
					hostile_n++;
					// котёл: взяв t, замкнём кольцо вокруг вражеской провинции q
					int open = 0;
					for (int32_t m = a_start[q]; m < a_start[q + 1]; m++) {
						const int32_t r = a_list[m];
						if (r != t && land[r] == 1 && ctrl[r] >= 0 && war[int64_t(nid) * nc + ctrl[r]] == 1) open++;
					}
					if (open == 0) closing++;
				}
			}
			// помощь соседнему бою: враг в цели уже ведёт бой с нами (атакует наш участок
			// или обороняется от нашей атаки) — удар туда важнее (как ai.gd)
			bool engaged = false;
			for (int32_t k = pd_start[t]; k < pd_start[t + 1] && !engaged; k++) {
				const int32_t e = pd_list[k];
				if (dv_owner[e] != nid && war[int64_t(nid) * nc + dv_owner[e]] == 1 && (dv_flags[e] & 2) != 0) engaged = true;
			}
			if (engaged) score -= SUPPORT_BONUS;
			if (dirs > 1) score -= double(dirs - 1) * 15.0;
			score -= double(closing) * 25.0;
			// удар — со снабжённых участков
			if (sup_n > 0) score += (1.0 - std::min(1.0, sup_sum / double(sup_n))) * 40.0;
			// выступ: цель окружена врагом, а бьём с одной стороны — риск котла
			double risk = 1.0;
			if (dirs == 1 && hostile_n >= 3) {
				score += double(hostile_n - 2) * 15.0;
				risk = 1.3;
			}
			target_list.push_back({ score, t, enemy_str * def_mult * risk / climf, dirs });
		}
		std::sort(target_list.begin(), target_list.end(), [](const Entry &a, const Entry &b) {
			return a.score < b.score || (a.score == b.score && a.t < b.t);
		});
		for (size_t j = 0; j < target_list.size() && j < 3; j++) {
			main_axis[target_list[j].t] = 1;
			has_axis = true;
		}
		std::vector<int32_t> left(pc, INT_MIN);   // сколько наших дивизий останется в провинции
		std::vector<int32_t> group, chosen;
		for (const Entry &entry : target_list) {
			const int32_t t = entry.t;
			double need = entry.es * ratio;
			// направление главного удара к цели наступления — сил с запасом (как ai.gd)
			double commit = (objective >= 0 && main_axis[t]) ? need * 2.0 : need;
			// осторожная страна не лезет в пустую провинцию-выступ (котёл)
			if (entry.es <= 0.0 && ratio >= 4.0 && entry.dirs < 2) continue;
			const bool breach = objective >= 0 && entry.es <= 0.0 && main_axis[t];
			group.clear();
			for (int32_t k = a_start[t]; k < a_start[t + 1]; k++) {
				const int32_t q = a_list[k];
				for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++) {
					const int32_t i = pd_list[m];
					// истощённые (снабжение < SUP_EXH) в атаку не идут (как ai.gd)
					if (dv_owner[i] == nid && in_group[i] && (dv_flags[i] & 1) == 1 && !used[i] && double(dv_org[i]) > 0.6
							&& (!has_sup || dv_sup[i] >= SUP_EXH))
						group.push_back(i);
				}
			}
			if (group.empty()) continue;
			// плохое снабжение группы (в среднем < SUP_BAD) — атака лишь с двойным перевесом (как ai.gd)
			if (has_sup) {
				double gs = 0.0;
				for (int32_t i : group) gs += dv_sup[i];
				if (gs / double(group.size()) < SUP_BAD) {
					need *= 2.0;
					commit = std::max(commit, need);
				}
			}
			std::sort(group.begin(), group.end(), [dv_power](int32_t a, int32_t b) {
				return dv_power[a] > dv_power[b] || (dv_power[a] == dv_power[b] && a < b);
			});
			chosen.clear();
			double power = 0.0;
			for (int32_t i : group) {
				const int32_t pv = dv_prov[i];
				if (left[pv] == INT_MIN) left[pv] = pd_start[pv + 1] - pd_start[pv];
				// последняя дивизия участок не бросает — кроме прорыва в пустую провинцию на направлении удара (как ai.gd)
				if (left[pv] <= 1 && !(breach && left[pv] == 1)) continue;
				chosen.push_back(i);
				left[pv] -= 1;
				power += double(dv_power[i]);
				if (power > commit && (entry.es <= 0.0 || chosen.size() >= 2)) break;
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

	// отход с передовой (решение пользователя; как ai.gd):
	// организация < REGROUP_ORG (10 %) — в соседний тыл, даже последняя на участке,
	// и на фронт не идёт, пока не восстановится; < ROTATE_ORG (30 %) — ротация,
	// если на участке остаётся кто-то из наших (смена на марше восстанавливает
	// организацию); резерв, ещё не вызванный в бой (не «в бою»), уходит из
	// провинции, которую не удержать: атакующих сильнее обороны в ESCAPE_RATIO раз
	std::vector<int32_t> rotated;
	if (at_war) {
		std::vector<int32_t> ours_left(pc, INT_MIN);
		std::vector<int8_t> hopeless(pc, -1);
		auto is_hopeless = [&](int32_t pv) -> bool {
			if (hopeless[pv] >= 0) return hopeless[pv] == 1;
			bool fighting = false;
			double ours = 0.0;
			for (int32_t m = pd_start[pv]; m < pd_start[pv + 1]; m++) {
				const int32_t e = pd_list[m];
				if (dv_owner[e] != nid) continue;
				if ((dv_flags[e] & 2) != 0) fighting = true;
				ours += double(dv_defw[e]);
			}
			double theirs = 0.0;
			if (fighting) {
				for (int32_t k = a_start[pv]; k < a_start[pv + 1]; k++) {
					const int32_t q = a_list[k];
					for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++) {
						const int32_t e = pd_list[m];
						const int32_t eo = dv_owner[e];
						if (eo != nid && war[int64_t(nid) * nc + eo] == 1 && (dv_flags[e] & 2) != 0) theirs += double(dv_power[e]);
					}
				}
			}
			const double dm = 1.0 / std::max(0.1, 1.0 - 0.6 * double(def_tab[pv]));
			const bool h = fighting && theirs > ESCAPE_RATIO * ours * dm;
			hopeless[pv] = h ? 1 : 0;
			return h;
		};
		for (int32_t i : idle) {
			if (used[i]) continue;
			const int32_t pv = dv_prov[i];
			if (!fronts.has[pv]) continue;
			const double o = double(dv_org[i]);
			if (ours_left[pv] == INT_MIN) {
				int cnt = 0;
				for (int32_t m = pd_start[pv]; m < pd_start[pv + 1]; m++)
					if (dv_owner[pd_list[m]] == nid) cnt++;
				ours_left[pv] = cnt;
			}
			bool go = false;
			if (o < REGROUP_ORG) go = true;
			else if (o < ROTATE_ORG) go = ours_left[pv] > 1;
			else go = is_hopeless(pv);
			if (!go) continue;
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
			Array o2;
			o2.push_back(i);
			PackedInt32Array path;
			path.push_back(rear);
			o2.push_back(path);
			orders.push_back(o2);
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
	std::vector<char> axis_front(pc, 0);
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
		if (has_axis) {
			for (int32_t k = a_start[f]; k < a_start[f + 1]; k++)
				if (main_axis[a_list[k]]) {
					weight[f] += 3.0;
					if (objective >= 0) axis_front[f] = 1;   // план наступления: до ёмкости снабжения (как ai.gd)
					break;
				}
		}
		wsum += weight[f];
	}
	std::vector<int32_t> desired(pc, 0);
	// план наступления: участкам удара — до ёмкости снабжения, прочим — остаток (как ai.gd)
	int64_t pool = divs.size();
	if (has_cap) {
		for (int32_t f : fronts.order)
			if (axis_front[f]) pool -= capd(f);
		if (pool < 0) pool = 0;
	}
	for (int32_t f : fronts.order) {
		desired[f] = std::max(1, int(std::round(double(pool) * weight[f] / wsum)));
		if (has_cap) desired[f] = std::min(desired[f], capd(f));
		if (has_cap && axis_front[f]) desired[f] = capd(f);
	}

	// пустой участок фронта (в том числе оставленный уходящей дивизией): туда идёт
	// ближайшая свободная дивизия — из тыла или лишняя на участке сверх нужного;
	// поиск по своей земле на FILL_DEPTH переходов (решение пользователя; как ai.gd)
	if (at_war) {
		std::vector<int32_t> fpar(pc, -2), fdep(pc, 0), fq, touched;
		for (int32_t f : fronts.order) {
			if (per_front[f] > 0) continue;
			fq.clear();
			fq.push_back(f);
			fpar[f] = -1;
			touched.push_back(f);
			int32_t found = -1, fdiv = -1;
			for (size_t head = 0; head < fq.size(); head++) {
				const int32_t x = fq[head];
				if (x != f) {
					const bool spare = !fronts.has[x] || per_front[x] > std::max(1, desired[x]);
					if (spare)
						for (int32_t m = pd_start[x]; m < pd_start[x + 1]; m++) {
							const int32_t i = pd_list[m];
							if (dv_owner[i] == nid && in_group[i] && (dv_flags[i] & 1) == 1 && !used[i] && double(dv_org[i]) >= REGROUP_ORG) {
								fdiv = i;
								break;
							}
						}
					if (fdiv >= 0) { found = x; break; }
				}
				if (fdep[x] >= FILL_DEPTH) continue;
				for (int32_t k = a_start[x]; k < a_start[x + 1]; k++) {
					const int32_t y = a_list[k];
					if (fpar[y] != -2 || land[y] == 0 || ctrl[y] != nid) continue;
					fpar[y] = x;
					fdep[y] = fdep[x] + 1;
					fq.push_back(y);
					touched.push_back(y);
				}
			}
			if (fdiv >= 0) {
				PackedInt32Array path;
				for (int32_t cur = fpar[found]; cur != -1; cur = fpar[cur]) path.push_back(cur);
				used[fdiv] = 1;
				Array o3;
				o3.push_back(fdiv);
				o3.push_back(path);
				orders.push_back(o3);
				per_front[f] = 1;
				if (fronts.has[found]) per_front[found] -= 1;
			}
			for (int32_t t : touched) { fpar[t] = -2; fdep[t] = 0; }
			touched.clear();
		}
	}

	// поиск пути к ближайшему участку (как Pathfinder.nearest_goal)
	std::vector<char> goal(pc, 0);
	std::vector<int32_t> parent(pc, -1), queue;
	const uint8_t *war_row = war + int64_t(nid) * nc;
	for (int32_t i : idle) {
		if (used[i]) continue;
		if (double(dv_org[i]) < REGROUP_ORG) continue;   // перегруппировка — на фронт не идёт (как ai.gd)
		const int32_t pv = dv_prov[i];
		if (fronts.has[pv] && per_front[pv] <= desired[pv] + 1) continue;
		std::vector<int32_t> goals;
		// план наступления: пока участки удара не заполнены — только к ним (как ai.gd)
		for (int32_t f : fronts.order)
			if (axis_front[f] && per_front[f] < desired[f] && f != pv) goals.push_back(f);
		if (goals.empty())
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
	// перегруз: лишние дивизии из провинции фронта сверх снабжения — в ближайшую
	// нашу тыловую провинцию с запасом снабжения (вторая линия, заполнена — глубже)
	if (has_cap) {
		OrderedSet reserve(pc);
		std::vector<int32_t> rcount(pc, 0);
		for (int32_t q = 0; q < pc; q++) {
			if (land[q] == 1 && ctrl[q] == nid && !fronts.has[q]) {
				reserve.add(q);
				int cnt = 0;
				for (int32_t m = pd_start[q]; m < pd_start[q + 1]; m++)
					if (dv_owner[pd_list[m]] == nid) cnt++;
				rcount[q] = cnt;
			}
		}
		// цели — тыловые провинции с запасом; заполненная выбывает
		std::vector<int32_t> goals;
		int n_goals = 0;
		for (int32_t q : reserve.order)
			if (rcount[q] < capd(q)) { goals.push_back(q); n_goals++; }
		for (int32_t g : goals) goal[g] = 1;
		for (int32_t i : idle) {
			if (used[i]) continue;
			const int32_t pv = dv_prov[i];
			const int cap_pv = capd(pv);
			// фронт — по счёту участка; тыл — по числу наших дивизий в провинции
			if ((fronts.has[pv] && per_front[pv] <= cap_pv) || (!fronts.has[pv] && (!reserve.has[pv] || rcount[pv] <= cap_pv))) continue;
			if (n_goals == 0) break;
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
			if (found < 0) continue;
			int len = 0;
			for (int32_t cur = found; cur != pv; cur = parent[cur]) len++;
			PackedInt32Array path;
			path.resize(len);
			int32_t *w = path.ptrw();
			for (int32_t cur = found; cur != pv; cur = parent[cur]) w[--len] = cur;
			rcount[found] += 1;
			if (rcount[found] >= capd(found)) { goal[found] = 0; n_goals--; }
			if (fronts.has[pv]) per_front[pv] -= 1;
			else {
				rcount[pv] -= 1;
				if (rcount[pv] < cap_pv && !goal[pv]) { goal[pv] = 1; n_goals++; goals.push_back(pv); }
			}
			used[i] = 1;
			Array o;
			o.push_back(i);
			o.push_back(path);
			orders.push_back(o);
		}
		for (int32_t g : goals) goal[g] = 0;
	}
	return result;
}
