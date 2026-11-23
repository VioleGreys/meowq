// Внешняя экономика (Economy, двойники на GDScript): раздача экспорта по
// планам продавцов, пересчёт поставок, докупка и отказ от лишнего у
// покупателей дня (trade_sweep); соседство стран и узлы материков
// (trade_geo); добыча стран (res_prod). Операция в операцию как в GDScript:
// double, накопление в PackedFloat32Array — через float, тот же порядок.
#include "meowq_core.h"

#include <godot_cpp/core/math.hpp>

#include <unordered_map>
#include <vector>

using namespace godot;

namespace {
const double UNITS_PER_CIV = 24.0;
const double SELLER_SHARE = 0.5;
const int CONTRACT_DAYS = 30;
const int R = 6;

struct Sweep {
	int nc = 0, day = 0;
	const uint8_t *alive, *player, *autob, *war, *emb, *block;
	const int32_t *fac, *over;
	const uint8_t *closed;   // trade_closed (без проверки сюзерена)
	const double *law, *base;
	const float *prod, *need, *rep, *score;
	bool has_block = false, has_rep = false;
	std::vector<float> in, out;
	std::vector<double> civ, civ_in;
	std::vector<int32_t> c0, c1, c2, c4, c5;
	std::vector<double> c3, c6;
	std::unordered_map<int64_t, int> first;   // покупатель, продавец, ресурс → первая поставка (Economy._find)

	static int64_t key(int b, int s, int r) { return (int64_t(b) * 100000 + s) * 8 + r; }

