// Ядра горячих фаз дня. Каждое повторяет World.k_* из scripts/sim/world.gd
// операция в операцию (double, тот же порядок обхода и вычислений): игра с
// библиотекой и без неё обязана считать одинаково (tests/sim_bench.gd).
#include "meowq_core.h"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

// Снабжение (World.sup_mult и константы — двойники)
static constexpr double SUP_BAD = 0.5, SUP_EXH = 0.25, EXH_LOSS = 1.5, ORG_DECAY = 0.03;
static inline double sup_mult(double s) { return s >= SUP_BAD ? 1.0 : (s >= SUP_EXH ? 0.75 : 0.5); }

static inline double clampd(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline double maxd(double a, double b) { return a > b ? a : b; }   // как maxf в Godot
static inline double mind(double a, double b) { return a < b ? a : b; }

Array MeowqCore::recovery(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedFloat64Array &sup,
		const PackedFloat64Array &org_in, const PackedFloat64Array &morg, const PackedFloat64Array &str_in,
		const PackedFloat64Array &eq_in, const PackedFloat64Array &ent_in, const PackedInt32Array &next,
		const PackedByteArray &battle, const PackedInt32Array &owner, const PackedInt32Array &prov,
		const PackedInt32Array &tpl, const PackedInt32Array &ctrl, const PackedByteArray &ally, int nc,
		const PackedFloat32Array &stock_in, const PackedFloat64Array &manpower_in, const PackedFloat64Array &rbonus,
		const PackedFloat64Array &tpl_eq, const PackedFloat64Array &tpl_men, const PackedInt32Array &pool) const {
	const int32_t *pl_p = pool.ptr();
	PackedFloat64Array org = org_in, str = str_in, eq = eq_in, ent = ent_in, manpower = manpower_in;
	PackedFloat32Array stock = stock_in;
	PackedInt32Array dead;
	double *o_org = org.ptrw(), *o_str = str.ptrw(), *o_eq = eq.ptrw(), *o_ent = ent.ptrw(), *mp = manpower.ptrw();
	float *st = stock.ptrw();
	const uint8_t *al = alive.ptr(), *bt = battle.ptr(), *ally_p = ally.ptr();
	const int32_t *tr = transit.ptr(), *nx = next.ptr(), *ow = owner.ptr(), *pv = prov.ptr(), *tp = tpl.ptr(), *ct = ctrl.ptr();
	const double *sp = sup.ptr(), *mo = morg.ptr(), *rb = rbonus.ptr(), *te = tpl_eq.ptr(), *tm = tpl_men.ptr();
	const int64_t n = alive.size();
	for (int64_t i = 0; i < n; i++) {
		if (al[i] == 0 || tr[i] > 0) continue;
		const double s = sp[i];
		if (s <= 0.0) {
			o_org[i] = maxd(0.0, o_org[i] - mo[i] * 0.02);
			o_str[i] = maxd(0.0, o_str[i] - 0.6);
			o_eq[i] = maxd(0.0, o_eq[i] - 0.004);
			if (o_str[i] <= 5.0) dead.push_back(int32_t(i));
			continue;
		}
		o_ent[i] = nx[i] < 0 ? mind(1.0, o_ent[i] + 0.05) : 0.0;
		if (bt[i] != 0) continue;
		const double rate = nx[i] < 0 ? 0.06 : 0.03;
		const double cap = mo[i] * mind(1.0, s);
		if (o_org[i] > cap)
			o_org[i] = maxd(cap, o_org[i] - mo[i] * ORG_DECAY);
		else
			o_org[i] = mind(cap, o_org[i] + mo[i] * rate * (0.3 + 0.7 * s));
		const int32_t o = ow[i];
		const int32_t c = ct[pv[i]];
		if (c != o && ally_p[int64_t(o) * nc + c] != 1) continue;
		const int32_t pl = pl_p[i];
		if (pl < 0 || s < 0.3 || (o_eq[i] >= 1.0 && o_str[i] >= 100.0)) continue;
		const int32_t t = tp[i];
		const double rr = 0.04 * (1.0 + rb[o]) * s;
		if (o_eq[i] < 1.0) {
			double want = mind(1.0 - o_eq[i], rr);
			for (int k = 0; k < 7; k++) {
				const double e = te[t * 7 + k];
				if (e > 0) want = mind(want, double(st[pl * 7 + k]) / e);
			}
			if (want > 0.0) {
				for (int k = 0; k < 7; k++) st[pl * 7 + k] = float(double(st[pl * 7 + k]) - te[t * 7 + k] * want);
				o_eq[i] += want;
			}
		}
		if (o_str[i] < 100.0) {
			const double add = mind(100.0 - o_str[i], rr * 100.0);
			const double men = add / 100.0 * tm[t];
			if (mp[o] >= men) {
				mp[o] -= men;
				o_str[i] += add;
			}
		}
	}
	Array r;
	r.push_back(org);
	r.push_back(str);
	r.push_back(eq);
	r.push_back(ent);
	r.push_back(stock);
	r.push_back(manpower);
	r.push_back(dead);
	return r;
}

PackedFloat64Array MeowqCore::supply_apply(const PackedByteArray &alive, const PackedFloat64Array &sup_in, const PackedInt32Array &prov, const PackedInt32Array &tpl,
		const PackedInt32Array &owner, const PackedInt32Array &side_of, const PackedInt32Array &dist,
		const PackedFloat32Array &caps, int prov_count, int t_mot) const {
	const int64_t n = alive.size();
	std::vector<float> demand(prov_count, 0.0f);   // как PackedFloat32Array в GDScript
	const uint8_t *al = alive.ptr();
	const int32_t *pv = prov.ptr(), *tp = tpl.ptr(), *ow = owner.ptr(), *so = side_of.ptr(), *ds = dist.ptr();
	const float *cp = caps.ptr();
	for (int64_t i = 0; i < n; i++)
		if (al[i] == 1) demand[pv[i]] = float(double(demand[pv[i]]) + (tp[i] >= t_mot ? 1.5 : 1.0));
	PackedFloat64Array out = sup_in;
	double *o = out.ptrw();
	for (int64_t i = 0; i < n; i++) {
		if (al[i] == 0) continue;
		const int32_t s = so[ow[i]];
		const int32_t p = pv[i];
		const int32_t h = s >= 0 ? ds[int64_t(s) * prov_count + p] : -1;
		if (h < 0) {
			o[i] = 0.0;
			continue;
		}
		const double reach = h <= 5 ? 1.0 : maxd(0.35, 1.0 - (h - 5) * 0.06);
		const double cap = mind(1.0, double(cp[p]) / maxd(1.0, double(demand[p])));
		o[i] = reach * cap;
	}
	return out;
}

Array MeowqCore::march(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedInt32Array &next_in,
		const PackedInt32Array &owner, const PackedInt32Array &prov, const PackedFloat64Array &prog_in,
		const PackedFloat64Array &spd, const PackedFloat64Array &org, const PackedFloat64Array &morg,
		const PackedFloat64Array &sup, const PackedByteArray &land, const PackedInt32Array &ctrl,
		const PackedByteArray &war, int nc, const PackedFloat32Array &move_mult) const {
	PackedFloat64Array prog = prog_in;
	PackedInt32Array next = next_in;
	const int64_t n = alive.size();
	const int pc = int(land.size());
	const uint8_t *al = alive.ptr(), *ld = land.ptr(), *wr = war.ptr();
	const int32_t *tr = transit.ptr(), *ow = owner.ptr(), *pv = prov.ptr(), *ct = ctrl.ptr();
	const double *sd = spd.ptr(), *og = org.ptr(), *mo = morg.ptr(), *su = sup.ptr();
	const float *mm = move_mult.ptr();
	int32_t *nx = next.ptrw();
	double *pg = prog.ptrw();
	std::vector<int32_t> start(pc + 1, 0), list;
	for (int64_t i = 0; i < n; i++)
		if (al[i] == 1 && tr[i] <= 0) start[pv[i] + 1]++;
	for (int p = 0; p < pc; p++) start[p + 1] += start[p];
	list.resize(start[pc]);
	std::vector<int32_t> fill(start.begin(), start.end());
	for (int64_t i = 0; i < n; i++)
		if (al[i] == 1 && tr[i] <= 0) list[fill[pv[i]]++] = int32_t(i);
	PackedInt32Array cleared, attackers, movers;
	for (int64_t i = 0; i < n; i++) {
		const int32_t t = nx[i];
		if (t < 0 || tr[i] > 0) continue;
		const int32_t o = ow[i];
		const int32_t c = ct[t];
		if (ld[t] == 0 || (c != o && (c < 0 || o < 0 || c == o || wr[int64_t(o) * nc + c] == 0))) {
			cleared.push_back(int32_t(i));
			nx[i] = -1;
			pg[i] = 0.0;
			continue;
		}
		bool hostile = false;
		for (int32_t k = start[t]; k < start[t + 1]; k++) {
			const int32_t e = ow[list[k]];
			if (o >= 0 && e >= 0 && e != o && wr[int64_t(o) * nc + e] == 1) { hostile = true; break; }
		}
		if (hostile) {
			attackers.push_back(int32_t(i));
			continue;
		}
		movers.push_back(int32_t(i));
		const double speed = sd[i] * double(mm[t]);
		const double org_factor = 0.5 + 0.5 * clampd(og[i] / maxd(1.0, mo[i]), 0.0, 1.0);
		pg[i] = pg[i] + speed * org_factor * (0.5 + 0.5 * su[i]);
	}
	Array r;
	r.push_back(prog);
	r.push_back(next);
	r.push_back(cleared);
	r.push_back(attackers);
	r.push_back(movers);
	return r;
}

Array MeowqCore::snapshot(const PackedInt32Array &next, const PackedByteArray &battle, const PackedInt32Array &transit,
		const PackedInt32Array &resv, const PackedInt32Array &inv, const PackedFloat64Array &str,
		const PackedFloat64Array &org, const PackedFloat64Array &morg, const PackedFloat64Array &atk,
		const PackedFloat64Array &eq, const PackedFloat64Array &sup, const PackedInt32Array &prov,
		int prov_count, int day, const PackedFloat64Array &def, const PackedFloat64Array &ent,
		const PackedFloat64Array &plan, double plan_max) const {
	const int64_t n = next.size();
	PackedInt32Array flags, pd_start, pd_list;
	PackedFloat32Array o_str, o_org, o_pow, o_defw;
	flags.resize(n);
	o_str.resize(n);
	o_org.resize(n);
	o_pow.resize(n);
	o_defw.resize(n);
	pd_start.resize(prov_count + 1);
	int32_t *fl = flags.ptrw(), *ps = pd_start.ptrw();
	float *fs = o_str.ptrw(), *fo = o_org.ptrw(), *fp = o_pow.ptrw(), *fd = o_defw.ptrw();
	const int32_t *nx = next.ptr(), *tr = transit.ptr(), *rv = resv.ptr(), *iv = inv.ptr(), *pv = prov.ptr();
	const uint8_t *bt = battle.ptr();
	const double *st = str.ptr(), *og = org.ptr(), *mo = morg.ptr(), *at = atk.ptr(), *e = eq.ptr(), *su = sup.ptr();
	const double *df = def.ptr(), *en = ent.ptr(), *pl0 = plan.ptr();
	for (int p = 0; p <= prov_count; p++) ps[p] = 0;
	for (int64_t i = 0; i < n; i++) {
		int f = 0;
		if (nx[i] < 0 && bt[i] == 0 && tr[i] <= 0 && rv[i] < day && iv[i] < 0) f |= 1;
		if (bt[i] != 0) f |= 2;
		if (tr[i] > 0) f |= 4;
		fl[i] = f;
		const double s = st[i];
		fs[i] = float(s);
		const double orgf = clampd(og[i] / maxd(1.0, mo[i]), 0.0, 1.0);
		fo[i] = float(orgf);
		// как в бою: атака с планированием (×0,5 там — только у десанта); оборона с окопами и организацией (как world.gd)
		const double eqf = (0.4 + 0.6 * e[i]) * sup_mult(su[i]);
		fp[i] = float(s / 100.0 * at[i] * (1.0 + plan_max * pl0[i]) * eqf);
		fd[i] = float(s / 100.0 * df[i] * (1.0 + 0.3 * en[i]) * orgf * eqf);
		if (tr[i] <= 0) ps[pv[i] + 1]++;
	}
	for (int p = 0; p < prov_count; p++) ps[p + 1] += ps[p];
	pd_list.resize(ps[prov_count]);
	int32_t *pl = pd_list.ptrw();
	std::vector<int32_t> fill(ps, ps + prov_count + 1);
	for (int64_t i = 0; i < n; i++)
		if ((fl[i] & 4) == 0) pl[fill[pv[i]]++] = int32_t(i);
	Array r;
	r.push_back(flags);
	r.push_back(o_str);
	r.push_back(o_org);
	r.push_back(o_pow);
	r.push_back(o_defw);
	r.push_back(pd_start);
	r.push_back(pd_list);
	return r;
}

Array MeowqCore::relink(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedInt32Array &prov,
		const PackedInt32Array &owner, int prov_count, int nation_count) const {
	PackedInt32Array head, tail, nx, pv, counts;
	PackedByteArray inl;
	const int64_t n = alive.size();
	head.resize(prov_count);
	tail.resize(prov_count);
	nx.resize(n);
	pv.resize(n);
	inl.resize(n);
	counts.resize(nation_count);
	int32_t *h = head.ptrw(), *t = tail.ptrw(), *x = nx.ptrw(), *v = pv.ptrw(), *c = counts.ptrw();
	uint8_t *l = inl.ptrw();
	for (int p = 0; p < prov_count; p++) h[p] = t[p] = -1;
	for (int k = 0; k < nation_count; k++) c[k] = 0;
	const uint8_t *al = alive.ptr();
	const int32_t *tr = transit.ptr(), *pr = prov.ptr(), *ow = owner.ptr();
	for (int64_t i = 0; i < n; i++) {
		c[ow[i]] += 1;
		x[i] = -1;
		v[i] = -1;
		l[i] = 0;
		if (al[i] == 1 && tr[i] <= 0) {
			const int32_t p = pr[i];
			v[i] = t[p];
			if (t[p] >= 0) x[t[p]] = int32_t(i);
			else h[p] = int32_t(i);
			t[p] = int32_t(i);
			l[i] = 1;
		}
	}
	Array r;
	r.push_back(head);
	r.push_back(tail);
	r.push_back(nx);
	r.push_back(pv);
	r.push_back(inl);
	r.push_back(counts);
	return r;
}

// --- Поиск по морю и по своей территории (Forces/Diplomacy) ---------------------

PackedInt32Array MeowqCore::sea_bfs(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &land, int from) const {
	const int n = int(land.size());
	PackedInt32Array out;
	out.resize(n);
	int32_t *dist = out.ptrw();
	for (int i = 0; i < n; i++) dist[i] = -1;
	if (from < 0 || from >= n) return out;
	const int32_t *as = adj_start.ptr(), *al = adj_list.ptr();
	const uint8_t *ld = land.ptr();
	std::vector<int32_t> queue;
	queue.reserve(256);
	dist[from] = 0;
	queue.push_back(from);
	for (size_t head = 0; head < queue.size(); head++) {
		const int32_t p = queue[head];
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] == 0 && dist[q] < 0) {
				dist[q] = dist[p] + 1;
				queue.push_back(q);
			}
		}
	}
	return out;
}

