// Снабжение по принципу жанра (Supply.field_gd / divisions_gd в GDScript —
// двойники; результаты совпадают до бита: тот же порядок обхода, double).
#include "meowq_core.h"

#include <vector>
#include <algorithm>

using namespace godot;

Array MeowqCore::supply_field(const Dictionary &t) const {
	const PackedInt32Array adj_start_a = t["adj_start"], adj_list_a = t["adj_list"];
	const PackedByteArray land_a = t["land"];
	const PackedInt32Array ctrl_a = t["ctrl"], preg_a = t["preg"], vp_a = t["vp"], pop_a = t["pop"];
	const PackedFloat32Array pcap_a = t["pcap"];
	const PackedInt32Array side_a = t["side_of"], radj_s_a = t["reg_adj_start"], radj_l_a = t["reg_adj_list"];
	const PackedInt32Array src_a = t["src"], src_off_a = t["src_off"], caps_a = t["capitals"];
	const PackedFloat64Array fall_a = t["fall"], kk_a = t["k"];
	const int ns = int(t["ns"]), nr = int(t["nr"]);
	const int32_t *adj_start = adj_start_a.ptr(), *adj_list = adj_list_a.ptr(), *ctrl = ctrl_a.ptr();
	const int32_t *preg = preg_a.ptr(), *vp = vp_a.ptr(), *pop = pop_a.ptr(), *side_of = side_a.ptr();
	const int32_t *radj_s = radj_s_a.ptr(), *radj_l = radj_l_a.ptr(), *src = src_a.ptr(), *src_off = src_off_a.ptr();
	const uint8_t *land = land_a.ptr();
	const float *pcap = pcap_a.ptr();
	const double *fall = fall_a.ptr();
	const double k_cap = kk_a[0], k_port = kk_a[1], k_pvp = kk_a[2], k_level = kk_a[3];
	const int hub_range = int(kk_a[5]);
	const int pc = ctrl_a.size();
	const bool has_pop = pop_a.size() == pc;
	const int nk = ns * nr;

	PackedInt32Array ps_a;
	ps_a.resize(pc);
	int32_t *ps = ps_a.ptrw();
	std::fill(ps, ps + pc, -1);
	std::vector<int32_t> hub(nk, -1), pcount(nk, 0);
	std::vector<double> hscore(nk, 0.0), capsum(nk, 0.0), level(nk, 0.0);
	for (int p = 0; p < pc; p++) {
		if (land[p] == 0 || ctrl[p] < 0)
			continue;
		const int s = side_of[ctrl[p]];
		if (s < 0)
			continue;
		ps[p] = s;
		const int k = s * nr + preg[p];
		capsum[k] += double(pcap[p]);
		pcount[k] += 1;
		const double sc = double(vp[p]) * 1.0e6 + (has_pop ? double(pop[p]) : 0.0);
		if (hub[k] < 0 || sc > hscore[k]) {
			hub[k] = p;
			hscore[k] = sc;
		}
	}
	for (int k = 0; k < nk; k++)
		if (pcount[k] > 0)
			level[k] = capsum[k] / double(pcount[k]);

	std::vector<int32_t> best_src(nk, -1);
	std::vector<double> best_f(nk, 0.0), best(nr, -1.0);
	std::vector<int32_t> open, nxt;
	for (int s = 0; s < ns; s++) {
		std::fill(best.begin(), best.end(), -1.0);
		open.clear();
		for (int j = src_off[s]; j < src_off[s + 1]; j++) {
			const int r = preg[src[j]];
			if (best[r] < 99.0) {
				best[r] = 99.0;
				open.push_back(r);
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
			if (hub[k] >= 0 && best[r] > 0.0) {
				best_src[k] = hub[k];
				best_f[k] = k_level * std::min(best[r], level[k]);
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
			const double f = is_cap ? k_cap : k_port + k_pvp * std::min(5.0, double(vp[h]));
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
	std::vector<int32_t> mark(pc, 0), queue, hops;
	int stamp = 0;
	for (int r = 0; r < nr; r++) {
		for (int s = 0; s < ns; s++) {
			const int start = best_src[s * nr + r];
			if (start < 0)
				continue;
			const double f0 = best_f[s * nr + r];
			stamp++;
			mark[start] = stamp;
			queue.assign(1, start);
			hops.assign(1, 0);
			size_t head = 0;
			while (head < queue.size()) {
				const int p = queue[head];
				const int h = hops[head];
				head++;
				const double v = f0 * fall[h];
				if (v > got[p]) {
					got[p] = v;
					gsrc[p] = start;
				}
				if (h >= hub_range)
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
	Array res;
	res.push_back(ps_a);
	res.push_back(got_a);
	res.push_back(gsrc_a);
	return res;
}

PackedFloat64Array MeowqCore::supply_divs(const Dictionary &t) const {
	const PackedInt32Array ps_a = t["ps"], side_a = t["side_of"], ctrl_a = t["ctrl"];
	const PackedFloat64Array got_a = t["got"];
	const PackedInt32Array gsrc_a = t["gsrc"];
	const int32_t *gsrc = gsrc_a.ptr();
	const PackedFloat32Array pcap_a = t["pcap"];
	const PackedByteArray alive_a = t["d_alive"];
	const PackedInt32Array prov_a = t["d_prov"], owner_a = t["d_owner"], mot_a = t["mot"];
	const double k_local = double(t["local"]);
	const int32_t *ps = ps_a.ptr(), *side_of = side_a.ptr(), *ctrl = ctrl_a.ptr();
	const int32_t *prov = prov_a.ptr(), *owner = owner_a.ptr(), *mot = mot_a.ptr();
	const double *got = got_a.ptr();
	const float *pcap = pcap_a.ptr();
	const uint8_t *alive = alive_a.ptr();
	const int n = alive_a.size();
	std::vector<double> dem(ctrl_a.size(), 0.0);
	for (int i = 0; i < n; i++)
		if (alive[i] == 1)
			dem[prov[i]] += mot[i] >= 1 ? 1.5 : 1.0;
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
		double have = k_local * double(pcap[p]);
		const int g = gsrc[p];
		if (ps[p] == s && g >= 0 && ctrl[g] >= 0 && side_of[ctrl[g]] == s)
			have += got[p];
		const double d = dem[p];
		sup[i] = have >= d ? 1.0 : have / std::max(1.0, d);
	}
	return sup_a;
}
