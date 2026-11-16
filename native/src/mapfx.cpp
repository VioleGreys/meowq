// Кайма границ стран на карте (MapView.update_palette, только вид): расстояние
// от каждого пикселя сетки в четверть карты до ближайшей границы двух стран
// (суша к суше), двухпроходная фаска 3-4 — пересчёт при смене владельцев.
#include "meowq_core.h"

#include <algorithm>
#include <vector>

using namespace godot;

// ids — RGB8 карта провинций W×H (r + g·256), сетка — каждый step-й пиксель
// (центры клеток step×step), ctrl — хозяин провинции (−1 — море), maxd —
// предел (пиксели сетки). → L8 (W/step)×(H/step): 255 у самой границы, 0 —
// дальше maxd (линейно).
PackedByteArray MeowqCore::border_band(const PackedByteArray &ids, int W, int H, int step, const PackedInt32Array &ctrl, int maxd) const {
	const int w = W / step, h = H / step;
	const int n = w * h;
	PackedByteArray out;
	out.resize(n);
	if (ids.size() < int64_t(W) * H * 3 || maxd <= 0 || n <= 0) {
		out.fill(0);
		return out;
	}
	const uint8_t *iv = ids.ptr();
	const int32_t *ct = ctrl.ptr();
	const int nc = int(ctrl.size());
	std::vector<int32_t> c(n);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const int64_t k = (int64_t(y * step + step / 2) * W + (x * step + step / 2)) * 3;
			const int p = iv[k] + iv[k + 1] * 256;
			c[y * w + x] = (p >= 0 && p < nc) ? ct[p] : -1;
		}
	}
	const int INF = 1 << 28;
	std::vector<int> d(n, INF);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const int i = y * w + x;
			const int a = c[i];
			if (a < 0) continue;
			if ((x + 1 < w && c[i + 1] >= 0 && c[i + 1] != a) || (x > 0 && c[i - 1] >= 0 && c[i - 1] != a)
					|| (y + 1 < h && c[i + w] >= 0 && c[i + w] != a) || (y > 0 && c[i - w] >= 0 && c[i - w] != a))
				d[i] = 0;
		}
	}
	// фаска 3-4: вперёд и назад
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const int i = y * w + x;
			int v = d[i];
			if (x > 0) v = std::min(v, d[i - 1] + 3);
			if (y > 0) {
				v = std::min(v, d[i - w] + 3);
				if (x > 0) v = std::min(v, d[i - w - 1] + 4);
				if (x + 1 < w) v = std::min(v, d[i - w + 1] + 4);
			}
			d[i] = v;
		}
	}
	for (int y = h - 1; y >= 0; y--) {
		for (int x = w - 1; x >= 0; x--) {
			const int i = y * w + x;
			int v = d[i];
			if (x + 1 < w) v = std::min(v, d[i + 1] + 3);
			if (y + 1 < h) {
				v = std::min(v, d[i + w] + 3);
				if (x + 1 < w) v = std::min(v, d[i + w + 1] + 4);
				if (x > 0) v = std::min(v, d[i + w - 1] + 4);
			}
			d[i] = v;
		}
	}
	uint8_t *o = out.ptrw();
	const double lim = maxd * 3.0;
	for (int i = 0; i < n; i++) {
		if (c[i] < 0) {
			o[i] = 0;
			continue;
		}
		const double t = 1.0 - std::min(1.0, d[i] / lim);
		o[i] = uint8_t(t * 255.0 + 0.5);
	}
	return out;
}