PackedInt32Array MeowqCore::sea_path(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &land, int from, int to) const {
	PackedInt32Array path;
	const int n = int(land.size());
	if (from == to || from < 0 || to < 0 || from >= n || to >= n) return path;
	const int32_t *as = adj_start.ptr(), *al = adj_list.ptr();
	const uint8_t *ld = land.ptr();
	std::vector<int32_t> parent(n, -1), queue;
	parent[from] = from;
	queue.push_back(from);
	for (size_t head = 0; head < queue.size(); head++) {
		const int32_t p = queue[head];
		if (p == to) break;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] == 0 && parent[q] < 0) {
				parent[q] = p;
				queue.push_back(q);
			}
		}
	}
	if (parent[to] < 0) return path;
	int len = 0;
	for (int32_t cur = to; cur != from; cur = parent[cur]) len++;
	path.resize(len);
	int32_t *w = path.ptrw();
	for (int32_t cur = to; cur != from; cur = parent[cur]) w[--len] = cur;
	return path;
}

// Своя территория, связанная с start по суше (start входит всегда) (обход стеком, как в GDScript),
// и соседи-страны в порядке первой встречи. [маска, соседи].
Array MeowqCore::own_reach(const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &land, const PackedInt32Array &ctrl, int n, int start, int nation_count) const {
	const int pc = int(land.size());
	PackedByteArray mask;
	mask.resize(pc);
	uint8_t *m = mask.ptrw();
	for (int i = 0; i < pc; i++) m[i] = 0;
	PackedInt32Array neigh;
	Array r;
	if (start < 0 || start >= pc) {
		r.push_back(mask);
		r.push_back(neigh);
		return r;
	}
	const int32_t *as = adj_start.ptr(), *al = adj_list.ptr(), *ct = ctrl.ptr();
	const uint8_t *ld = land.ptr();
	std::vector<char> seen_n(nation_count, 0);
	std::vector<int32_t> stack{ start };
	m[start] = 1;
	while (!stack.empty()) {
		const int32_t p = stack.back();
		stack.pop_back();
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] == 0) continue;
			const int32_t c = ct[q];
			if (c == n) {
				if (!m[q]) {
					m[q] = 1;
					stack.push_back(q);
				}
			} else if (c >= 0 && !seen_n[c]) {
				seen_n[c] = 1;
				neigh.push_back(c);
			}
		}
	}
	r.push_back(mask);
	r.push_back(neigh);
	return r;
}

