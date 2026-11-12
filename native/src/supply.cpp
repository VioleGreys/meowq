// Снабжение по принципу жанра (Supply.field_gd / divisions_gd в GDScript —
// двойники; результаты совпадают до бита: тот же порядок обхода, double).
#include "meowq_core.h"

#include <unordered_map>
#include <vector>
#include <algorithm>

using namespace godot;

Array MeowqCore::supply_field(const Dictionary &t) const {
	const PackedInt32Array adj_start_a = t["adj_start"], adj_list_a = t["adj_list"];
	const PackedByteArray land_a = t["land"];
	const PackedInt32Array ctrl_a = t["ctrl"], preg_a = t["preg"], vp_a = t["vp"], pop_a = t["pop"];
	const PackedFloat32Array pcap_a = t["pcap"], smult_a = t["smult"];
	const PackedInt32Array side_a = t["side_of"], radj_s_a = t["reg_adj_start"], radj_l_a = t["reg_adj_list"];
	const PackedInt32Array src_a = t["src"], src_off_a = t["src_off"], caps_a = t["capitals"];
	const PackedFloat64Array fall_a = t["fall"], kk_a = t["k"];
	const int ns = int(t["ns"]), nr = int(t["nr"]);
	const int32_t *adj_start = adj_start_a.ptr(), *adj_list = adj_list_a.ptr(), *ctrl = ctrl_a.ptr();
	const int32_t *preg = preg_a.ptr(), *vp = vp_a.ptr(), *pop = pop_a.ptr(), *side_of = side_a.ptr();
	const int32_t *radj_s = radj_s_a.ptr(), *radj_l = radj_l_a.ptr(), *src = src_a.ptr(), *src_off = src_off_a.ptr();
	const uint8_t *land = land_a.ptr();
	const float *pcap = pcap_a.ptr();
	const float *smult = smult_a.ptr();   // подача порта от конвоев (Convoys), 0..1
	const double *fall = fall_a.ptr();
	const double k_cap = kk_a[0], k_port = kk_a[1], k_pvp = kk_a[2], k_level = kk_a[3];
	const int hub_range = int(kk_a[5]);
	const double rail_loss = kk_a[6], rail_min = kk_a[7], gauge_loss = kk_a[8];
	const PackedInt32Array owner_a = t["owner"];
	const PackedByteArray gauge_a = t["gauge"];
	const int32_t *owner = owner_a.ptr();
	const uint8_t *gauge = gauge_a.ptr();
	const PackedByteArray nlvl_a = t["nlvl"];
	const PackedInt32Array join_a = t["join"], trange_a = t["trange"];
	const PackedFloat64Array tcap_a = t["tcap"];
	const uint8_t *nlvl = nlvl_a.ptr();
	const int32_t *join = join_a.ptr(), *trange = trange_a.ptr();
	const double *tcap = tcap_a.ptr();
	const double node_up = kk_a[10], rail_up = kk_a[11];
	const int kc = int(kk_a[12]);
	const int pc = ctrl_a.size();
	const bool has_pop = pop_a.size() == pc;
	const int nk = ns * nr;

	PackedInt32Array ps_a;
	ps_a.resize(pc);
	int32_t *ps = ps_a.ptrw();
	std::fill(ps, ps + pc, -1);
	PackedInt32Array hub_a;
	hub_a.resize(nk);
	int32_t *hub = hub_a.ptrw();
	std::fill(hub, hub + nk, -1);
	std::vector<int32_t> pcount(nk, 0);
	std::vector<double> hscore(nk, 0.0), capsum(nk, 0.0), level(nk, 0.0);
	for (int p = 0; p < pc; p++) {
		if (land[p] == 0 || ctrl[p] < 0)
			continue;
		const int s = side_of[ctrl[p]];
		if (s < 0)
			continue;
		ps[p] = s;
		const int k = s * nr + preg[p];
		pcount[k] += 1;
		const double sc = double(vp[p]) * 1.0e6 + (has_pop ? double(pop[p]) : 0.0);
		if (hub[k] < 0 || sc > hscore[k]) {
			hub[k] = p;
			hscore[k] = sc;
		}
	}
	// узел свой или присоединён к сети стороны
	std::vector<uint8_t> hub_ok(nk, 0);
	for (int k = 0; k < nk; k++) {
		const int h = hub[k];
		if (h < 0)
			continue;
		const int s = k / nr;
		const int o = owner[h];
		if ((o >= 0 && side_of[o] == s) || (join[h] >= 0 && side_of[join[h]] == s))
			hub_ok[k] = 1;
	}
	for (int p = 0; p < pc; p++) {
		const int s = ps[p];
		if (s < 0)
			continue;
		const int k = s * nr + preg[p];
		const int o = owner[p];
		const bool lose = o >= 0 && gauge[o] != gauge[ctrl[p]] && !(hub[k] >= 0 && join[hub[k]] >= 0 && hub_ok[k] == 1);
		capsum[k] += double(pcap[p]) * (lose ? gauge_loss : 1.0);
	}
	PackedByteArray conn_a;
	conn_a.resize(pc);
	uint8_t *conn = conn_a.ptrw();
	std::fill(conn, conn + pc, 0);
	{
		std::vector<int32_t> cq;
		for (int s = 0; s < ns; s++)
			for (int j = src_off[s]; j < src_off[s + 1]; j++) {
				const int h = src[j];
				if (ps[h] == s && conn[h] == 0) {
					conn[h] = 1;
					cq.push_back(h);
				}
			}
		for (size_t ch = 0; ch < cq.size(); ch++) {
			const int p = cq[ch];
			const int s = ps[p];
			for (int e = adj_start[p]; e < adj_start[p + 1]; e++) {
				const int q = adj_list[e];
				if (conn[q] == 0 && ps[q] == s) {
					conn[q] = 1;
					cq.push_back(q);
				}
			}
		}
	}
	for (int k = 0; k < nk; k++)
		if (pcount[k] > 0) {
			level[k] = capsum[k] / double(pcount[k]);
			if (hub_ok[k] == 1)
				level[k] += rail_up * double(nlvl[hub[k]]);
		}

	PackedInt32Array best_src_a;
	best_src_a.resize(nk);
	int32_t *best_src = best_src_a.ptrw();
	std::fill(best_src, best_src + nk, -1);
	PackedFloat64Array best_f_a;
	best_f_a.resize(nk);
	double *best_f = best_f_a.ptrw();
	std::fill(best_f, best_f + nk, 0.0);
	std::vector<double> best(nr, -1.0);
	std::vector<int32_t> open, nxt, rd(nr, -1), q2;
	for (int s = 0; s < ns; s++) {
		std::fill(best.begin(), best.end(), -1.0);
		std::fill(rd.begin(), rd.end(), -1);
		open.clear();
		for (int j = src_off[s]; j < src_off[s + 1]; j++) {
			const int r = preg[src[j]];
			if (best[r] < 99.0) {
				best[r] = 99.0;
				rd[r] = 0;
				open.push_back(r);
			}
		}
		q2 = open;
		for (size_t head2 = 0; head2 < q2.size(); head2++) {
			const int r0 = q2[head2];
			for (int j = radj_s[r0]; j < radj_s[r0 + 1]; j++) {
				const int r2 = radj_l[j];
				if (rd[r2] >= 0 || pcount[s * nr + r2] == 0)
					continue;
				rd[r2] = rd[r0] + 1;
				q2.push_back(r2);
			}
		}
		while (!open.empty()) {
			nxt.clear();
			for (int r : open) {
				for (int j = radj_s[r]; j < radj_s[r + 1]; j++) {
					const int r2 = radj_l[j];
					const int k2 = s * nr + r2;
					if (pcount[k2] == 0)
						continue;
					const double w = std::min(best[r], level[k2]);
					if (w > best[r2] + 1e-9) {
						best[r2] = w;
						nxt.push_back(r2);
					}
				}
			}
			open.swap(nxt);
		}
		for (int r = 0; r < nr; r++) {
			const int k = s * nr + r;
			const int h = hub[k];
			if (h >= 0 && hub_ok[k] == 1 && best[r] > 0.0 && conn[h] == 1) {
				best_src[k] = h;
				best_f[k] = k_level * std::min(best[r], level[k]) * std::max(rail_min, 1.0 - rail_loss * double(rd[r]))
						* (1.0 + node_up * double(nlvl[h])) * tcap[ctrl[h]];
			}
		}
		for (int j = src_off[s]; j < src_off[s + 1]; j++) {
			const int h = src[j];
			bool is_cap = false;
			for (int c = 0; c < caps_a.size(); c++)
				if (caps_a[c] == h) {
					is_cap = true;
					break;
				}
			double f = is_cap ? k_cap : (k_port + k_pvp * std::min(5.0, double(vp[h]))) * double(smult[h]);
			f *= (1.0 + node_up * double(nlvl[h])) * tcap[ctrl[h]];
			const int k = s * nr + preg[h];
			if (f > best_f[k]) {
				best_f[k] = f;
				best_src[k] = h;
			}
		}
	}

	PackedFloat64Array got_a;
	got_a.resize(pc);
	double *got = got_a.ptrw();
	std::fill(got, got + pc, 0.0);
	PackedInt32Array gsrc_a;
	gsrc_a.resize(pc);
	int32_t *gsrc = gsrc_a.ptrw();
	std::fill(gsrc, gsrc + pc, -1);
	PackedInt32Array cand_a, chop_a;
	cand_a.resize(int64_t(pc) * kc);
	chop_a.resize(int64_t(pc) * kc);
	int32_t *cand = cand_a.ptrw(), *chop = chop_a.ptrw();
	std::fill(cand, cand + int64_t(pc) * kc, -1);
	std::fill(chop, chop + int64_t(pc) * kc, 0);
	std::vector<int32_t> pkey(pc, -1);
	for (int k = 0; k < nk; k++)
		if (best_src[k] >= 0)
			pkey[best_src[k]] = k;
	std::unordered_map<int64_t, int32_t> nn;   // (узел волны)*nk + (узел, до которого дошла) → переходов
	std::vector<int32_t> mark(pc, 0), queue, hops;
	int stamp = 0;
	for (int r = 0; r < nr; r++) {
		for (int s = 0; s < ns; s++) {
			const int k = s * nr + r;
			const int start = best_src[k];
			if (start < 0)
				continue;
			const int rng = hub_range + int(nlvl[start]) / 2 + trange[ctrl[start]];
			const double f0 = best_f[k];
			stamp++;
			mark[start] = stamp;
			queue.assign(1, start);
			hops.assign(1, 0);
			size_t head = 0;
			while (head < queue.size()) {
				const int p = queue[head];
				const int h = hops[head];
				head++;
				if (pkey[p] >= 0)
					nn[int64_t(k) * nk + pkey[p]] = h;
				const double v = f0 * fall[h];
				if (v > got[p]) {
					got[p] = v;
					gsrc[p] = start;
				}
				const int64_t b = int64_t(p) * kc;
				int pos = kc;
				for (int m = 0; m < kc; m++) {
					const int ck = cand[b + m];
					if (ck < 0 || h < chop[b + m] || (h == chop[b + m] && k < ck)) {
						pos = m;
						break;
					}
				}
				if (pos < kc) {
					for (int m2 = kc - 1; m2 > pos; m2--) {
						cand[b + m2] = cand[b + m2 - 1];
						chop[b + m2] = chop[b + m2 - 1];
					}
					cand[b + pos] = k;
					chop[b + pos] = h;
				}
				if (h >= rng)
					continue;
				for (int e = adj_start[p]; e < adj_start[p + 1]; e++) {
					const int q = adj_list[e];
					if (mark[q] == stamp || ps[q] != s)
						continue;
					mark[q] = stamp;
					queue.push_back(q);
					hops.push_back(h + 1);
				}
			}
		}
	}
	const double spill_step = kk_a[13], spill_min = kk_a[14];
	PackedFloat64Array cfac_a;
	cfac_a.resize(int64_t(pc) * kc);
	double *cfac = cfac_a.ptrw();
	std::fill(cfac, cfac + int64_t(pc) * kc, 0.0);
	for (int p = 0; p < pc; p++) {
		const int64_t b = int64_t(p) * kc;
		const int k0 = cand[b];
		if (k0 < 0)
			continue;
		cfac[b] = 1.0;
		for (int m = 1; m < kc; m++) {
			const int km = cand[b + m];
			if (km < 0)
				break;
			auto it = nn.find(int64_t(km) * nk + k0);
			cfac[b + m] = it == nn.end() ? spill_min : std::max(spill_min, 1.0 - spill_step * double(it->second));
		}
	}
	// ёмкость провинции для военного ИИ: подача + местное (в котле — урезанное)
	const double k_loc = kk_a[4], k_pock = kk_a[9];
	PackedFloat32Array supcap_a;
	supcap_a.resize(pc);
	float *supcap = supcap_a.ptrw();
	for (int p = 0; p < pc; p++) {
		supcap[p] = 0.0f;
		if (ps[p] >= 0)
			supcap[p] = float(got[p] + k_loc * double(pcap[p]) * (conn[p] == 1 ? 1.0 : k_pock));
	}
	Array res;
	res.push_back(ps_a);
	res.push_back(got_a);
	res.push_back(gsrc_a);
	res.push_back(conn_a);
	res.push_back(supcap_a);
	res.push_back(cand_a);
	res.push_back(chop_a);
	res.push_back(best_f_a);
	res.push_back(best_src_a);
	res.push_back(hub_a);
	PackedInt32Array keys_a;   // узлы, где у стороны есть провинции района
	for (int k = 0; k < nk; k++)
		if (hub[k] >= 0)
			keys_a.push_back(k);
	res.push_back(keys_a);
	res.push_back(cfac_a);
	return res;
}

