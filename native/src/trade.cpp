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