// Лучшая провинция под новый завод (Simulation._place_factory): своя и под
// контролем, есть свободный слот (по населению), меньше заводов, город — плюс.
int MeowqCore::place_factory(const PackedInt32Array &owner, const PackedInt32Array &ctrl, const PackedInt32Array &civ,
		const PackedInt32Array &mil, const PackedInt32Array &pop, const PackedByteArray &terrain, int nid,
		int max_factories, int t_urban) const {
	const int64_t pc = owner.size();
	const int32_t *ow = owner.ptr(), *ct = ctrl.ptr(), *cv = civ.ptr(), *ml = mil.ptr(), *pp = pop.ptr();
	const uint8_t *tr = terrain.ptr();
	const int64_t np = pop.size();
	int best = -1;
	double best_score = INFINITY;
	for (int64_t p = 0; p < pc; p++) {
		if (ow[p] != nid || ct[p] != nid) continue;
		const int total = cv[p] + ml[p];
		const int ps = p < np ? pp[p] : 0;
		const int slots = ps <= 0 ? max_factories : std::min(std::max(1 + ps / 250, 1), max_factories);
		if (total >= slots) continue;
		const double score = double(total) - (tr[p] == t_urban ? 2.0 : 0.0) + double(p % 7) * 0.01;
		if (score < best_score) {
			best_score = score;
			best = int(p);
		}
	}
	return best;
}

