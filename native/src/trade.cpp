// Морская блокада торговли (Economy.refresh_blockade, двойник на GDScript):
// округа флотов, открытые зоны каждой воюющей страны и недоступные ей
// продавцы. Операция в операцию как в GDScript (double; силы округи — в
// float32, как PackedFloat32Array), тот же порядок обходов.
#include "meowq_core.h"

#include <algorithm>
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


// Пути конвоев (Convoys.refresh_routes, двойник на GDScript): для каждой
// страны — обход бассейнов от её бассейнов (открытые — по блокаде; связи и
// закрытия проливов), путь по суше (граф «материк × страна» через невоюющих),
// пути к продавцам (по возрастанию номера) и к заморским пунктам (по порядку).
// → [страна, вид (0 — торговля, 1 — порт), цель, начала путей, бассейны путей].
Array MeowqCore::conv_routes(const Dictionary &t) const {
	const int nc = int(t["nc"]), nb = int(t["nb"]);
	const PackedInt32Array bs_a = t["bas_start"], bl_a = t["bas_list"], as_a = t["adj_start"], al_a = t["adj_list"], zb_a = t["zb"];
	const PackedByteArray land_a = t["land"], war_a = t["war"], nal_a = t["n_alive"], ndo_a = t["n_do"], ophas_a = t["op_has"];
	const PackedInt32Array sta_a = t["st_a"], stb_a = t["st_b"], stt_a = t["st_t"];
	const PackedByteArray stc_a = t["st_closed"];
	const PackedInt32Array sel_s = t["sel_s"], sel_l = t["sel_l"], op_s = t["op_s"], op_l = t["op_l"];
	const PackedInt32Array st_key = t["start_key"], tmk_a = t["tm_keys"], tms_a = t["tm_start"], tml_a = t["tm_list"];
	const PackedInt32Array pts_a = t["points"], ctrl_a = t["ctrl"], comp_a = t["comp"], dhome_a = t["dhome"];
	const PackedByteArray dmask_a = t["dmask"];
	const int32_t *bs = bs_a.ptr(), *bl = bl_a.ptr(), *as = as_a.ptr(), *al = al_a.ptr(), *zb = zb_a.ptr();
	const uint8_t *land = land_a.ptr(), *war = war_a.ptr(), *nal = nal_a.ptr(), *ndo = ndo_a.ptr(), *ophas = ophas_a.ptr();
	const int nst = int(sta_a.size());
	const int32_t *sta = sta_a.ptr(), *stb = stb_a.ptr(), *stt = stt_a.ptr();
	const uint8_t *stc = stc_a.ptr();
	const int32_t *tmk = tmk_a.ptr(), *tms = tms_a.ptr(), *tml = tml_a.ptr();
	std::unordered_map<int32_t, int32_t> tm_idx;
	for (int i = 0; i < int(tmk_a.size()); i++) tm_idx[tmk[i]] = i;

	// бассейны у портов стран (все и метрополии), заморские пункты снабжения —
	// по морским пунктам (Depots.sea_points), как в GDScript
	std::vector<std::vector<int32_t>> zl(nc), zh(nc), over(nc), transit(nc);
	{
		std::vector<uint8_t> zl_m(size_t(nc) * nb), zh_m(size_t(nc) * nb);
		const int32_t *pts = pts_a.ptr(), *ct = ctrl_a.ptr(), *cm = comp_a.ptr(), *dh = dhome_a.ptr();
		const uint8_t *dm = dmask_a.ptr();
		for (int i = 0; i < int(pts_a.size()); i++) {
			const int p = pts[i];
			const int c = ct[p];
			if (c < 0) continue;
			const bool home = !(dh[c] < 0 || cm[p] != dh[c]);
			if (!home && dm[p] == 1) over[c].push_back(p);
			for (int32_t k = as[p]; k < as[p + 1]; k++) {
				const int32_t y = al[k];
				if (land[y] != 0) continue;
				const int32_t z = zb[y];
				if (!zl_m[size_t(c) * nb + z]) { zl_m[size_t(c) * nb + z] = 1; zl[c].push_back(z); }
				if (home && !zh_m[size_t(c) * nb + z]) { zh_m[size_t(c) * nb + z] = 1; zh[c].push_back(z); }
			}
		}
		// транзит: страны-соседи по суше (узлы графа trade_mass)
		std::vector<uint8_t> tr_m(size_t(nc) * nc);
		for (int i = 0; i < int(tmk_a.size()); i++) {
			const int x = tmk[i] % nc;
			for (int32_t k = tms[i]; k < tms[i + 1]; k++) {
				const int y = tml[k] % nc;
				if (!tr_m[size_t(x) * nc + y]) { tr_m[size_t(x) * nc + y] = 1; transit[x].push_back(y); }
			}
		}
	}

	PackedInt32Array r_nat, r_kind, r_tgt, r_start, r_list;
	r_start.push_back(0);
	std::vector<std::vector<int32_t>> extra(nb);
	std::vector<uint8_t> cut(size_t(nb) * nb), open(nb);
	std::vector<int32_t> par(nb), dist(nb), par2(nb), dist2(nb), q;
	std::vector<uint8_t> by_land(nc);

	// обход бассейнов (Convoys._bfs): use_open — с открытыми, use_cut — с закрытыми проливами
	auto bfs = [&](int b, bool use_open, bool use_cut, std::vector<int32_t> &pr, std::vector<int32_t> &ds) {
		std::fill(pr.begin(), pr.end(), -1);
		std::fill(ds.begin(), ds.end(), 0);
		std::vector<int32_t> ss = zh[b].empty() ? zl[b] : zh[b];
		std::sort(ss.begin(), ss.end());
		q.clear();
		for (int32_t z : ss) {
			if (!use_open || open[z]) {
				pr[z] = z;
				ds[z] = 1;
				q.push_back(z);
			}
		}
		for (size_t h = 0; h < q.size(); h++) {
			const int32_t z = q[h];
			auto visit = [&](int32_t y) {
				if (pr[y] >= 0 || (use_open && !open[y]) || (use_cut && cut[size_t(z) * nb + y])) return;
				pr[y] = z;
				ds[y] = ds[z] + 1;
				q.push_back(y);
			};
			for (int32_t k = bs[z]; k < bs[z + 1]; k++) visit(bl[k]);
			for (int32_t y : extra[z]) visit(y);
		}
	};
	// путь до ближайшего из целевых (Convoys._route)
	auto route = [&](const std::vector<int32_t> &pr, const std::vector<int32_t> &ds, const std::vector<int32_t> &tz,
			std::vector<int32_t> &out) {
		out.clear();
		int best = -1, best_len = 1 << 30;
		for (int32_t z : tz) {
			if (pr[z] < 0) continue;
			const int l = ds[z];
			if (l < best_len || (l == best_len && z < best)) {
				best_len = l;
				best = z;
			}
		}
		if (best < 0) return;
		out.resize(best_len);
		int x = best;
		for (int i = best_len - 1; i >= 0; i--) {
			out[i] = x;
			x = pr[x];
		}
	};
	auto emit = [&](int b, int kind, int tgt, const std::vector<int32_t> &path) {
		r_nat.push_back(b);
		r_kind.push_back(kind);
		r_tgt.push_back(tgt);
		for (int32_t z : path) r_list.push_back(z);
		r_start.push_back(int32_t(r_list.size()));
	};

	std::vector<int32_t> tz, path;
	std::vector<uint8_t> seen_k;
	std::vector<int32_t> qn;
	for (int b = 0; b < nc; b++) {
		if (ndo[b] == 0 || (sel_s[b + 1] == sel_s[b] && over[b].empty()) || (zl[b].empty() && zh[b].empty())) continue;
		const int64_t bb = int64_t(b) * nc;
		// путь по суше (Convoys._by_land)
		std::fill(by_land.begin(), by_land.end(), 0);
		by_land[b] = 1;
		if (st_key[b] >= 0) {
			seen_k.assign(tmk_a.size(), 0);
			std::vector<int32_t> seen_x;
			auto was = [&](int32_t key) -> bool {
				auto it = tm_idx.find(key);
				if (it != tm_idx.end()) return seen_k[it->second] != 0;
				for (int32_t s : seen_x) if (s == key) return true;
				return false;
			};
			auto mark = [&](int32_t key) {
				auto it = tm_idx.find(key);
				if (it != tm_idx.end()) seen_k[it->second] = 1;
				else seen_x.push_back(key);
			};
			qn.clear();
			mark(st_key[b]);
			qn.push_back(st_key[b]);
			for (size_t h = 0; h < qn.size(); h++) {
				auto it = tm_idx.find(qn[h]);
				if (it == tm_idx.end()) continue;
				for (int32_t k = tms[it->second]; k < tms[it->second + 1]; k++) {
					const int32_t k2 = tml[k];
					const int y = k2 % nc;
					if (was(k2) || war[bb + y] == 1 || nal[y] == 0) continue;
					mark(k2);
					by_land[y] = 1;
					qn.push_back(k2);
				}
			}
		}
		// проливы (Convoys._strait_links)
		for (auto &e : extra) e.clear();
		std::fill(cut.begin(), cut.end(), 0);
		bool any_cut = false;
		for (int i = 0; i < nst; i++) {
			const int a = sta[i], c = stb[i];
			if (stc[int64_t(b) * nst + i]) {
				cut[size_t(a) * nb + c] = 1;
				cut[size_t(c) * nb + a] = 1;
				any_cut = true;
			} else if (stt[i] == 1) {
				extra[a].push_back(c);
				extra[c].push_back(a);
			}
		}
		const bool has_open = ophas[b] != 0;
		std::fill(open.begin(), open.end(), 0);
		if (has_open)
			for (int32_t i = op_s[b]; i < op_s[b + 1]; i++) open[zb[op_l[i]]] = 1;   // зона открыта → её бассейн
		bfs(b, has_open, true, par, dist);
		bool have_all = false;
		// продавцы
		for (int32_t i = sel_s[b]; i < sel_s[b + 1]; i++) {
			const int s = sel_l[i];
			if (by_land[s] == 1) continue;
			tz = zl[s];
			if (tz.empty()) {
				for (int y : transit[s]) tz.insert(tz.end(), zl[y].begin(), zl[y].end());
			}
			route(par, dist, tz, path);
			if (path.empty() && has_open) {
				if (!have_all) {
					bfs(b, false, true, par2, dist2);
					have_all = true;
				}
				route(par2, dist2, tz, path);
			}
			if (path.empty()) continue;
			emit(b, 0, s, path);
		}
		// заморские пункты
		for (int p : over[b]) {
			tz.clear();
			for (int32_t k = as[p]; k < as[p + 1]; k++) {
				const int32_t y = al[k];
				if (land[y] != 0) continue;
				const int32_t z = zb[y];
				if (std::find(tz.begin(), tz.end(), z) == tz.end()) tz.push_back(z);
			}
			route(par, dist, tz, path);
			if (path.empty() && !has_open) {
				if (!any_cut) continue;   // до порта не дойти (нет общей воды)
				std::vector<int32_t> p3(nb), d3(nb), path3;
				bfs(b, false, false, p3, d3);
				route(p3, d3, tz, path3);
				if (path3.empty()) continue;
				// иначе путь закрыт проливом — порт отрезан (пустой путь)
			}
			emit(b, 1, p, path);
		}
	}
	Array r;
	r.push_back(r_nat);
	r.push_back(r_kind);
	r.push_back(r_tgt);
	r.push_back(r_start);
	r.push_back(r_list);
	return r;
}