	bool can_trade(int b, int s) const {
		if (b == s || !alive[s] || war[b * nc + s] == 1 || emb[s * nc + b] == 1)
			return false;
		if (has_block && block[b * nc + s] == 1)
			return false;
		if (closed[s] && over[s] >= 0 && over[s] != b)
			return false;
		if (has_rep && rep[s * nc + b] < -30.0)
			return false;
		return true;
	}
	bool is_ally(int s, int b) const {
		if (player[s] || b < 0 || b == s)
			return false;
		return over[s] == b || (fac[s] >= 0 && fac[s] == fac[b]);
	}
	double export_cap(int s, int r, bool ally) const {
		const double share = (ally || (closed[s] && over[s] >= 0)) ? 1.0 : law[s];
		const double p = prod[s * R + r];
		const double cap = p * share;
		return Math::min(cap, Math::max(0.0, p - double(need[s * R + r]) * 1.1));
	}
	double exportable(int s, int r, int b) const {
		const bool ally = b >= 0 && is_ally(s, b);
		return Math::max(0.0, export_cap(s, r, ally) - double(out[s * R + r]));
	}
	double ordered(int n, int r) const {
		return double(prod[n * R + r]) - double(out[n * R + r]) + double(in[n * R + r]);
	}
	double budget(int n) const {
		if (player[n] && !autob[n])
			return 0.0;
		return base[n] - civ[n];
	}
	void add(int b, int s, int r, double u) {
		in[b * R + r] = float(double(in[b * R + r]) + u);
		out[s * R + r] = float(double(out[s * R + r]) + u);
		civ[b] += u / UNITS_PER_CIV;
		civ_in[s] += u / UNITS_PER_CIV * SELLER_SHARE;
	}
	int append(int b, int s, int r, double u) {
		const int k = int(c0.size());
		c0.push_back(b);
		c1.push_back(s);
		c2.push_back(r);
		c3.push_back(u);
		c4.push_back(day + CONTRACT_DAYS);
		c5.push_back(0);
		c6.push_back(-1.0);
		first.emplace(key(b, s, r), k);
		return k;
	}
	void recount() {
		std::fill(in.begin(), in.end(), 0.0f);
		std::fill(out.begin(), out.end(), 0.0f);
		std::fill(civ.begin(), civ.end(), 0.0);
		std::fill(civ_in.begin(), civ_in.end(), 0.0);
		for (size_t k = 0; k < c0.size(); k++)
			add(c0[k], c1[k], c2[k], c3[k]);
	}
	bool buy(int b, int s, int r, double units) {
		units = Math::snapped(units, 0.1);
		if (units < 0.1 || !can_trade(b, s))
			return false;
		if (exportable(s, r, b) + 0.001 < units)
			return false;
		auto it = first.find(key(b, s, r));
		if (it != first.end()) {
			const int k = it->second;
			c3[k] = c3[k] + units;
			if (c6[k] >= 0.0)
				c6[k] = c6[k] + units;
		} else {
			append(b, s, r, units);
		}
		add(b, s, r, units);
		return true;
	}
	void ai_buy(int n, std::vector<std::vector<int>> &freel, bool &built) {
		bool any = false;
		for (int r = 0; r < R; r++) {
			if (double(need[n * R + r]) * 1.05 - ordered(n, r) >= 1.0) {
				any = true;
				break;
			}
		}
		if (!any)
			return;
		if (!built) {
			built = true;
			freel.assign(R, std::vector<int>());
			for (int r = 0; r < R; r++)
				for (int x = 0; x < nc; x++)
					if (alive[x] && Math::max(0.0, export_cap(x, r, !player[x]) - double(out[x * R + r])) >= 1.0)
						freel[r].push_back(x);
		}
		double bud = budget(n);
		for (int r = 0; r < R; r++) {
			double lack = double(need[n * R + r]) * 1.05 - ordered(n, r);
			if (lack < 1.0 || bud <= 0.05)
				continue;
			lack = Math::min(lack, bud * UNITS_PER_CIV);
			const std::vector<int> &lst = freel[r];
			std::vector<uint8_t> dead(lst.size(), 0);
			while (lack >= 1.0) {
				int best = -1;
				double best_score = 0.0;
				for (size_t j = 0; j < lst.size(); j++) {
					if (dead[j])
						continue;
					const int s = lst[j];
					const double sc = score[s * nc + n];
					if (sc <= best_score) {
						if (sc <= 0.0)
							dead[j] = 1;
						continue;
					}
					if (exportable(s, r, n) < 1.0) {
						dead[j] = 1;
						continue;
					}
					best_score = sc;
					best = s;
				}
				if (best < 0)
					break;
				const double take = Math::min(lack, exportable(best, r, n));
				if (!buy(n, best, r, take))
					break;
				lack -= take;
				bud -= take / UNITS_PER_CIV;
			}
		}
	}
	void ai_cut(int n, const std::vector<int> &mine) {
		for (int r = 0; r < R; r++) {
			double extra = ordered(n, r) - double(need[n * R + r]) * 1.15;
			if (extra <= 0.5)
				continue;
			for (int j = int(mine.size()) - 1; j >= 0; j--) {
				const int k = mine[j];
				if (c0[k] == n && c2[k] == r && c6[k] < 0.0 && c3[k] <= extra && c5[k] <= day) {
					c6[k] = 0.0;
					extra -= c3[k];
				}
			}
		}
		// закупки сверх бюджета — отказ с конца, пока оплата не уложится в долю фабрик
		double over = -budget(n);
		if (over <= 0.1)
			return;
		for (int j = int(mine.size()) - 1; j >= 0; j--) {
			const int k = mine[j];
			if (c0[k] == n && c6[k] < 0.0 && c5[k] <= day) {
				c6[k] = 0.0;
				over -= c3[k] / UNITS_PER_CIV;
				if (over <= 0.0)
					break;
			}
		}
	}
};

template <typename T, typename P>
static std::vector<T> to_vec(const P &a) {
	std::vector<T> v(a.size());
	for (int64_t i = 0; i < a.size(); i++)
		v[i] = a[i];
	return v;
}
} // namespace