// --- Бои (World.k_combat) ---------------------------------------------------------

namespace {
struct SidePower {
	double power, hard;
};
}

static SidePower side_power(const int32_t *slots, const double *part, int64_t count, int terr, bool defending, const double *str,
		const double *def, const double *ent, const double *atk, const uint8_t *landing, const double *eq,
		const double *sup, const int32_t *tpl, const double *hard, const float *tmul, std::vector<double> &pw) {
	double power = 0.0, hd = 0.0, wsum = 0.0;
	pw.clear();
	for (int64_t k = 0; k < count; k++) {
		const int32_t i = slots[k];
		const double w = str[i] / 100.0 * part[k];
		const double base = defending ? def[i] * (1.0 + 0.3 * ent[i]) : atk[i] * (landing[i] == 1 ? 0.5 : 1.0);
		const double c = base * w * (0.4 + 0.6 * eq[i]) * sup_mult(sup[i]) * double(tmul[tpl[i] * 8 + terr]);
		pw.push_back(c);
		power += c;
		hd += hard[i] * w;
		wsum += w;
	}
	return { power, hd / maxd(wsum, 0.01) };
}

Array MeowqCore::combat(const PackedInt32Array &provs, const PackedInt32Array &att_start, const PackedInt32Array &att_list,
		const PackedInt64Array &seeds, const PackedFloat64Array &str_in, const PackedFloat64Array &org_in,
		const PackedFloat64Array &eq_in, const PackedFloat64Array &def, const PackedFloat64Array &atk,
		const PackedFloat64Array &ent, const PackedByteArray &landing, const PackedFloat64Array &sup,
		const PackedInt32Array &tpl, const PackedFloat64Array &hard, const PackedInt32Array &owner,
		const PackedByteArray &battle_in, const PackedInt32Array &pl_head, const PackedInt32Array &d_nx,
		const PackedByteArray &war, int nc, const PackedFloat32Array &def_mult, const PackedByteArray &terrain,
		const PackedInt32Array &region, const PackedFloat32Array &cas, const PackedFloat32Array &tmul,
		const PackedInt32Array &prov, const PackedFloat32Array &tpl_width, const PackedFloat32Array &fw,
		const PackedFloat64Array &armor, const PackedFloat64Array &pierce, double armor_cut) const {
	PackedFloat64Array str = str_in, org = org_in, eq = eq_in;
	const double *arm = armor.ptr(), *prc = pierce.ptr();
	std::vector<double> pa, pd;
	// броня (как World._pierced): вклад дивизии без пробития брони цели — × armor_cut
	auto pierced = [&](const std::vector<double> &pw, const std::vector<int32_t> &slots, double a) {
		double sum = 0.0;
		for (size_t k = 0; k < slots.size(); k++) sum += pw[k] * (prc[slots[k]] < a ? armor_cut : 1.0);
		return sum;
	};
	PackedByteArray battle = battle_in;
	const double *s0 = str_in.ptr(), *e0 = eq_in.ptr();
	const double *df = def.ptr(), *at = atk.ptr(), *en = ent.ptr(), *su = sup.ptr(), *hd = hard.ptr();
	const uint8_t *ld = landing.ptr(), *wr = war.ptr(), *tr = terrain.ptr();
	const int32_t *tp = tpl.ptr(), *ow = owner.ptr(), *ph = pl_head.ptr(), *nx = d_nx.ptr(), *rg = region.ptr();
	const int32_t *as = att_start.ptr(), *al = att_list.ptr();
	const float *dm = def_mult.ptr(), *cm = cas.ptr(), *tm = tmul.ptr();
	struct Delta {
		int32_t slot;
		double org, str;
	};
	std::vector<Delta> deltas;
	std::vector<int32_t> defenders, attackers, src;
	const int32_t *pr = prov.ptr();
	const float *tw = tpl_width.ptr(), *fwp = fw.ptr();
	const double *og = org_in.ptr();
	// ширина фронта (World.front_pick): свежие первыми, при равенстве — по номеру
	std::vector<double> aw, dw;
	auto pick = [&](std::vector<int32_t> &v, std::vector<double> &part, double limit) {
		std::sort(v.begin(), v.end(), [&](int32_t a, int32_t b) { return og[a] > og[b] || (og[a] == og[b] && a < b); });
		size_t n = 0;
		double used = 0.0;
		part.clear();
		for (int32_t i : v) {
			const double w = double(tw[tp[i]]);
			if (n == 0 || used + w <= limit) {
				v[n++] = i;
				part.push_back(1.0);
				used += w;
			} else {
				if (limit - used > 0.0) {
					v[n++] = i;
					part.push_back((limit - used) / w);
				}
				break;
			}
		}
		v.resize(n);
	};
	auto wsum = [](const std::vector<double> &w) {
		double s = 0.0;
		for (double x : w) s += x;
		return s;
	};
	Ref<RandomNumberGenerator> rng;
	rng.instantiate();
	for (int64_t b = 0; b < provs.size(); b++) {
		const int32_t p = provs[b];
		const int32_t a0 = as[b], a1 = as[b + 1];
		const int32_t att_owner = ow[al[a0]];
		defenders.clear();
		for (int32_t h = ph[p]; h >= 0; h = nx[h]) {
			const int32_t eo = ow[h];
			if (att_owner >= 0 && eo >= 0 && att_owner != eo && wr[int64_t(att_owner) * nc + eo] == 1) defenders.push_back(h);
		}
		if (defenders.empty()) continue;
		rng->set_seed(uint64_t(seeds[b]));
		const double terrain_def = double(dm[p]);
		const int terr = tr[p];
		attackers.assign(al + a0, al + a1);
		src.clear();
		for (int32_t i : attackers)
			if (std::find(src.begin(), src.end(), pr[i]) == src.end()) src.push_back(pr[i]);
		const int dirs = std::min(int(src.size()), int(fwp[9]));
		const double limit = double(fwp[terr]) + double(fwp[8]) * double(dirs - 1);
		for (int32_t e : defenders) deltas.push_back({ e, 0.0, 0.0 });   // резерв — тоже в бою
		for (int32_t e : attackers) deltas.push_back({ e, 0.0, 0.0 });
		pick(attackers, aw, limit);
		pick(defenders, dw, limit);
		const SidePower sa = side_power(attackers.data(), aw.data(), int64_t(attackers.size()), terr, false, s0, df, en, at, ld, e0, su, tp, hd, tm, pa);
		const SidePower sd = side_power(defenders.data(), dw.data(), int64_t(defenders.size()), terr, true, s0, df, en, at, ld, e0, su, tp, hd, tm, pd);
		const int32_t reg = rg[p];
		const double cas_a = double(cm[int64_t(reg) * nc + att_owner]);
		const double cas_d = double(cm[int64_t(reg) * nc + ow[defenders[0]]]);
		const double att_hard = sa.hard;
		const double def_hard = sd.hard;
		const double r1 = double(rng->randf_range(0.8, 1.2));
		const double r2 = double(rng->randf_range(0.8, 1.2));
		const double wd = wsum(dw), wa = wsum(aw);
		for (size_t j = 0; j < defenders.size(); j++) {
			double att_power = pierced(pa, attackers, arm[defenders[j]]) * cas_a;
			att_power *= r1 * (1.0 - terrain_def * 0.6);
			att_power *= 1.0 - def_hard * 0.6 * (1.0 - att_hard);
			const double to_def = att_power / wd;
			deltas.push_back({ defenders[j], to_def * dw[j] * 0.55, to_def * dw[j] * 0.12 * (su[defenders[j]] < SUP_EXH ? EXH_LOSS : 1.0) });
		}
		for (size_t j = 0; j < attackers.size(); j++) {
			double def_power = pierced(pd, defenders, arm[attackers[j]]) * cas_d;
			def_power *= r2;
			def_power *= 1.0 - att_hard * 0.6 * (1.0 - def_hard);
			const double to_att = def_power / wa;
			deltas.push_back({ attackers[j], to_att * aw[j] * 0.5, to_att * aw[j] * 0.10 * (su[attackers[j]] < SUP_EXH ? EXH_LOSS : 1.0) });
		}
	}
	double *o = org.ptrw(), *s = str.ptrw(), *q = eq.ptrw();
	uint8_t *bt = battle.ptrw();
	for (const Delta &d : deltas) {
		bt[d.slot] = 1;
		o[d.slot] = maxd(0.0, o[d.slot] - d.org);
		s[d.slot] = maxd(0.0, s[d.slot] - d.str);
		q[d.slot] = maxd(0.0, q[d.slot] - d.str / 100.0 * 0.9);
	}
	Array r;
	r.push_back(org);
	r.push_back(str);
	r.push_back(eq);
	r.push_back(battle);
	return r;
}

