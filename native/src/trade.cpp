// Морская блокада торговли (Economy.refresh_blockade, двойник на GDScript):
// округа флотов, открытые зоны каждой воюющей страны и недоступные ей
// продавцы. Операция в операцию как в GDScript (double; силы округи — в
// float32, как PackedFloat32Array), тот же порядок обходов.
#include "meowq_core.h"

#include <cmath>
#include <unordered_map>
#include <vector>

using namespace godot;

// t: nc, pc, land, adj_start, adj_list, war, ally, z_start/z_list (морские зоны у
// портов страны), tr_start/tr_list (транзит через соседей по суше), fr_owner/
// fr_zone/fr_pw (флоты с округой, по порядку), zf_start (pc + 1)/zf_owner/
// zf_alive/zf_port/zf_pw (флоты зон, World.zone_fleets), n_alive, n_war, n_cap,
// p_mass (пусто — нет), tm_keys/tm_start/tm_list (World.trade_mass), k:
// [BLOCK_RANGE, BLOCK_FALL, BLOCK_SHARE, BLOCK_OPEN].
// → [trade_block (nc*nc), страны с записью, начала, открытые зоны].
Array MeowqCore::blockade(const Dictionary &t) const {
	const int nc = int(t["nc"]), pc = int(t["pc"]);
	const PackedByteArray land_a = t["land"], war_a = t["war"], ally_a = t["ally"];
	const PackedInt32Array as_a = t["adj_start"], al_a = t["adj_list"];
	const PackedInt32Array zs_a = t["z_start"], zl_a = t["z_list"], ts_a = t["tr_start"], tl_a = t["tr_list"];
	const PackedInt32Array fro_a = t["fr_owner"], frz_a = t["fr_zone"];
	const PackedFloat64Array frp_a = t["fr_pw"];
	const PackedInt32Array zfs_a = t["zf_start"], zfo_a = t["zf_owner"];
	const PackedByteArray zfa_a = t["zf_alive"], zfp_a = t["zf_port"];
	const PackedFloat64Array zfw_a = t["zf_pw"];
	const PackedByteArray nal_a = t["n_alive"], nwar_a = t["n_war"];
	const PackedInt32Array ncap_a = t["n_cap"], mass_a = t["p_mass"];
	const PackedInt32Array tmk_a = t["tm_keys"], tms_a = t["tm_start"], tml_a = t["tm_list"];
	const PackedFloat64Array k_a = t["k"];
	const uint8_t *land = land_a.ptr(), *war = war_a.ptr(), *ally = ally_a.ptr();
	const int32_t *as = as_a.ptr(), *al = al_a.ptr();
	const int32_t *zst = zs_a.ptr(), *zli = zl_a.ptr(), *tst = ts_a.ptr(), *tli = tl_a.ptr();
	const int32_t *fro = fro_a.ptr(), *frz = frz_a.ptr();
	const double *frp = frp_a.ptr();
	const int32_t *zfs = zfs_a.ptr(), *zfo = zfo_a.ptr();
	const uint8_t *zfa = zfa_a.ptr(), *zfp = zfp_a.ptr();
	const double *zfw = zfw_a.ptr();
	const uint8_t *nal = nal_a.ptr(), *nwar = nwar_a.ptr();
	const int32_t *ncap = ncap_a.ptr();
	const bool has_mass = mass_a.size() == pc;
	const int32_t *mass = has_mass ? mass_a.ptr() : nullptr;
	const int32_t *tmk = tmk_a.ptr(), *tms = tms_a.ptr(), *tml = tml_a.ptr();
	const int range = int(k_a[0]);
	const double fall = k_a[1], share = k_a[2], open_k = k_a[3];

	PackedByteArray block;
	block.resize(int64_t(nc) * nc);
	uint8_t *blk = block.ptrw();
	for (int64_t i = 0; i < int64_t(nc) * nc; i++) blk[i] = 0;

	// округа флотов: зоны в пределах range и вес силы (float32, как ws)
	const int nf = int(fro_a.size());
	std::vector<int32_t> r_start(1, 0), r_zone;
	std::vector<float> r_w;
	std::vector<int32_t> dist(pc, -1);
	std::vector<int32_t> touched;
	for (int f = 0; f < nf; f++) {
		const double pw = frp[f];
		const size_t b0 = r_zone.size();
		r_zone.push_back(frz[f]);
		r_w.push_back(float(pw));
		dist[frz[f]] = 0;
		touched.clear();
		touched.push_back(frz[f]);
		for (size_t h = b0; h < r_zone.size(); h++) {
			const int32_t z = r_zone[h];
			const int32_t dz = dist[z];
			if (dz >= range) continue;
			for (int32_t k = as[z]; k < as[z + 1]; k++) {
				const int32_t q = al[k];
				if (land[q] == 0 && dist[q] < 0) {
					dist[q] = dz + 1;
					touched.push_back(q);
					r_zone.push_back(q);
					r_w.push_back(float(pw * std::pow(fall, double(dz + 1))));
				}
			}
		}
		for (int32_t z : touched) dist[z] = -1;
		r_start.push_back(int32_t(r_zone.size()));
	}

	// узлы «материк*N + страна» → индекс
	std::unordered_map<int32_t, int32_t> tm_idx;
	for (int i = 0; i < int(tmk_a.size()); i++) tm_idx[tmk[i]] = i;

	PackedInt32Array ob_n, ob_start, ob_list;
	ob_start.push_back(0);
	std::vector<float> own_r(pc), en_r(pc);
	std::vector<uint8_t> near(pc), seen(pc), open(pc), by_land(nc);
	std::vector<int32_t> qz;
	std::vector<uint8_t> seen_n;
	std::vector<int32_t> qn;
	for (int b = 0; b < nc; b++) {
		if (nal[b] == 0 || nwar[b] == 0) continue;
		const int64_t bb = int64_t(b) * nc;
		bool any_enemy = false;
		for (int f = 0; f < nf; f++) {
			if (war[bb + fro[f]] == 1) { any_enemy = true; break; }
		}
		if (!any_enemy) continue;
		std::fill(own_r.begin(), own_r.end(), 0.0f);
		std::fill(en_r.begin(), en_r.end(), 0.0f);
		for (int f = 0; f < nf; f++) {
			const int o = fro[f];
			if (war[bb + o] == 1) {
				for (int32_t i = r_start[f]; i < r_start[f + 1]; i++)
					en_r[r_zone[i]] = float(double(en_r[r_zone[i]]) + double(r_w[i]));
			} else if (ally[bb + o] == 1 || o == b) {
				for (int32_t i = r_start[f]; i < r_start[f + 1]; i++)
					own_r[r_zone[i]] = float(double(own_r[r_zone[i]]) + double(r_w[i]));
			}
		}
		// у своих и союзных берегов
		std::fill(near.begin(), near.end(), 0);
		for (int x = 0; x < nc; x++) {
			if (ally[bb + x] == 1 || x == b)
				for (int32_t i = zst[x]; i < zst[x + 1]; i++) near[zli[i]] = 1;
		}
		// по суше: страны на материке столицы через невоюющих с нами
		std::fill(by_land.begin(), by_land.end(), 0);
		by_land[b] = 1;
		const int cap = ncap[b];
		if (cap >= 0 && has_mass && mass[cap] >= 0) {
			const int32_t start = mass[cap] * nc + b;
			seen_n.assign(tmk_a.size(), 0);
			qn.clear();
			std::vector<int32_t> seen_extra;   // узлы без своей записи в trade_mass
			auto mark = [&](int32_t key) -> bool {
				auto it = tm_idx.find(key);
				if (it != tm_idx.end()) {
					if (seen_n[it->second]) return false;
					seen_n[it->second] = 1;
					return true;
				}
				for (int32_t s : seen_extra) if (s == key) return false;
				seen_extra.push_back(key);
				return true;
			};
			mark(start);
			qn.push_back(start);
			for (size_t h = 0; h < qn.size(); h++) {
				auto it = tm_idx.find(qn[h]);
				if (it == tm_idx.end()) continue;
				const int32_t ii = it->second;
				for (int32_t k = tms[ii]; k < tms[ii + 1]; k++) {
					const int32_t k2 = tml[k];
					const int y = k2 % nc;
					// порядок проверок как в GDScript: seen, война, жив
					{
						auto jt = tm_idx.find(k2);
						bool was = false;
						if (jt != tm_idx.end()) was = seen_n[jt->second] != 0;
						else for (int32_t s : seen_extra) if (s == k2) { was = true; break; }
						if (was || war[bb + y] == 1 || nal[y] == 0) continue;
					}
					mark(k2);
					by_land[y] = 1;
					qn.push_back(k2);
				}
			}
		}
		// по морю: зоны от наших портов без господства противника
		auto zone_open = [&](int z) -> bool {
			for (int32_t i = zfs[z]; i < zfs[z + 1]; i++) {
				if (zfa[i] == 1 && zfp[i] == 0 && war[bb + zfo[i]] == 1) {
					// Forces.supremacy(b, z)
					double mine = 0.0, enemy = 0.0;
					for (int32_t j = zfs[z]; j < zfs[z + 1]; j++) {
						if (zfp[j] == 1) continue;
						const int o = zfo[j];
						if (ally[bb + o] == 1) mine += zfw[j];
						else if (o != b && war[bb + o] == 1) enemy += zfw[j];
					}
					const double sup = (mine + enemy <= 0.0) ? 0.5 : mine / (mine + enemy);
					return sup >= share;
				}
			}
			if (near[z] == 1 || double(en_r[z]) <= 0.0) return true;
			return double(own_r[z]) / (double(own_r[z]) + double(en_r[z])) >= open_k;
		};
		std::fill(seen.begin(), seen.end(), 0);
		std::fill(open.begin(), open.end(), 0);
		qz.clear();
		for (int32_t i = zst[b]; i < zst[b + 1]; i++) {
			const int32_t z = zli[i];
			if (seen[z]) continue;
			seen[z] = 1;
			if (zone_open(z)) {
				open[z] = 1;
				qz.push_back(z);
			}
		}
		for (size_t h = 0; h < qz.size(); h++) {
			const int32_t z = qz[h];
			for (int32_t k = as[z]; k < as[z + 1]; k++) {
				const int32_t q = al[k];
				if (land[q] != 0 || seen[q]) continue;
				seen[q] = 1;
				if (zone_open(q)) {
					open[q] = 1;
					qz.push_back(q);
				}
			}
		}
		ob_n.push_back(b);
		for (int32_t z : qz) ob_list.push_back(z);
		ob_start.push_back(int32_t(ob_list.size()));
		for (int s = 0; s < nc; s++) {
			if (s == b || by_land[s] == 1 || war[bb + s] == 1 || nal[s] == 0) continue;
			bool ok = false;
			for (int32_t i = zst[s]; i < zst[s + 1] && !ok; i++)
				if (open[zli[i]]) ok = true;
			if (!ok) {
				for (int32_t j = tst[s]; j < tst[s + 1] && !ok; j++) {
					const int y = tli[j];
					if (war[bb + y] == 1 || nal[y] == 0) continue;
					for (int32_t i = zst[y]; i < zst[y + 1]; i++)
						if (open[zli[i]]) { ok = true; break; }
				}
			}
			if (!ok) blk[bb + s] = 1;
		}
	}
	Array res;
	res.push_back(block);
	res.push_back(ob_n);
	res.push_back(ob_start);
	res.push_back(ob_list);
	return res;
}