// t: nc, day, due, rows (Array PackedFloat32Array), plans (Array [[b, r, give]]),
// score (trade_score), alive/player/auto/closed/fac/over/law/base (по странам;
// base — (civ − товары народного потребления) × AI_CIV_SHARE), prod/need/in/out
// (nc*6, float32), civ/civ_in (trade_civ, trade_civ_in), war, emb, block, rep
// (nc*nc), поставки по столбцам c0..c6; keep — сначала обход поставок (как в
// Economy.daily) и пересчёт.
// → [score, c0..c6 (оставшиеся, новые — в конце), in, out, civ, civ_in,
// номера оставшихся (keep), покупатели без заморских поставок, сколько снято].
Array MeowqCore::trade_sweep(const Dictionary &t) const {
	Sweep w;
	w.nc = int(t["nc"]);
	w.day = int(t["day"]);
	const int nc = w.nc;
	const PackedInt32Array due = t["due"];
	const Array rows = t["rows"], plans = t["plans"];
	PackedFloat32Array score = t["score"];
	const PackedByteArray alive_a = t["alive"], player_a = t["player"], auto_a = t["auto"], closed_a = t["closed"];
	const PackedInt32Array fac_a = t["fac"], over_a = t["over"];
	const PackedFloat64Array law_a = t["law"], base_a = t["base"];
	const PackedFloat32Array prod_a = t["prod"], need_a = t["need"], rep_a = t["rep"];
	const PackedByteArray war_a = t["war"], emb_a = t["emb"], block_a = t["block"];
	w.alive = alive_a.ptr();
	w.player = player_a.ptr();
	w.autob = auto_a.ptr();
	w.closed = closed_a.ptr();
	w.fac = fac_a.ptr();
	w.over = over_a.ptr();
	w.law = law_a.ptr();
	w.base = base_a.ptr();
	w.prod = prod_a.ptr();
	w.need = need_a.ptr();
	w.rep = rep_a.ptr();
	w.war = war_a.ptr();
	w.emb = emb_a.ptr();
	w.block = block_a.ptr();
	w.has_block = block_a.size() == int64_t(nc) * nc;
	w.has_rep = rep_a.size() == int64_t(nc) * nc;
	w.in = to_vec<float>(PackedFloat32Array(t["in"]));
	w.out = to_vec<float>(PackedFloat32Array(t["out"]));
	w.civ = to_vec<double>(PackedFloat64Array(t["civ"]));
	w.civ_in = to_vec<double>(PackedFloat64Array(t["civ_in"]));
	w.c0 = to_vec<int32_t>(PackedInt32Array(t["c0"]));
	w.c1 = to_vec<int32_t>(PackedInt32Array(t["c1"]));
	w.c2 = to_vec<int32_t>(PackedInt32Array(t["c2"]));
	w.c3 = to_vec<double>(PackedFloat64Array(t["c3"]));
	w.c4 = to_vec<int32_t>(PackedInt32Array(t["c4"]));
	w.c5 = to_vec<int32_t>(PackedInt32Array(t["c5"]));
	w.c6 = to_vec<double>(PackedFloat64Array(t["c6"]));
	// обход поставок (keep): блокада рвёт и договорные; истёкшие продлеваются на
	// месяц (или снимаются), отказ и урезка вступают в силу
	PackedInt32Array kept;
	PackedInt32Array cut_b, cut_n;
	const bool keep = t.get("keep", false);
	if (keep) {
		std::vector<int> cut_cnt(nc, 0);
		size_t m = 0;
		for (size_t k = 0; k < w.c0.size(); k++) {
			const int b = w.c0[k], s = w.c1[k];
			if (w.has_block && w.block[b * nc + s] == 1) {
				if (cut_cnt[b]++ == 0)
					cut_b.append(b);
				continue;
			}
			if (w.day >= w.c4[k]) {
				if (!w.can_trade(b, s))
					continue;
				if (w.c6[k] >= 0.0) {
					w.c3[k] = w.c6[k];
					w.c6[k] = -1.0;
				}
				if (w.c3[k] < 0.05)
					continue;
				while (w.c4[k] <= w.day)
					w.c4[k] = w.c4[k] + CONTRACT_DAYS;
			}
			kept.append(int(k));
			w.c0[m] = w.c0[k];
			w.c1[m] = w.c1[k];
			w.c2[m] = w.c2[k];
			w.c3[m] = w.c3[k];
			w.c4[m] = w.c4[k];
			w.c5[m] = w.c5[k];
			w.c6[m] = w.c6[k];
			m++;
		}
		for (auto *v : {&w.c0, &w.c1, &w.c2, &w.c4, &w.c5})
			v->resize(m);
		w.c3.resize(m);
		w.c6.resize(m);
		for (int i = 0; i < cut_b.size(); i++)
			cut_n.append(cut_cnt[cut_b[i]]);
		w.recount();
	}
	const int n0 = int(w.c0.size());
	// индекс продавца: продавец, покупатель, ресурс → поставка (последняя — как Dictionary)
	std::unordered_map<int64_t, int> index;
	for (int k = 0; k < n0; k++) {
		index[w.key(w.c1[k], w.c0[k], w.c2[k])] = k;
		w.first.emplace(w.key(w.c0[k], w.c1[k], w.c2[k]), k);
	}
	float *sc = score.ptrw();
	for (int i = 0; i < due.size(); i++) {
		const int s = due[i];
		const PackedFloat32Array row = rows[i];
		const float *rw = row.ptr();
		for (int b = 0; b < nc; b++)
			sc[s * nc + b] = rw[b];
		if (!w.alive[s])
			continue;
		const Array plan = plans[i];
		for (int j = 0; j < plan.size(); j++) {
			const Array p = plan[j];
			const int b = int(p[0]), r = int(p[1]);
			const double give = double(p[2]);
			const int64_t ik = w.key(s, b, r);
			auto it = index.find(ik);
			if (it != index.end() && w.c5[it->second] > w.day)
				continue;
			if (it == index.end()) {
				if (give >= 0.3 && w.can_trade(b, s) && w.budget(b) >= give / UNITS_PER_CIV) {
					index[ik] = w.append(b, s, r, give);
					w.add(b, s, r, give);
				}
			} else if (give < w.c3[it->second]) {
				w.c6[it->second] = give;
			} else {
				w.c3[it->second] = give;
				w.c6[it->second] = -1.0;
			}
		}
	}
	w.score = sc;
	w.recount();
	// покупатели дня: договоры по покупателю — номера по возрастанию
	std::vector<std::vector<int>> by_buyer(nc);
	for (size_t k = 0; k < w.c0.size(); k++)
		by_buyer[w.c0[k]].push_back(int(k));
	std::vector<std::vector<int>> freel;
	bool built = false;
	for (int i = 0; i < due.size(); i++) {
		const int x = due[i];
		if (!w.alive[x] || (w.player[x] && !w.autob[x]))
			continue;
		const int m0 = int(w.c0.size());
		w.ai_buy(x, freel, built);
		std::vector<int> &mine = by_buyer[x];
		for (int k = m0; k < int(w.c0.size()); k++)
			mine.push_back(k);
		w.ai_cut(x, mine);
	}
	auto pi = [](const std::vector<int32_t> &v) {
		PackedInt32Array a;
		a.resize(v.size());
		for (size_t i = 0; i < v.size(); i++)
			a.set(i, v[i]);
		return a;
	};
	auto pd = [](const std::vector<double> &v) {
		PackedFloat64Array a;
		a.resize(v.size());
		for (size_t i = 0; i < v.size(); i++)
			a.set(i, v[i]);
		return a;
	};
	auto pf = [](const std::vector<float> &v) {
		PackedFloat32Array a;
		a.resize(v.size());
		for (size_t i = 0; i < v.size(); i++)
			a.set(i, v[i]);
		return a;
	};
	Array res;
	res.append(score);
	res.append(pi(w.c0));
	res.append(pi(w.c1));
	res.append(pi(w.c2));
	res.append(pd(w.c3));
	res.append(pi(w.c4));
	res.append(pi(w.c5));
	res.append(pd(w.c6));
	res.append(pf(w.in));
	res.append(pf(w.out));
	res.append(pd(w.civ));
	res.append(pd(w.civ_in));
	res.append(kept);
	res.append(cut_b);
	res.append(cut_n);
	return res;
}