// Доход стран за день (World.compute_all_income): [гражд., воен., призывники,
// провинций] подряд по странам; чужие провинции — половина заводов, пятая часть людей.
PackedInt32Array MeowqCore::income(const PackedInt32Array &ctrl, const PackedInt32Array &owner,
		const PackedInt32Array &civ, const PackedInt32Array &mil, const PackedInt32Array &manpower, int nc) const {
	PackedInt32Array r;
	r.resize(int64_t(nc) * 4);
	int32_t *o = r.ptrw();
	for (int64_t i = 0; i < int64_t(nc) * 4; i++) o[i] = 0;
	const int32_t *ct = ctrl.ptr(), *ow = owner.ptr(), *cv = civ.ptr(), *ml = mil.ptr(), *mp = manpower.ptr();
	for (int64_t p = 0; p < ctrl.size(); p++) {
		const int32_t c = ct[p];
		if (c < 0) continue;
		int32_t *x = o + int64_t(c) * 4;
		x[3] += 1;
		if (ow[p] == c) {
			x[0] += cv[p];
			x[1] += ml[p];
			x[2] += mp[p];
		} else {
			x[0] += cv[p] / 2;
			x[1] += ml[p] / 2;
			x[2] += mp[p] / 5;
		}
	}
	return r;
}