// Живые дивизии страны n по возрастанию слота (World.slots_of, двойник на GDScript).
PackedInt32Array MeowqCore::owner_slots(const PackedByteArray &alive, const PackedInt32Array &owner, int n) const {
	PackedInt32Array res;
	const int m = int(alive.size() < owner.size() ? alive.size() : owner.size());
	const uint8_t *al = alive.ptr();
	const int32_t *ow = owner.ptr();
	int k = 0;
	for (int i = 0; i < m; i++) if (al[i] == 1 && ow[i] == n) k++;
	res.resize(k);
	int32_t *r = res.ptrw();
	k = 0;
	for (int i = 0; i < m; i++) if (al[i] == 1 && ow[i] == n) r[k++] = i;
	return res;
}


// Дивизии не на участке метрополии (World.overseas_slots, двойник на GDScript):
// живые, с хозяином и провинцией, кроме стоящих на участке home[хозяина];
// и число живых с провинцией по странам. → [слоты, по странам].
Array MeowqCore::overseas_slots(const PackedByteArray &alive, const PackedInt32Array &prov, const PackedInt32Array &owner,
		const PackedInt32Array &comp, const PackedInt32Array &home, int nc) const {
	PackedInt32Array slots, total;
	total.resize(nc);
	int32_t *tot = total.ptrw();
	for (int i = 0; i < nc; i++) tot[i] = 0;
	const int m = int(alive.size());
	const uint8_t *al = alive.ptr();
	const int32_t *pv = prov.ptr(), *ow = owner.ptr(), *cm = comp.ptr(), *hm = home.ptr();
	std::vector<int32_t> out;
	for (int i = 0; i < m; i++) {
		if (al[i] == 0) continue;
		const int32_t p = pv[i], o = ow[i];
		if (p < 0 || o < 0) continue;
		if (o < nc) tot[o]++;
		const int32_t c = cm[p];
		if (c >= 0 && o < nc && c == hm[o]) continue;
		out.push_back(i);
	}
	slots.resize(int64_t(out.size()));
	int32_t *sl = slots.ptrw();
	for (size_t k = 0; k < out.size(); k++) sl[k] = out[k];
	Array r;
	r.push_back(slots);
	r.push_back(total);
	return r;
}