// Опасность на путях конвоев (Convoys._danger_all, двойник _danger_gd): силы
// бассейна по хозяевам флотов в порядке появления (флот в порту — только
// хозяин), затем для пары (страна, бассейн) — перехват и охранение. Операция в
// операцию как в GDScript (double), итог — в float32 (как прежний Vector2).
// → [перехват, охранение] по парам.
Array MeowqCore::convoy_danger(const Dictionary &t) const {
	const int nc = int(t["nc"]), nb = int(t["nb"]);
	const PackedByteArray war_a = t["war"], ally_a = t["ally"], fm_a = t["f_mode"];
	const PackedInt32Array bs_a = t["bas_start"], bl_a = t["bas_list"], zs_a = t["zs"], zn_a = t["zn"];
	const PackedInt32Array fo_a = t["f_owner"], qn_a = t["qn"], qb_a = t["qb"];
	const PackedFloat64Array fc_a = t["f_cp"], fe_a = t["f_es"], fr_a = t["f_rd"], k_a = t["k"];
	const uint8_t *war = war_a.ptr(), *ally = ally_a.ptr(), *fm = fm_a.ptr();
	const int32_t *bs = bs_a.ptr(), *bl = bl_a.ptr(), *zs = zs_a.ptr(), *zn = zn_a.ptr();
	const int32_t *fo = fo_a.ptr(), *qn = qn_a.ptr(), *qb = qb_a.ptr();
	const double *fc = fc_a.ptr(), *fe = fe_a.ptr(), *fr = fr_a.ptr(), *k = k_a.ptr();
	const int nq = int(qn_a.size());
	PackedFloat32Array out_ic, out_es;
	out_ic.resize(nq);
	out_es.resize(nq);
	float *oic = out_ic.ptrw(), *oes = out_es.ptrw();
	for (int q = 0; q < nq; q++) {
		oic[q] = 0.0f;
		oes[q] = 0.0f;
	}
	// бассейн → [начало, число] в общих списках хозяев
	std::vector<int32_t> b_off(size_t(nb), -1), b_cnt(size_t(nb), 0);
	std::vector<int32_t> ow;
	std::vector<double> rd, es, cp;
	std::vector<uint8_t> surf;
	std::vector<int32_t> pos(size_t(nc), -1);
	for (int q = 0; q < nq; q++) {
		const int n = qn[q], bi = qb[q];
		if (b_off[bi] < 0) {
			const int32_t base = int32_t(ow.size());
			b_off[bi] = base;
			for (int32_t j = bs[bi]; j < bs[bi + 1]; j++) {
				const int32_t z = bl[j];
				const int32_t z0 = zs[z];
				if (z0 < 0) continue;
				for (int32_t x = z0; x < z0 + zn[z]; x++) {
					const int32_t o = fo[x];
					int32_t i = pos[o];
					if (i < 0) {
						i = int32_t(ow.size());
						pos[o] = i;
						ow.push_back(o);
						rd.push_back(0.0);
						es.push_back(0.0);
						cp.push_back(0.0);
						surf.push_back(0);
					}
					const uint8_t m = fm[x];
					if (m == 0) continue;
					cp[i] += fc[x];
					es[i] += fe[x];
					if (m == 2) rd[i] += fr[x];
					else if (fc[x] > 0.0) surf[i] = 1;
				}
			}
			b_cnt[bi] = int32_t(ow.size()) - base;
			for (int32_t i = base; i < int32_t(ow.size()); i++) pos[ow[i]] = -1;
		}
		const int32_t base = b_off[bi], cnt = b_cnt[bi];
		if (cnt == 0) continue;
		double raid = 0.0, escort = 0.0, mine = 0.0, enemy = 0.0;
		bool surface = false;
		for (int32_t i = base; i < base + cnt; i++) {
			const int32_t o = ow[i];
			if (war[int64_t(n) * nc + o] == 1) {
				raid += rd[i];
				enemy += cp[i];
				if (surf[i] == 1) surface = true;
			} else if (o == n || ally[int64_t(n) * nc + o] == 1) {
				escort += es[i];
				mine += cp[i];
			}
		}
		double ic = (raid - escort * k[0]) * k[1];
		ic = ic < 0.0 ? 0.0 : (ic > k[2] ? k[2] : ic);
		if (surface) {
			const double sup = mine + enemy <= 0.0 ? 0.5 : mine / (mine + enemy);
			if (sup < k[3]) ic = ic > k[4] ? ic : k[4];
		}
		oic[q] = float(ic);
		oes[q] = float(escort);
	}
	Array r;
	r.push_back(out_ic);
	r.push_back(out_es);
	return r;
}


