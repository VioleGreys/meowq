// Воздушный бой района — перенос Forces.air_region_gd (scripts/sim/forces.gd)
// один в один: тот же порядок обхода, те же формулы в double, те же вызовы ГСЧ.
// Результаты обязаны совпадать с GDScript до бита (perf_bench «Подпись»).
#include "meowq_core.h"

#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <algorithm>
#include <map>
#include <vector>

using namespace godot;

PackedFloat64Array MeowqCore::air_region(const Dictionary &t, int i) const {
	const int nc = int(t["nc"]);
	const PackedByteArray ally_a = t["ally"], war_a = t["war"];
	const PackedFloat64Array det_a = t["det"], kk = t["kk"];
	const PackedInt32Array rstart = t["rstart"];
	const PackedInt64Array seeds = t["seeds"];
	const PackedInt32Array ow0 = t["ow"], kd0 = t["kd"], wid0 = t["wid"];
	const PackedFloat64Array pl0 = t["pl"], ae0 = t["ae"], de0 = t["de"], co0 = t["co"], gr0 = t["gr"];
	const uint8_t *ally = ally_a.ptr(), *war = war_a.ptr();
	const double *det = det_a.ptr();
	const double pack_n = kk[0];
	const int width = int(kk[1]);
	const double kill = kk[2], loss_max = kk[3], night_k = kk[4], pen = kk[5], full = kk[6], cas_max = kk[7];
	const int s0 = rstart[i];
	const int cnt = rstart[i + 1] - s0;
	Ref<RandomNumberGenerator> rng;
	rng.instantiate();
	rng->set_seed(uint64_t(seeds[i]));

	std::vector<int32_t> ow(cnt), kd(cnt), wid(cnt), side(cnt);
	std::vector<double> pl(cnt), ae(cnt), de(cnt), co(cnt), gr(cnt);
	for (int j = 0; j < cnt; j++) {
		ow[j] = ow0[s0 + j];
		kd[j] = kd0[s0 + j];
		wid[j] = wid0[s0 + j];
		pl[j] = pl0[s0 + j];
		ae[j] = ae0[s0 + j];
		de[j] = de0[s0 + j];
		co[j] = co0[s0 + j];
		gr[j] = gr0[s0 + j];
	}
	// стороны: союзники — одна сторона (номер — меньший из союзных владельцев)
	for (int j = 0; j < cnt; j++) {
		side[j] = ow[j];
		for (int k = 0; k < cnt; k++) {
			if (ow[k] < side[j] && ally[int64_t(ow[j]) * nc + ow[k]] == 1) side[j] = ow[k];
		}
	}
	std::vector<int> order(cnt);
	for (int j = 0; j < cnt; j++) order[j] = j;
	std::sort(order.begin(), order.end(), [&](int a, int b) {
		if (side[a] != side[b]) return side[a] < side[b];
		if (kd[a] != kd[b]) return kd[a] < kd[b];
		if (pl[a] != pl[b]) return pl[a] > pl[b];
		return wid[a] < wid[b];
	});
	// пачки
	std::vector<int32_t> pk_side, c_pk, c_w;
	std::vector<double> pk_pl, pk_at, pk_de, pk_co, c_take;
	std::vector<double> eng(cnt, 0.0);
	std::map<int32_t, int> count_side;
	for (int j : order) {
		double left = pl[j];
		while (left > 0.001) {
			int np = int(pk_side.size());
			if (np == 0 || pk_side[np - 1] != side[j] || pk_pl[np - 1] >= pack_n - 0.001) {
				if (count_side[side[j]] >= width) break;
				pk_side.push_back(side[j]);
				pk_pl.push_back(0.0);
				pk_at.push_back(0.0);
				pk_de.push_back(0.0);
				pk_co.push_back(0.0);
				count_side[side[j]] += 1;
				np += 1;
			}
			const double take = std::min(left, pack_n - pk_pl[np - 1]);
			pk_pl[np - 1] += take;
			pk_at[np - 1] += take * ae[j];
			pk_de[np - 1] += take * de[j];
			pk_co[np - 1] += take * co[j];
			c_pk.push_back(np - 1);
			c_w.push_back(j);
			c_take.push_back(take);
			eng[j] += take;
			left -= take;
		}
	}
	const int npk = int(pk_side.size());
	for (int b = 0; b < npk; b++) {
		if (pk_pl[b] > 0.0) {
			pk_at[b] = pk_at[b] / pk_pl[b];
			pk_de[b] = pk_de[b] / pk_pl[b];
			pk_co[b] = pk_co[b] / pk_pl[b];
		}
	}
	std::vector<double> out(2 * cnt, 0.0);
	// превосходство и поправки к сухопутному бою
	std::vector<char> mark(nc, 0);
	for (int j = 0; j < cnt; j++) mark[ow[j]] = 1;
	for (int j = 0; j < cnt; j++) {
		for (int n2 = 0; n2 < nc; n2++) {
			if (war[int64_t(ow[j]) * nc + n2] == 1) mark[n2] = 1;
		}
	}
	for (int n = 0; n < nc; n++) {
		if (!mark[n]) continue;
		double own_f = 0.0, en_f = 0.0, own_b = 0.0;
		for (int j = 0; j < cnt; j++) {
			const int32_t o = ow[j];
			if (kd[j] == 0) {
				const double pw = eng[j] * (ae[j] + de[j]);
				if (ally[int64_t(n) * nc + o] == 1) own_f += pw;
				else if (n != o && war[int64_t(n) * nc + o] == 1) en_f += pw;
			} else if (ally[int64_t(n) * nc + o] == 1) {
				own_b += pl[j] * gr[j];
			}
		}
		const double sup = own_f + en_f <= 0.0 ? 0.5 : own_f / (own_f + en_f);
		double m = 1.0 + std::min(cas_max, own_b * (0.5 + sup) / 900.0);
		if (sup < 0.5) {
			const double presence = std::min(1.0, (own_f + en_f) / full);
			m -= pen * (0.5 - sup) * 2.0 * presence;
		}
		out.push_back(double(n));
		out.push_back(sup);
		out.push_back(m);
	}
	// бой днём и ночью
	std::vector<double> loss(npk, 0.0), xpw(cnt, 0.0);
	std::vector<int32_t> foes;
	const int ncs = int(c_pk.size());
	for (int phase = 0; phase < 2; phase++) {
		const double night = phase == 0 ? 1.0 : night_k;
		std::map<int32_t, int32_t> prev_target;
		int ci = 0;
		for (int a = 0; a < npk; a++) {
			const int c0 = ci;
			while (ci < ncs && c_pk[ci] == a) ci++;
			foes.clear();
			for (int b = 0; b < npk; b++) {
				if (war[int64_t(pk_side[a]) * nc + pk_side[b]] == 1) foes.push_back(b);
			}
			if (foes.empty()) continue;
			if (phase == 0) {
				for (int c = c0; c < ci; c++) xpw[c_w[c]] += c_take[c] / pack_n;
			}
			if (double(rng->randf()) >= det[pk_side[a]] * night) continue;
			const double coord = pk_co[a] * night;
			int32_t tg = foes[int64_t(rng->randi()) % int64_t(foes.size())];
			auto it = prev_target.find(pk_side[a]);
			const int32_t pt = it == prev_target.end() ? -1 : it->second;
			if (pt >= 0 && std::find(foes.begin(), foes.end(), pt) != foes.end() && double(rng->randf()) < coord) tg = pt;
			prev_target[pk_side[a]] = tg;
			const double engaged = pk_pl[a] * (0.5 + 0.5 * coord);
			loss[tg] += 0.5 * engaged * pk_at[a] * kill * double(rng->randf_range(0.7, 1.3)) / std::max(0.5, pk_de[tg]);
		}
	}
	for (int j = 0; j < cnt; j++) {
		out[j] = pl[j];
		out[cnt + j] = xpw[j];
	}
	for (int c = 0; c < ncs; c++) {
		const int b = c_pk[c];
		if (loss[b] <= 0.0) continue;
		const double frac = std::min(loss_max, loss[b] / std::max(1.0, pk_pl[b]));
		const int wj = c_w[c];
		out[wj] = std::max(0.0, out[wj] - c_take[c] * frac);
	}
	PackedFloat64Array res;
	res.resize(int64_t(out.size()));
	for (size_t k = 0; k < out.size(); k++) res[int64_t(k)] = out[k];
	return res;
}