// Прорыв из котла (Simulation._breakouts, двойник на GDScript): обход по суше
// от своих провинций участка c (по возрастанию номера) до первой провинции
// участка home не дальше steps переходов. → [найденная (−1 — нет), откуда].
PackedInt32Array MeowqCore::breakout_bfs(const PackedInt32Array &comp, const PackedInt32Array &ctrl,
		const PackedByteArray &land, const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		int c, int nid, int home, int steps) const {
	const int pc = int(land.size());
	const int32_t *cm = comp.ptr(), *ct = ctrl.ptr(), *as = adj_start.ptr(), *al = adj_list.ptr();
	const uint8_t *ld = land.ptr();
	std::vector<int32_t> dist(pc, -1), origin(pc, -1), q;
	for (int p = 0; p < pc; p++) {
		if (cm[p] == c && ct[p] == nid) {
			dist[p] = 0;
			origin[p] = p;
			q.push_back(p);
		}
	}
	int found = -1;
	for (size_t h = 0; h < q.size() && found < 0; h++) {
		const int32_t p = q[h];
		if (dist[p] >= steps) continue;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t y = al[k];
			if (ld[y] == 0 || dist[y] >= 0) continue;
			dist[y] = dist[p] + 1;
			origin[y] = origin[p];
			if (cm[y] == home) {
				found = y;
				break;
			}
			q.push_back(y);
		}
	}
	PackedInt32Array r;
	r.push_back(found);
	r.push_back(found >= 0 ? origin[found] : -1);
	return r;
}