// Разбор пунктов снабжения за день (Depots._scan, двойник _scan_gd): связь
// пунктов со столицей и отрезанные (веса стран по очкам победы, столица — × cap_w),
// дивизии за морем по участкам (в порядке появления), группы пунктов за морем
// по (страна, участок) по возрастанию, у группы — главный порт (лучшая доля
// пути конвоев, при равенстве — первый), дивизий и подвоз (наибольшая подача
// портов с путём). → [связь, отрезанные, веса, начала групп стран, участок,
// начала пунктов, пункты, главный, дивизий, подвоз, ключи участков с
// дивизиями, их число].
Array MeowqCore::depots_scan(const Dictionary &t) const {
	const int nc = int(t["nc"]), pc = int(t["pc"]);
	const double cap_w = double(t["cap_w"]);
	const PackedInt32Array ctrl_a = t["ctrl"], comp_a = t["comp"], dl_a = t["dlist"], home_a = t["home"], capn_a = t["capn"];
	const PackedInt32Array vp_a = t["vp"], lp_a = t["lp"], sl_a = t["slots"], dp_a = t["dprov"], dow_a = t["downer"];
	const PackedFloat64Array cs_a = t["cs"];
	const PackedFloat32Array pcv_a = t["pconv"];
	const int32_t *ctrl = ctrl_a.ptr(), *comp = comp_a.ptr(), *dl = dl_a.ptr(), *home = home_a.ptr(), *capn = capn_a.ptr();
	const int32_t *vp = vp_a.ptr(), *lp = lp_a.ptr(), *sl = sl_a.ptr(), *dp = dp_a.ptr(), *dow = dow_a.ptr();
	const double *cs = cs_a.ptr();
	const float *pcv = pcv_a.ptr();
	const bool has_comp = comp_a.size() == pc, has_conv = pcv_a.size() == pc;
	const int nd = int(dl_a.size());
	PackedInt32Array ln, cut;
	ln.resize(pc);
	int32_t *lnp = ln.ptrw();
	for (int p = 0; p < pc; p++) lnp[p] = -1;
	PackedFloat64Array weight;
	weight.resize(nc);
	double *wt = weight.ptrw();
	for (int c = 0; c < nc; c++) wt[c] = 0.0;
	for (int i = 0; i < nd; i++) {
		const int32_t p = dl[i], c = ctrl[p];
		if (c < 0) continue;
		const double w = double(vp[p] > 1 ? vp[p] : 1) * (capn[c] == p ? cap_w : 1.0);
		if (has_comp && (home[c] < 0 || comp[p] != home[c])) {
			if (lp[p] == c) {
				cut.push_back(p);
				wt[c] += w;
			}
		} else {
			lnp[p] = c;
			wt[c] += w;
		}
	}
	// дивизии за морем: ключ «страна * pc + участок» → число (порядок появления)
	std::unordered_map<int64_t, int32_t> dv_idx;
	std::vector<int64_t> dv_keys;
	std::vector<int32_t> dv_cnt;
	const int ns = int(sl_a.size());
	for (int i = 0; i < ns; i++) {
		const int32_t s = sl[i];
		const int32_t cpv = comp[dp[s]];
		if (cpv < 0) continue;
		const int64_t key = int64_t(dow[s]) * pc + cpv;
		auto it = dv_idx.find(key);
		if (it == dv_idx.end()) {
			dv_idx.emplace(key, int32_t(dv_keys.size()));
			dv_keys.push_back(key);
			dv_cnt.push_back(1);
		} else {
			dv_cnt[it->second]++;
		}
	}
	// пункты за морем: (ключ, порядок в списке) — устойчиво по ключу
	std::vector<std::pair<int64_t, int32_t>> gp;
	for (int i = 0; i < nd; i++) {
		const int32_t p = dl[i], c = ctrl[p];
		if (c < 0 || comp[p] < 0 || comp[p] == home[c]) continue;
		gp.emplace_back(int64_t(c) * pc + comp[p], p);
	}
	std::stable_sort(gp.begin(), gp.end(), [](const std::pair<int64_t, int32_t> &a, const std::pair<int64_t, int32_t> &b) {
		return a.first < b.first;
	});
	PackedInt32Array g_ns, g_comp, g_start, g_pts, g_best, g_dv;
	PackedFloat64Array g_f;
	g_ns.resize(nc + 1);
	int32_t *gns = g_ns.ptrw();
	g_start.push_back(0);
	int cn = 0;
	size_t i = 0;
	while (i < gp.size()) {
		const int64_t key = gp[i].first;
		const int c = int(key / pc);
		while (cn <= c) gns[cn++] = int32_t(g_comp.size());
		g_comp.push_back(int32_t(key % pc));
		int32_t best = gp[i].second;
		double bs = -1.0, f = 0.0;
		size_t j = i;
		for (; j < gp.size() && gp[j].first == key; j++) {
			const int32_t p = gp[j].second;
			const double sf = cs[p];
			if (sf > bs) {
				bs = sf;
				best = p;
			}
			if (sf != -1.0 && has_conv) {
				const double x = double(pcv[p]);
				f = f > x ? f : x;
			}
			g_pts.push_back(p);
		}
		g_start.push_back(int32_t(g_pts.size()));
		g_best.push_back(best);
		auto it = dv_idx.find(key);
		g_dv.push_back(it == dv_idx.end() ? 0 : dv_cnt[it->second]);
		g_f.push_back(f);
		i = j;
	}
	while (cn <= nc) gns[cn++] = int32_t(g_comp.size());
	PackedInt32Array o_key, o_cnt;
	o_key.resize(int64_t(dv_keys.size()));
	o_cnt.resize(int64_t(dv_keys.size()));
	for (size_t k = 0; k < dv_keys.size(); k++) {
		o_key.set(int64_t(k), int32_t(dv_keys[k]));
		o_cnt.set(int64_t(k), dv_cnt[k]);
	}
	Array r;
	r.push_back(ln);
	r.push_back(cut);
	r.push_back(weight);
	r.push_back(g_ns);
	r.push_back(g_comp);
	r.push_back(g_start);
	r.push_back(g_pts);
	r.push_back(g_best);
	r.push_back(g_dv);
	r.push_back(g_f);
	r.push_back(o_key);
	r.push_back(o_cnt);
	return r;
}