Array MeowqCore::supply_divs(const Dictionary &t) const {
	const PackedInt32Array ps_a = t["ps"], side_a = t["side_of"], ctrl_a = t["ctrl"];
	const PackedByteArray conn_a = t["conn"];
	const uint8_t *conn = conn_a.ptr();
	const double k_pocket = double(t["pocket"]);
	const PackedFloat32Array pcap_a = t["pcap"];
	const PackedByteArray alive_a = t["d_alive"];
	const PackedInt32Array prov_a = t["d_prov"], owner_a = t["d_owner"], mot_a = t["mot"];
	const double k_local = double(t["local"]);
	const PackedInt32Array cand_a = t["cand"], chop_a = t["chop"], nprov_a = t["nprov"];
	const PackedFloat64Array nf_a = t["nf"], fall_a = t["fall"], cfac_a = t["cfac"];
	const double *cfac = cfac_a.ptr();
	const double budget_k = double(t["budget"]);
	const int kc = int(t["kc"]), nr = int(t["nr"]);
	const int32_t *ps = ps_a.ptr(), *side_of = side_a.ptr(), *ctrl = ctrl_a.ptr();
	const int32_t *prov = prov_a.ptr(), *owner = owner_a.ptr(), *mot = mot_a.ptr();
	const int32_t *cand = cand_a.ptr(), *chop = chop_a.ptr(), *nprov = nprov_a.ptr();
	const double *nf = nf_a.ptr(), *fall = fall_a.ptr();
	const float *pcap = pcap_a.ptr();
	const uint8_t *alive = alive_a.ptr();
	const int n = alive_a.size();
	const int pc = ctrl_a.size();
	const int nk = nf_a.size();
	std::vector<double> dem(pc, 0.0), have(pc, 0.0), need(pc, 0.0);
	for (int i = 0; i < n; i++)
		if (alive[i] == 1) {
			const int s = side_of[owner[i]];
			const int c = ctrl[prov[i]];
			if (s >= 0 && c >= 0 && side_of[c] == s)
				dem[prov[i]] += mot[i] >= 1 ? 1.5 : 1.0;
		}
	std::vector<int32_t> plist;
	for (int p = 0; p < pc; p++) {
		if (dem[p] <= 0.0)
			continue;
		const int s = side_of[ctrl[p]];
		have[p] = k_local * double(pcap[p]) * ((ps[p] == s && conn[p] == 1) ? 1.0 : k_pocket);
		if (ps[p] == s && dem[p] > have[p]) {
			need[p] = dem[p] - have[p];
			plist.push_back(p);
		}
	}
	std::vector<double> rem(nk, 0.0), req(nk, 0.0), rq(plist.size(), 0.0);
	std::vector<uint8_t> rset(nk, 0);
	std::vector<int32_t> rk(plist.size(), -1);
	PackedFloat64Array used_a;
	used_a.resize(nk);
	double *used = used_a.ptrw();
	std::fill(used, used + nk, 0.0);
	for (int j = 0; j < kc; j++) {
		for (size_t m = 0; m < plist.size(); m++) {
			const int p = plist[m];
			rk[m] = -1;
			const int k = cand[int64_t(p) * kc + j];
			if (k < 0 || need[p] <= 0.0)
				continue;
			const int g = nprov[k];
			if (ctrl[g] < 0 || side_of[ctrl[g]] != k / nr)
				continue;
			const double r = std::min(need[p], nf[k] * fall[chop[int64_t(p) * kc + j]] * cfac[int64_t(p) * kc + j]);
			if (rset[k] == 0) {
				rset[k] = 1;
				rem[k] = nf[k] * budget_k;
			}
			rq[m] = r;
			rk[m] = k;
			req[k] += r;
		}
		for (size_t m = 0; m < plist.size(); m++) {
			const int k = rk[m];
			if (k < 0)
				continue;
			const int p = plist[m];
			const double d = rem[k] >= req[k] ? rq[m] : rq[m] * (rem[k] / req[k]);
			have[p] += d;
			need[p] -= d;
			used[k] += d;
		}
		for (size_t m = 0; m < plist.size(); m++) {
			const int k = rk[m];
			if (k >= 0 && req[k] > 0.0) {
				rem[k] = std::max(0.0, rem[k] - req[k]);
				req[k] = 0.0;
			}
		}
	}
	PackedFloat64Array sup_a;
	sup_a.resize(n);
	double *sup = sup_a.ptrw();
	for (int i = 0; i < n; i++) {
		sup[i] = 0.0;
		if (alive[i] == 0)
			continue;
		const int p = prov[i];
		const int s = side_of[owner[i]];
		const int c = ctrl[p];
		if (s < 0 || c < 0 || side_of[c] != s)
			continue;
		const double d = dem[p];
		sup[i] = have[p] >= d ? 1.0 : have[p] / std::max(1.0, d);
	}
	Array r;
	r.push_back(sup_a);
	r.push_back(used_a);
	return r;
}