// Участки стороны страны n для экспедиций (Forces._exp_transfers, двойник на
// GDScript): по номеру участка — провинций, у фронта, вражеских дивизий у
// фронта (каждая вражеская провинция — один раз), ёмкость снабжения (сумма в
// double по возрастанию p, как в GDScript); порты стороны — [участок, у
// фронта, ёмкость, порт] по возрастанию p. → [size, front, foes, cap, порты i32, порты f64].
Array MeowqCore::exp_scan(const PackedInt32Array &comp, const PackedByteArray &land, const PackedInt32Array &ctrl,
		const PackedFloat32Array &supcap, const PackedInt32Array &adj_start, const PackedInt32Array &adj_list,
		const PackedByteArray &war, const PackedByteArray &ally, const PackedInt32Array &pl_head,
		const PackedInt32Array &d_nx, const PackedInt32Array &d_owner, const PackedByteArray &is_port, int n, int nc) const {
	const int pc = int(land.size());
	const int32_t *cm = comp.ptr(), *ct = ctrl.ptr(), *as = adj_start.ptr(), *al = adj_list.ptr();
	const int32_t *plh = pl_head.ptr(), *dnx = d_nx.ptr(), *dow = d_owner.ptr();
	const uint8_t *ld = land.ptr(), *wr = war.ptr(), *alw = ally.ptr(), *isp = is_port.ptr();
	const float *sc = supcap.ptr();
	const int nsup = int(supcap.size());
	int ncomp = 0;
	for (int p = 0; p < pc; p++) if (cm[p] + 1 > ncomp) ncomp = cm[p] + 1;
	PackedInt32Array a_size, a_front, a_foes, pi;
	PackedFloat64Array a_cap, pf;
	a_size.resize(ncomp); a_front.resize(ncomp); a_foes.resize(ncomp); a_cap.resize(ncomp);
	int32_t *sz = a_size.ptrw(), *fr = a_front.ptrw(), *fo = a_foes.ptrw();
	double *cp = a_cap.ptrw();
	for (int i = 0; i < ncomp; i++) { sz[i] = 0; fr[i] = 0; fo[i] = 0; cp[i] = 0.0; }
	std::vector<uint8_t> seen(pc, 0);
	const int64_t base = int64_t(n) * nc;
	for (int p = 0; p < pc; p++) {
		const int c = cm[p];
		if (c < 0 || ld[p] == 0) continue;
		const int o = ct[p];
		if (o < 0 || (o != n && alw[base + o] != 1)) continue;
		sz[c]++;
		const double s = p < nsup ? double(sc[p]) : 0.0;
		cp[c] += s;
		int f = 0;
		for (int32_t k = as[p]; k < as[p + 1]; k++) {
			const int32_t q = al[k];
			const int e = ct[q];
			if (e >= 0 && e != n && wr[base + e] == 1) {
				f = 1;
				if (!seen[q]) {
					seen[q] = 1;
					for (int32_t h = plh[q]; h >= 0; h = dnx[h]) {
						const int x = dow[h];
						if (x >= 0 && x != n && wr[base + x] == 1) fo[c]++;
					}
				}
			}
		}
		fr[c] += f;
		if (isp[p] == 1) {
			pi.push_back(c);
			pi.push_back(f);
			pi.push_back(p);
			pf.push_back(s);
		}
	}
	Array r;
	r.push_back(a_size);
	r.push_back(a_front);
	r.push_back(a_foes);
	r.push_back(a_cap);
	r.push_back(pi);
	r.push_back(pf);
	return r;
}