// Пути конвоев стран за день (Convoys.daily, двойник _day_gd): вид 1 — всё
// доходит, порты по обеспеченности снабжения; вид 2 — доля, что доходит по пути
// (перехват по опасным бассейнам), недошедший импорт (float32, как
// res_lost), потопленные конвои. Операция в операцию как в GDScript (double).
// → [подача портов, доля пути, недошедшее (nc × 6), доля импорта, потоплено].
Array MeowqCore::convoy_day(const Dictionary &t) const {
	const int RES_N = 6;
	const int nc = int(t["nc"]), nb = int(t["nb"]);
	const double sink = double(t["sink"]);
	const PackedByteArray mode_a = t["mode"], rk_a = t["r_kind"], uh_a = t["u_has"];
	const PackedFloat64Array sf_a = t["s_fill"], tf_a = t["t_fill"], sn_a = t["s_need"], rn_a = t["r_need"];
	const PackedInt32Array qns_a = t["q_ns"], qb_a = t["qb"], rns_a = t["r_ns"], rkey_a = t["r_key"], rzs_a = t["r_zs"], rz_a = t["r_z"], vp_a = t["vp"];
	const PackedFloat32Array dic_a = t["d_ic"], un_a = t["units"];
	PackedFloat32Array pconv = t["p_conv"];
	pconv = pconv.duplicate();
	const uint8_t *mode = mode_a.ptr(), *rk = rk_a.ptr(), *uh = uh_a.ptr();
	const double *sf = sf_a.ptr(), *tf = tf_a.ptr(), *sn = sn_a.ptr(), *rn = rn_a.ptr();
	const int32_t *qns = qns_a.ptr(), *qb = qb_a.ptr(), *rns = rns_a.ptr(), *rkey = rkey_a.ptr(), *rzs = rzs_a.ptr(), *rz = rz_a.ptr(), *vp = vp_a.ptr();
	const float *dic = dic_a.ptr(), *un = un_a.ptr();
	float *pc = pconv.ptrw();
	const int nr = int(rkey_a.size());
	PackedFloat64Array r_safe, o_trade, o_sunk;
	PackedFloat32Array o_lost;
	r_safe.resize(nr);
	o_lost.resize(int64_t(nc) * RES_N);
	o_trade.resize(nc);
	o_sunk.resize(nc);
	double *rs = r_safe.ptrw(), *otr = o_trade.ptrw(), *osk = o_sunk.ptrw();
	float *ol = o_lost.ptrw();
	for (int i = 0; i < nr; i++) rs[i] = 0.0;
	for (int i = 0; i < nc * RES_N; i++) ol[i] = 0.0f;
	for (int n = 0; n < nc; n++) {
		otr[n] = 0.0;
		osk[n] = 0.0;
	}
	std::vector<double> dz(size_t(nb), 0.0);
	for (int n = 0; n < nc; n++) {
		const uint8_t m = mode[n];
		if (m == 0) continue;
		const double sup_fill = sf[n];
		if (m == 1) {
			for (int32_t i = rns[n]; i < rns[n + 1]; i++) {
				if (rk[i] != 1) continue;
				const bool cut = rzs[i + 1] == rzs[i];
				pc[rkey[i]] = cut ? 0.0f : float(sup_fill);
				rs[i] = cut ? 0.0 : 1.0;
			}
			continue;
		}
		bool calm = true;
		for (int32_t q = qns[n]; q < qns[n + 1]; q++) {
			const double dx = double(dic[q]);
			if (dx > 0.0) {
				dz[qb[q]] = dx;
				calm = false;
			}
		}
		const double trade_fill = tf[n], sup_need = sn[n];
		double wsum = 0.0;
		for (int32_t i = rns[n]; i < rns[n + 1]; i++)
			if (rk[i] == 1) wsum += 1.0 + double(vp[rkey[i]]);
		double sunk = 0.0, sea_total = 0.0, lost_total = 0.0;
		float *lb = ol + int64_t(n) * RES_N;
		for (int32_t i = rns[n]; i < rns[n + 1]; i++) {
			double safe = 1.0;
			if (!calm)
				for (int32_t j = rzs[i]; j < rzs[i + 1]; j++) safe *= 1.0 - dz[rz[j]];
			if (rk[i] == 0) {
				const double got = trade_fill * safe;
				if (uh[i] == 1) {
					for (int r = 0; r < RES_N; r++) {
						const double u = double(un[int64_t(i) * RES_N + r]);
						lb[r] = float(double(lb[r]) + u * (1.0 - got));
						sea_total += u;
						lost_total += u * (1.0 - got);
					}
				}
				sunk += rn[i] * trade_fill * (1.0 - safe) * sink;
			} else {
				const int32_t p = rkey[i];
				if (rzs[i + 1] == rzs[i]) {
					pc[p] = 0.0f;
					rs[i] = 0.0;
					continue;
				}
				pc[p] = float(sup_fill * safe);
				rs[i] = safe;
				const double share = (1.0 + double(vp[p])) / (wsum > 1.0 ? wsum : 1.0);
				sunk += sup_need * share * sup_fill * (1.0 - safe) * sink;
			}
		}
		otr[n] = sea_total <= 0.0 ? 1.0 : 1.0 - lost_total / sea_total;
		osk[n] = sunk;
		for (int32_t q = qns[n]; q < qns[n + 1]; q++) dz[qb[q]] = 0.0;
	}
	Array r;
	r.push_back(pconv);
	r.push_back(r_safe);
	r.push_back(o_lost);
	r.push_back(o_trade);
	r.push_back(o_sunk);
	return r;
}


// Подпись договоров (Convoys._units_by_buyer, двойник contracts_sig_gd): число
// и взвешенная сумма — операция в операцию как в GDScript (double, int64).
double MeowqCore::contracts_sig(const Array &contracts) const {
	const int64_t n = contracts.size();
	double sig = double(n);
	for (int64_t i = 0; i < n; i++) {
		const Array c = contracts[i];
		const double k = double(i + 1);
		const int64_t key = int64_t(c[0]) * 7919 + int64_t(c[1]) * 31 + int64_t(c[2]);
		sig += double(c[3]) * k + double(key) * 1.0e-3 * k;
	}
	return sig;
}