// Соседство стран и выход к морю (Economy.refresh_geo): → [trade_adj (nc*nc),
// trade_coast (nc), ключи узлов по первому появлению, начала (+1), соседние узлы
// по первому появлению].
Array MeowqCore::trade_geo(const PackedInt32Array &ctrl, const PackedByteArray &land, const PackedByteArray &coastal,
		const PackedInt32Array &adj_start, const PackedInt32Array &adj_list, const PackedInt32Array &mass, int nc) const {
	const int pc = int(ctrl.size());
	PackedByteArray adj;
	adj.resize(int64_t(nc) * nc);
	adj.fill(0);
	PackedByteArray coast;
	coast.resize(nc);
	coast.fill(0);
	uint8_t *ad = adj.ptrw(), *co = coast.ptrw();
	const int32_t *ct = ctrl.ptr(), *as = adj_start.ptr(), *al = adj_list.ptr(), *ms = mass.ptr();
	const uint8_t *ld = land.ptr(), *cs = coastal.ptr();
	std::unordered_map<int64_t, int> node;   // ключ узла → номер по первому появлению
	std::vector<int64_t> keys;
	std::vector<std::vector<int64_t>> lists;
	std::vector<std::unordered_map<int64_t, char>> seen;
	for (int p = 0; p < pc; p++) {
		const int c = ct[p];
		if (c < 0 || ld[p] == 0)
			continue;
		if (cs[p] == 1)
			co[c] = 1;
		for (int k = as[p]; k < as[p + 1]; k++) {
			const int q = al[k];
			const int d = ct[q];
			if (d >= 0 && d != c && ld[q] == 1) {
				ad[c * nc + d] = 1;
				const int64_t ka = int64_t(ms[p]) * nc + c;
				const int64_t kb = int64_t(ms[p]) * nc + d;
				auto it = node.find(ka);
				int ni;
				if (it == node.end()) {
					ni = int(keys.size());
					node.emplace(ka, ni);
					keys.push_back(ka);
					lists.emplace_back();
					seen.emplace_back();
				} else {
					ni = it->second;
				}
				if (seen[ni].emplace(kb, 1).second)
					lists[ni].push_back(kb);
			}
		}
	}
	PackedInt64Array ks;
	ks.resize(keys.size());
	PackedInt32Array st;
	st.resize(keys.size() + 1);
	size_t tot = 0;
	for (size_t i = 0; i < keys.size(); i++) {
		ks.set(i, keys[i]);
		st.set(i, int32_t(tot));
		tot += lists[i].size();
	}
	st.set(keys.size(), int32_t(tot));
	PackedInt32Array ls;
	ls.resize(tot);
	size_t o = 0;
	for (auto &l : lists)
		for (int64_t v : l)
			ls.set(o++, int32_t(v));
	Array res;
	res.append(adj);
	res.append(coast);
	res.append(ks);
	res.append(st);
	res.append(ls);
	return res;
}