// Районы фронта страны n (Forces.ai_air): для каждой своей провинции, у
// которой есть сосед-противник, +1 её воздушному району. Районы — в порядке
// первой встречи, затем число провинций: [r0, c0, r1, c1, ...].
PackedInt32Array MeowqCore::front_regions(const PackedInt32Array &ctrl, const PackedInt32Array &adj_start,
		const PackedInt32Array &adj_list, const PackedByteArray &war, int nc, const PackedInt32Array &region, int n) const {
	const int64_t pc = ctrl.size();
	const int32_t *ct = ctrl.ptr(), *as = adj_start.ptr(), *al = adj_list.ptr(), *rg = region.ptr();
	const uint8_t *wr = war.ptr() + int64_t(n) * nc;
	std::vector<int32_t> order;
	std::vector<int32_t> cnt;
	std::vector<int32_t> slot;
	for (int64_t p = 0; p < pc; p++) {
		if (ct[p] != n) continue;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t c = ct[al[k]];
			if (c >= 0 && c != n && wr[c] == 1) {
				const int32_t r = rg[p];
				if (r >= int32_t(slot.size())) slot.resize(r + 1, -1);
				if (slot[r] < 0) {
					slot[r] = int32_t(order.size());
					order.push_back(r);
					cnt.push_back(0);
				}
				cnt[slot[r]] += 1;
				break;
			}
		}
	}
	PackedInt32Array out;
	for (size_t i = 0; i < order.size(); i++) {
		out.push_back(order[i]);
		out.push_back(cnt[i]);
	}
	return out;
}

// Порты, у которых есть соседняя морская зона без флотов (там блокады нет).
PackedByteArray MeowqCore::ports_open(const PackedInt32Array &ports, const PackedInt32Array &adj_start,
		const PackedInt32Array &adj_list, const PackedByteArray &land, const PackedByteArray &zone_has_fleet) const {
	PackedByteArray out;
	out.resize(ports.size());
	uint8_t *o = out.ptrw();
	const int32_t *as = adj_start.ptr(), *al = adj_list.ptr();
	const uint8_t *ld = land.ptr(), *zf = zone_has_fleet.ptr();
	for (int64_t i = 0; i < ports.size(); i++) {
		const int32_t p = ports[i];
		o[i] = 0;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] == 0 && zf[q] == 0) {
				o[i] = 1;
				break;
			}
		}
	}
	return out;
}

// Воздушные районы в радиусе действия авиации стороны страны (Forces._regions_in_range):
// маска по районам. Расстояние — Vector2::distance_to (float), как в GDScript.
PackedByteArray MeowqCore::air_reach(const PackedByteArray &land, const PackedInt32Array &ctrl, const PackedByteArray &ally,
		int nc, int n, const PackedInt32Array &region, const PackedVector2Array &centers, double range) const {
	const int64_t pc = ctrl.size();
	const int64_t rc = centers.size();
	std::vector<char> own(rc, 0);
	std::vector<int32_t> own_list;
	const uint8_t *ld = land.ptr(), *al = ally.ptr() + int64_t(n) * nc;
	const int32_t *ct = ctrl.ptr(), *rg = region.ptr();
	for (int64_t p = 0; p < pc; p++) {
		const int32_t o = ct[p];
		if (ld[p] == 1 && o >= 0 && al[o] == 1) {
			const int32_t r = rg[p];
			if (r >= 0 && r < rc && !own[r]) {
				own[r] = 1;
				own_list.push_back(r);
			}
		}
	}
	PackedByteArray out;
	out.resize(rc);
	uint8_t *o = out.ptrw();
	const Vector2 *c = centers.ptr();
	const real_t rr = real_t(range);
	for (int64_t r = 0; r < rc; r++) {
		o[r] = 0;
		for (int32_t q : own_list) {
			if (c[q].distance_to(c[r]) <= rr) {
				o[r] = 1;
				break;
			}
		}
	}
	return out;
}