// Цель стратегических налётов (Forces._raid_region, двойник на GDScript):
// район в досягаемости с наибольшей ценностью вражеской суши (заводы и очки
// победы, сумма в double по возрастанию p); при равенстве — меньший; −1 — нет.
int MeowqCore::raid_region(const PackedInt32Array &ctrl, const PackedByteArray &war, const PackedByteArray &land,
		const PackedInt32Array &region, const PackedInt32Array &civ, const PackedInt32Array &mil,
		const PackedInt32Array &vpa, const PackedByteArray &reach, int n, int nc) const {
	const int pc = int(land.size());
	const int nr = int(reach.size());
	const int32_t *ct = ctrl.ptr(), *rg = region.ptr(), *cv = civ.ptr(), *ml = mil.ptr(), *vp = vpa.ptr();
	const uint8_t *wr = war.ptr(), *ld = land.ptr(), *rc = reach.ptr();
	std::vector<double> value(nr, 0.0);
	std::vector<uint8_t> has(nr, 0);
	const int64_t base = int64_t(n) * nc;
	for (int p = 0; p < pc; p++) {
		const int c = ct[p];
		if (c < 0 || wr[base + c] == 0 || ld[p] == 0) continue;
		const int r = rg[p];
		if (r < 0 || r >= nr || rc[r] == 0) continue;
		value[r] = value[r] + double(cv[p]) + double(ml[p]) * 1.5 + double(vp[p]) * 0.5;
		has[r] = 1;
	}
	int best = -1;
	double best_v = 0.0;
	for (int r = 0; r < nr; r++) {
		if (!has[r]) continue;
		if (value[r] > best_v || (value[r] == best_v && r < best)) {
			best_v = value[r];
			best = r;
		}
	}
	return best;
}


// Живые дивизии стороны страны n (своя и союзные: ally[n, хозяин]) по
// возрастанию слота (World.side_slots, двойник на GDScript).
PackedInt32Array MeowqCore::side_slots(const PackedByteArray &alive, const PackedInt32Array &owner,
		const PackedByteArray &ally, int n, int nc) const {
	const int m = int(alive.size() < owner.size() ? alive.size() : owner.size());
	const uint8_t *al = alive.ptr(), *aly = ally.ptr();
	const int32_t *ow = owner.ptr();
	const int64_t base = int64_t(n) * nc;
	std::vector<int32_t> out;
	for (int i = 0; i < m; i++) {
		if (al[i] == 0) continue;
		const int o = ow[i];
		if (o < 0 || (o != n && aly[base + o] != 1)) continue;
		out.push_back(i);
	}
	PackedInt32Array r;
	r.resize(int64_t(out.size()));
	int32_t *rp = r.ptrw();
	for (size_t k = 0; k < out.size(); k++) rp[k] = out[k];
	return r;
}
