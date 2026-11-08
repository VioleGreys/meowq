// Ядра горячих фаз дня. Каждое повторяет World.k_* из scripts/sim/world.gd
// операция в операцию (double, тот же порядок обхода и вычислений): игра с
// библиотекой и без неё обязана считать одинаково (tests/sim_bench.gd).
#include "meowq_core.h"

#include <algorithm>
#include <vector>

using namespace godot;

static inline double clampd(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline double maxd(double a, double b) { return a > b ? a : b; }   // как maxf в Godot
static inline double mind(double a, double b) { return a < b ? a : b; }

Array MeowqCore::recovery(const PackedByteArray &alive, const PackedInt32Array &transit, const PackedFloat64Array &sup,
		const PackedFloat64Array &org_in, const PackedFloat64Array &morg, const PackedFloat64Array &str_in,
		const PackedFloat64Array &eq_in, const PackedFloat64Array &ent_in, const PackedInt32Array &next,
		const PackedByteArray &battle, const PackedInt32Array &owner, const PackedInt32Array &prov,
		const PackedInt32Array &tpl, const PackedInt32Array &ctrl, const PackedByteArray &ally, int nc,
		const PackedFloat32Array &stock_in, const PackedFloat64Array &manpower_in, const PackedFloat64Array &rbonus,
		const PackedFloat64Array &tpl_eq, const PackedFloat64Array &tpl_men) const {
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
		o_org[i] = mind(mo[i], o_org[i] + mo[i] * rate * (0.3 + 0.7 * s));
		const int32_t o = ow[i];
		const int32_t c = ct[pv[i]];
		if (c != o && ally_p[int64_t(o) * nc + c] != 1) continue;
		if (s < 0.3 || (o_eq[i] >= 1.0 && o_str[i] >= 100.0)) continue;
		const int32_t t = tp[i];
		const double rr = 0.04 * (1.0 + rb[o]) * s;
		if (o_eq[i] < 1.0) {
			double want = mind(1.0 - o_eq[i], rr);
			for (int k = 0; k < 7; k++) {
				const double e = te[t * 7 + k];
				if (e > 0) want = mind(want, double(st[o * 7 + k]) / e);
			}
			if (want > 0.0) {
				for (int k = 0; k < 7; k++) st[o * 7 + k] = float(double(st[o * 7 + k]) - te[t * 7 + k] * want);
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
		int prov_count, int day) const {
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
		fp[i] = float(s * (at[i] / 10.0) * (0.4 + 0.6 * e[i]) * (0.5 + 0.5 * su[i]));
		fd[i] = float(s * orgf * (0.4 + 0.6 * e[i]));
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