// Добыча стран по контролируемым провинциям (Economy._refresh_prod, без
// марионеток и синтетики): mult — 1 + бонус resources по странам; yl — p_yield.
// → [res_ctrl, добыча nc*6 (float32)].
Array MeowqCore::res_prod(const PackedInt32Array &res_prov, const PackedFloat32Array &res_val, const PackedInt32Array &ctrl,
		const PackedFloat32Array &yl, const PackedFloat64Array &mult, int nc) const {
	const int n = int(res_prov.size());
	const bool has_y = yl.size() == ctrl.size();
	PackedInt32Array rc;
	rc.resize(n);
	PackedFloat32Array prod;
	prod.resize(int64_t(nc) * R);
	prod.fill(0.0f);
	float *pr = prod.ptrw();
	int32_t *rcw = rc.ptrw();
	const int32_t *rp = res_prov.ptr(), *ct = ctrl.ptr();
	const float *rv = res_val.ptr(), *y = yl.ptr();
	const double *ml = mult.ptr();
	for (int i = 0; i < n; i++) {
		const int c = ct[rp[i]];
		rcw[i] = c;
		if (c < 0)
			continue;
		double m = ml[c];
		if (has_y)
			m *= double(y[rp[i]]);
		for (int r = 0; r < R; r++)
			pr[c * R + r] = float(double(pr[c * R + r]) + double(rv[i * R + r]) * m);
	}
	Array res;
	res.append(rc);
	res.append(prod);
	return res;
}