Array MeowqCore::counters(const PackedInt32Array &head, const PackedInt32Array &nx, const PackedByteArray &alive,
		const PackedInt32Array &owner, const PackedFloat64Array &str, const PackedFloat64Array &org,
		const PackedFloat64Array &morg, const PackedFloat64Array &sup, const PackedInt32Array &tpl) const {
	PackedInt32Array o_prov, o_owner, o_n, o_tpl;
	PackedFloat64Array o_str, o_org, o_sup;
	const int32_t *hd = head.ptr(), *x = nx.ptr(), *ow = owner.ptr(), *tp = tpl.ptr();
	const uint8_t *al = alive.ptr();
	const double *st = str.ptr(), *og = org.ptr(), *mo = morg.ptr(), *su = sup.ptr();
	const int64_t pc = head.size();
	// стопки одной провинции — небольшой локальный набор
	int32_t g_owner[64], g_n[64], g_tc[64][8];
	double g_str[64], g_org[64], g_sup[64];
	for (int64_t p = 0; p < pc; p++) {
		int32_t h = hd[p];
		if (h < 0) continue;
		int gn = 0;
		while (h >= 0) {
			if (al[h] != 0) {
				const int32_t o = ow[h];
				int k = 0;
				while (k < gn && g_owner[k] != o) k++;
				if (k == gn) {
					if (gn == 64) { h = x[h]; continue; }
					g_owner[k] = o;
					g_n[k] = 0;
					g_str[k] = 0.0;
					g_org[k] = 0.0;
					g_sup[k] = 1.0;
					for (int t = 0; t < 8; t++) g_tc[k][t] = 0;
					gn++;
				}
				g_n[k] += 1;
				g_str[k] += st[h];
				g_org[k] += og[h] / (mo[h] > 1.0 ? mo[h] : 1.0);
				if (su[h] < g_sup[k]) g_sup[k] = su[h];
				int t = tp[h];
				t = t < 0 ? 0 : (t > 7 ? 7 : t);
				g_tc[k][t] += 1;
			}
			h = x[h];
		}
		for (int k = 0; k < gn; k++) {
			int main_t = 0;
			for (int t = 1; t < 8; t++) if (g_tc[k][t] > g_tc[k][main_t]) main_t = t;
			o_prov.push_back(int32_t(p));
			o_owner.push_back(g_owner[k]);
			o_n.push_back(g_n[k]);
			o_tpl.push_back(main_t);
			o_str.push_back(g_str[k]);
			o_org.push_back(g_org[k]);
			o_sup.push_back(g_sup[k]);
		}
	}
	Array r;
	r.push_back(o_prov);
	r.push_back(o_owner);
	r.push_back(o_n);
	r.push_back(o_tpl);
	r.push_back(o_str);
	r.push_back(o_org);
	r.push_back(o_sup);
	return r;
}

PackedFloat64Array MeowqCore::label_regions(const PackedInt32Array &ctrl, const PackedByteArray &land,
		const PackedInt32Array &adj_start, const PackedInt32Array &adj_list, const PackedInt32Array &pixels,
		const PackedVector2Array &centers, const PackedInt32Array &caps) const {
	const int64_t pc = ctrl.size();
	const int64_t nc = caps.size();
	PackedFloat64Array out;
	out.resize(nc * 8);
	double *o = out.ptrw();
	for (int64_t i = 0; i < nc * 8; i++) o[i] = 0.0;
	std::vector<int64_t> best_score(nc, -1);
	std::vector<int32_t> comp(pc, -1);
	std::vector<int32_t> stack;
	const int32_t *ct = ctrl.ptr(), *as = adj_start.ptr(), *al = adj_list.ptr(), *px = pixels.ptr(), *cp = caps.ptr();
	const uint8_t *ld = land.ptr();
	const Vector2 *ce = centers.ptr();
	for (int64_t p = 0; p < pc; p++) {
		const int32_t c = ct[p];
		if (c < 0 || c >= nc || ld[p] == 0 || comp[p] >= 0) continue;
		comp[p] = int32_t(p);
		stack.clear();
		stack.push_back(int32_t(p));
		int64_t n = 0;
		double sx = 0.0, sy = 0.0;
		double lx = 1e30, ly = 1e30, hx = -1e30, hy = -1e30;
		bool has_cap = false;
		while (!stack.empty()) {
			const int32_t q = stack.back();
			stack.pop_back();
			if (q == cp[c]) has_cap = true;
			const double w = px[q];
			n += px[q];
			sx += ce[q].x * w;
			sy += ce[q].y * w;
			lx = std::min(lx, double(ce[q].x));
			ly = std::min(ly, double(ce[q].y));
			hx = std::max(hx, double(ce[q].x));
			hy = std::max(hy, double(ce[q].y));
			for (int32_t k = as[q]; k < as[q + 1]; k++) {
				const int32_t r = al[k];
				if (comp[r] < 0 && ld[r] == 1 && ct[r] == c) {
					comp[r] = int32_t(p);
					stack.push_back(r);
				}
			}
		}
		const int64_t score = n + (has_cap ? (int64_t(1) << 30) : 0);
		if (score > best_score[c]) {
			best_score[c] = score;
			double *b = o + c * 8;
			b[0] = double(n);
			b[1] = sx;
			b[2] = sy;
			b[3] = lx;
			b[4] = ly;
			b[5] = hx;
			b[6] = hy;
			b[7] = 1.0;
		}
	}
	return out;
}

// Итоги проверки капитуляций — двойник цикла в Simulation._check_capitulation.
PackedInt32Array MeowqCore::cap_totals(const PackedInt32Array &owner, const PackedInt32Array &ctrl,
		const PackedInt32Array &vp, const PackedInt32Array &side, int nc) const {
	PackedInt32Array res;
	res.resize(int64_t(nc) * 3);
	int32_t *out = res.ptrw();
	for (int64_t k = 0; k < int64_t(nc) * 3; k++) out[k] = 0;
	const int64_t pc = owner.size();
	const int32_t *ow = owner.ptr(), *ct = ctrl.ptr(), *v = vp.ptr(), *sd = side.ptr();
	for (int64_t p = 0; p < pc; p++) {
		const int32_t o = ow[p];
		if (o < 0) continue;
		const int32_t c = ct[p];
		if (c == o) out[2 * nc + o] += 1;
		if (v[p] == 0) continue;
		out[o] += v[p];
		if (c == o || (c >= 0 && (sd[c * 2] == sd[o * 2] || (sd[c * 2 + 1] >= 0 && sd[c * 2 + 1] == sd[o * 2 + 1])))) {
			out[nc + o] += v[p];
		}
	}
	return res;
}