// Планирование наступления (World.k_plan — двойник): стоящая на фронте дивизия
// копит план, идущая/атакующая/в пути — теряет, стоящая в тылу — медленно теряет.
PackedFloat64Array MeowqCore::plan_update(const PackedByteArray &alive_a, const PackedInt32Array &transit_a,
		const PackedInt32Array &next_a, const PackedByteArray &battle_a, const PackedInt32Array &prov_a,
		const PackedInt32Array &owner_a, const PackedInt32Array &ctrl_a, const PackedInt32Array &adj_start_a,
		const PackedInt32Array &adj_list_a, const PackedByteArray &land_a, const PackedByteArray &hostile_a, int nc,
		const PackedFloat64Array &plan_in, double gain, double active, double rear) const {
	const uint8_t *alive = alive_a.ptr(), *battle = battle_a.ptr(), *land = land_a.ptr(), *hostile = hostile_a.ptr();
	const int32_t *transit = transit_a.ptr(), *next = next_a.ptr(), *prov = prov_a.ptr(), *owner = owner_a.ptr();
	const int32_t *ctrl = ctrl_a.ptr(), *adj_start = adj_start_a.ptr(), *adj_list = adj_list_a.ptr();
	PackedFloat64Array out = plan_in;
	double *v = out.ptrw();
	const int n = alive_a.size();
	for (int i = 0; i < n; i++) {
		if (alive[i] == 0)
			continue;
		if (next[i] >= 0 || transit[i] > 0 || battle[i] != 0) {
			v[i] = std::max(0.0, v[i] - active);
			continue;
		}
		const int p = prov[i];
		const int o = owner[i];
		bool front = false;
		for (int k = adj_start[p]; k < adj_start[p + 1]; k++) {
			const int q = adj_list[k];
			const int c = ctrl[q];
			if (land[q] == 1 && c >= 0 && hostile[int64_t(o) * nc + c] == 1) {
				front = true;
				break;
			}
		}
		v[i] = front ? std::min(1.0, v[i] + gain) : std::max(0.0, v[i] - rear);
	}
	return out;
}