// Узлы снабжения из портов — двойник Simulation._phase_supply/_blockaded/_zone_supremacy.
PackedByteArray MeowqCore::ports_hub(const PackedInt32Array &ports, const PackedInt32Array &ctrl,
		const PackedInt32Array &adj_start, const PackedInt32Array &adj_list, const PackedByteArray &land,
		const PackedByteArray &zone_has_fleet, const PackedInt32Array &zidx, const PackedInt32Array &zoff,
		const PackedInt32Array &zown, const PackedFloat64Array &zpow, const PackedByteArray &ally,
		const PackedByteArray &war, int nc, bool any_fleets) const {
	PackedByteArray out;
	out.resize(ports.size());
	uint8_t *o = out.ptrw();
	const int32_t *as = adj_start.ptr(), *al = adj_list.ptr(), *ct = ctrl.ptr();
	const int32_t *zi = zidx.ptr(), *zo = zoff.ptr(), *zw = zown.ptr();
	const double *zp = zpow.ptr();
	const uint8_t *ld = land.ptr(), *zf = zone_has_fleet.ptr(), *al2 = ally.ptr(), *wr = war.ptr();
	for (int64_t i = 0; i < ports.size(); i++) {
		const int32_t p = ports[i];
		const int32_t c = ct[p];
		o[i] = 0;
		if (c < 0) continue;
		bool open_sea = false;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] == 0 && zf[q] == 0) {
				open_sea = true;
				break;
			}
		}
		if (open_sea || !any_fleets) {
			o[i] = 1;
			continue;
		}
		// _blockaded: блокирован, если есть соседнее море и ни в одной зоне господство < 0,3
		bool any = false, free_zone = false;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			if (ld[q] != 0) continue;
			any = true;
			double mine = 0.0, enemy = 0.0;
			const int32_t z = zi[q];
			if (z >= 0) {
				for (int32_t j = zo[z]; j < zo[z + 1]; j++) {
					const int32_t ow = zw[j];
					if (al2[int64_t(c) * nc + ow] == 1) mine += zp[j];
					else if (c != ow && ow >= 0 && wr[int64_t(c) * nc + ow] == 1) enemy += zp[j];
				}
			}
			const double sup = mine + enemy <= 0.0 ? 0.5 : mine / (mine + enemy);
			if (sup >= 0.3) {
				free_zone = true;
				break;
			}
		}
		o[i] = (free_zone || !any) ? 1 : 0;
	}
	return out;
}

// --- Акклиматизация (Climate.kernel_gd — двойник) ---------------------------------
Array MeowqCore::climate(const Dictionary &t) const {
	const PackedByteArray alive_a = t["alive"];
	const PackedInt32Array transit_a = t["transit"], prov_a = t["prov"], owner_a = t["owner"];
	PackedFloat64Array st_a = t["str"], ah_a = t["acl_hot"], ac_a = t["acl_cold"];
	st_a = st_a.duplicate();
	ah_a = ah_a.duplicate();
	ac_a = ac_a.duplicate();
	const PackedFloat64Array spd_a = t["spd"], atk_a = t["atk"], def_a = t["def"], nh_a = t["n_hot"], nc_a = t["n_cold"], k_a = t["k"];
	const PackedFloat32Array ph_a = t["p_hot"], pc_a = t["p_cold"];
	const uint8_t *alive = alive_a.ptr();
	const int32_t *transit = transit_a.ptr(), *prov = prov_a.ptr(), *owner = owner_a.ptr();
	const double *spd = spd_a.ptr(), *atk = atk_a.ptr(), *def = def_a.ptr(), *nh = nh_a.ptr(), *ncd = nc_a.ptr();
	const float *ph = ph_a.ptr(), *pcd = pc_a.ptr();
	double *st = st_a.ptrw(), *ah = ah_a.ptrw(), *ac = ac_a.ptrw();
	const double gain = k_a[0], decay = k_a[1], spd_pen = k_a[2], cpen = k_a[3], attr = k_a[4], floor_s = k_a[5], bonus = k_a[6];
	const int64_t n = alive_a.size();
	PackedFloat64Array se_a, ae_a, de_a, cm_a;
	se_a.resize(n);
	ae_a.resize(n);
	de_a.resize(n);
	cm_a.resize(n);
	double *se = se_a.ptrw(), *ae = ae_a.ptrw(), *de = de_a.ptrw(), *cm = cm_a.ptrw();
	for (int64_t i = 0; i < n; i++) {
		se[i] = spd[i];
		ae[i] = atk[i];
		de[i] = def[i];
		cm[i] = 1.0;
		if (alive[i] == 0 || transit[i] > 0)
			continue;
		const int32_t p = prov[i], o = owner[i];
		const double hh = double(ph[p]), hc = double(pcd[p]);
		const double bh = mind(1.0, nh[o]), bc = mind(1.0, ncd[o]);
		if (hh > 0.0)
			ah[i] = mind(1.0, maxd(ah[i], bh) + gain * hh);
		else
			ah[i] = maxd(bh, ah[i] - decay);
		if (hc > 0.0)
			ac[i] = mind(1.0, maxd(ac[i], bc) + gain * hc);
		else
			ac[i] = maxd(bc, ac[i] - decay);
		const double u = mind(1.0, hh * (1.0 - ah[i]) + hc * (1.0 - ac[i]));
		const double b = mind(1.0, hh * clampd((nh[o] - 1.0) / 0.5, 0.0, 1.0) + hc * clampd((ncd[o] - 1.0) / 0.5, 0.0, 1.0));
		if (u <= 0.0 && b <= 0.0)
			continue;
		const double mult = (1.0 - cpen * u) * (1.0 + bonus * b);
		cm[i] = mult;
		se[i] = spd[i] * (1.0 - spd_pen * u);
		ae[i] = atk[i] * mult;
		de[i] = def[i] * mult;
		if (u > 0.0 && st[i] > floor_s)
			st[i] = maxd(floor_s, st[i] - attr * u);
	}
	Array r;
	r.push_back(ah_a);
	r.push_back(ac_a);
	r.push_back(st_a);
	r.push_back(se_a);
	r.push_back(ae_a);
	r.push_back(de_a);
	r.push_back(cm_a);
	return r;
}
