#!/usr/bin/env python3
"""Карта провинций для отрисовки — вдвое подробнее карты (11264×5250),
половинами запад/восток с перекрытием (как подложка, tools/build_map_art.py):
data/world1936/ids2_w.png.bin, ids2_e.png.bin (r + g·256 — номер провинции,
как provinces.png.bin; игра грузит сама и держит в видеопамяти как RG8). Симуляция её не читает: номера, площади и соседство —
по карте 5632×2625.

Каждый пиксель 2× берёт провинцию из окна 4×4 карты 1× (кубический B-сплайн,
как сглаживание границ в шейдере) с условиями по векторным контурам Natural
Earth, нарисованным в 2×: суша/вода — по доле суши (relief.png.bin, канал b),
область admin-1 — по контуру. Так границы стран и областей и берег идут по
вектору, а не лесенкой пикселей; границы провинций внутри области — плавно.

  python3 tools/build_ids2x.py --ne папка_с_GeoJSON_Natural_Earth
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")
OUT_DIR = DATA
SCALE = 2
PAD = 32


def regions(ne: str, k: int) -> np.ndarray:
    """Растр областей admin-1 в масштабе k (как шаг 1 build_map.main, озёра — 0)."""
    adm = bm.load(os.path.join(ne, "ne_10m_admin_1_states_provinces.geojson"))["features"]
    feats = []
    for f in adm:
        p = f["properties"]
        a0 = p["adm0_a3"]
        if a0 not in bm.ADM0_TAG:
            continue
        rings = [r for r in bm.rings_of(f["geometry"]) if bm.in_window(r)]
        if rings:
            feats.append((p.get("area_sqkm") or 0, rings))
    feats.sort(key=lambda t: -t[0])
    img = Image.new("I", (bm.WIDTH * k, bm.HEIGHT * k), 0)
    d = ImageDraw.Draw(img)
    for rid, (_, rings) in enumerate(feats, start=1):
        for r in rings:
            pts = [(x * k, y * k) for x, y in bm.poly_px(r)]
            if len(pts) >= 3:
                d.polygon(pts, fill=rid)
    lakes = bm.load(os.path.join(ne, "ne_10m_lakes.geojson"))["features"]
    for f in lakes:
        if bm._rank(f["properties"].get("scalerank")) <= 4:
            for r in bm.rings_of(f["geometry"]):
                if bm.in_window(r):
                    d.polygon([(x * k, y * k) for x, y in bm.poly_px(r)], fill=0)
    return np.array(img, dtype=np.int32)


def bspline(f: np.ndarray):
    """Кубические B-сплайн веса для смещений −1, 0, 1, 2 (+ перевес ближних, как в шейдере)."""
    f2, f3 = f * f, f * f * f
    w = [(1 - f) ** 3 / 6, (3 * f3 - 6 * f2 + 4) / 6, (-3 * f3 + 3 * f2 + 3 * f + 1) / 6, f3 / 6]
    b = [np.zeros_like(f), 1 - f, f, np.zeros_like(f)]
    return [w[i] + b[i] * 0.35 for i in range(4)]


import numba  # noqa: E402

SPECK_MIN = 9       # своих пикселей в окне 5×5 меньше — осколок


@numba.njit(parallel=True, cache=True)
def _despeckle(src, out):
    H, W = src.shape
    changed = np.zeros(H, np.int64)
    for y in numba.prange(2, H - 2):
        labs = np.empty(25, np.int64)
        cnts = np.empty(25, np.int64)
        for x in range(2, W - 2):
            c = src[y, x]
            if (src[y, x - 1] == c and src[y, x + 1] == c and src[y - 1, x] == c and src[y + 1, x] == c):
                continue
            n = 0
            own = 0
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    v = src[y + dy, x + dx]
                    if v == c:
                        own += 1
                    k = -1
                    for i in range(n):
                        if labs[i] == v:
                            k = i
                            break
                    if k < 0:
                        labs[n] = v
                        cnts[n] = 1
                        n += 1
                    else:
                        cnts[k] += 1
            if own >= SPECK_MIN:
                continue
            best = -1
            bc = -1
            for i in range(n):
                if labs[i] != c and cnts[i] > bc:
                    bc = cnts[i]
                    best = labs[i]
            if best >= 0:
                out[y, x] = best
                changed[y] += 1
    return changed.sum()


@numba.njit(parallel=True, cache=True)
def _thin_assign(src, out, mask, land_of):
    H, W = src.shape
    changed = np.zeros(H, np.int64)
    for y in numba.prange(1, H - 1):
        labs = np.empty(9, np.int64)
        cnts = np.empty(9, np.int64)
        for x in range(1, W - 1):
            if not mask[y, x]:
                continue
            c = src[y, x]
            n = 0
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    v = src[y + dy, x + dx]
                    if v == c or land_of[v] != 1:
                        continue
                    k = -1
                    for i in range(n):
                        if labs[i] == v:
                            k = i
                            break
                    if k < 0:
                        labs[n] = v
                        cnts[n] = 1
                        n += 1
                    else:
                        cnts[k] += 1
            best = -1
            bc = 0
            for i in range(n):
                if cnts[i] > bc:
                    bc = cnts[i]
                    best = labs[i]
            if best >= 0:
                out[y, x] = best
                changed[y] += 1
    return changed.sum()


@numba.njit(cache=True)
def _find(par, i):
    while par[i] != i:
        par[i] = par[par[i]]
        i = par[i]
    return i


@numba.njit(cache=True)
def _regions(ids, mask):
    """Связные куски одинаковых номеров (4-соседство) среди mask; -1 вне mask."""
    H, W = ids.shape
    par = np.arange(H * W, dtype=np.int64)
    for y in range(H):
        for x in range(W):
            if not mask[y, x]:
                continue
            i = y * W + x
            if x > 0 and mask[y, x - 1] and ids[y, x - 1] == ids[y, x]:
                a = _find(par, i)
                b = _find(par, i - 1)
                if a != b:
                    par[max(a, b)] = min(a, b)
            if y > 0 and mask[y - 1, x] and ids[y - 1, x] == ids[y, x]:
                a = _find(par, i)
                b = _find(par, i - W)
                if a != b:
                    par[max(a, b)] = min(a, b)
    out = np.full((H, W), -1, np.int64)
    for y in range(H):
        for x in range(W):
            if mask[y, x]:
                out[y, x] = _find(par, y * W + x)
    return out


def river_pieces(out, land_of, near, p1=None):
    """Провинция не лежит на двух берегах (решение пользователя; в данных —
    provinces8k._enforce_rivers). В карте отрисовки привязка к рекам и
    сглаживание могли перетащить кусок провинции за реку. Барьер — лента
    реки с берегом и запасом (near, расширенный на 3 пикс. 2×): каждый кусок
    провинции, отрезанный барьером от тела (самого большого куска), отходит
    провинции, которой прямо касается на своём берегу (без порогов размера;
    без такого соседа — остаётся). Пиксели барьера — провинции ближайшего
    пикселя вне барьера: барьер симметричен осевой линии, так что это свой
    берег, и граница проходит точно по середине реки."""
    from scipy import ndimage
    bar = ndimage.binary_dilation(near, iterations=3)
    landm = land_of[out] == 1
    orig = out.copy()
    reg = _regions(out, ~bar & landm)
    ok = reg >= 0
    ur, inv, cnt = np.unique(reg[ok], return_inverse=True, return_counts=True)
    nr = len(ur)
    rid = np.full(out.shape, -1, np.int64)
    rid[ok] = inv
    prov_of = np.zeros(nr, np.int64)
    prov_of[inv] = out[ok]
    big = np.zeros(len(land_of), np.int64)
    np.maximum.at(big, prov_of, cnt)
    # тело провинции — первый из кусков максимального размера
    main = np.full(len(land_of), -1, np.int64)
    order = np.lexsort((np.arange(nr), -cnt))
    for k in order.tolist():
        if main[prov_of[k]] < 0:
            main[prov_of[k]] = k
    extra = np.nonzero(main[prov_of] != np.arange(nr))[0]
    moved_px = 0
    if extra.size:
        # прямые соседства кусков (оба пикселя вне барьера) — свой берег
        pairs = []
        for a, b in ((rid[:, :-1], rid[:, 1:]), (rid[:-1, :], rid[1:, :])):
            m = (a >= 0) & (b >= 0) & (a != b)
            pairs.append(np.stack([a[m], b[m]], 1))
        pr = np.concatenate(pairs)
        pr = np.concatenate([pr, pr[:, ::-1]])
        key = pr[:, 0] * nr + pr[:, 1]
        uk, ln = np.unique(key, return_counts=True)
        ea, eb = uk // nr, uk % nr
        own_p = np.asarray(OWN_OF)[prov_of] if OWN_OF is not None else np.zeros(nr, np.int64)
        new_p = prov_of.copy()
        pending = set(extra.tolist())
        is_extra = np.zeros(nr, bool)
        is_extra[extra] = True
        nb = {}
        for a, b, l in zip(ea.tolist(), eb.tolist(), ln.tolist()):
            if is_extra[a]:
                nb.setdefault(a, []).append((b, l))
        for _ in range(50):
            done = []
            for c in sorted(pending, key=lambda q: cnt[q]):
                best = None
                for t, l in nb.get(c, []):
                    if t in pending or new_p[t] == prov_of[c]:
                        continue
                    kk = (1 if own_p[t] == own_p[c] else 0, l)
                    if best is None or kk > best[0]:
                        best = (kk, t)
                if best is not None:
                    new_p[c] = new_p[best[1]]
                    done.append(c)
            if not done:
                break
            pending -= set(done)
        ch = new_p != prov_of
        moved_px = int(cnt[ch].sum())
        out[ok] = new_p[inv]
    # пиксели барьера (суша) — провинции ближайшего пикселя вне барьера
    src = ~bar & landm
    _, (iy, ix) = ndimage.distance_transform_edt(~src, return_indices=True)
    fill = bar & landm
    before = out[fill].copy()
    out[fill] = out[iy[fill], ix[fill]]
    changed = moved_px + int((before != out[fill]).sum())
    # провинция уже барьера (островок, полоска между близкими руслами) или
    # потерявшая больше 30 % площади — свои пиксели обратно: на карте она
    # должна быть видна целиком
    n = len(land_of)
    b0 = np.bincount(orig.ravel(), minlength=n)
    b1 = np.bincount(out.ravel(), minlength=n)
    lost = (b1 < 0.7 * b0) & (b0 > 0)
    if lost.any():
        back = lost[orig] & (out != orig)
        out[back] = orig[back]
        changed -= int(back.sum())
        print(f"  провинций сохранено от поглощения рекой: {int(lost.sum())}")
    return changed


OWN_OF = None   # страна провинции (main заполняет из map.json)


THIN_CLUSTER = 4   # полоска из стольких «тонких» пикселей 2× и больше — убрать


def thin_strips(out, land_of):
    """Полоски провинций шириной 1–2 пикселя 2× (ни одного своего квадрата
    3×3): две границы по бокам сливаются в одно тёмное пятно («наложение
    обводок»). Пиксели такой полоски (связный кусок от THIN_CLUSTER) отходят
    соседней провинции суши, которой вокруг больше."""
    from scipy import ndimage
    H, W = out.shape
    c = out[1:-1, 1:-1]
    full = np.ones((H - 2, W - 2), bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            full &= out[1 + dy:H - 1 + dy, 1 + dx:W - 1 + dx] == c
    cov = np.zeros((H, W), bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cov[1 + dy:H - 1 + dy, 1 + dx:W - 1 + dx] |= full
    del full
    thin = ~cov & (land_of[out] == 1)
    del cov
    lab, n = ndimage.label(thin, structure=np.ones((3, 3), bool))
    sz = np.bincount(lab.ravel())
    sz[0] = 0
    mask = sz[lab] >= THIN_CLUSTER
    del lab
    src = out.copy()
    return int(_thin_assign(src, out, mask, land_of.astype(np.int8)))


def despeckle(out):
    """Осколки провинций в 2–3 пикселя (после сглаживания и привязки к рекам)
    — преобладающей вокруг провинции: иначе каждый обводится и виден тёмной
    точкой или крошечной петлёй."""
    src = out.copy()
    return int(_despeckle(src, out))


SNAP_FAR = 3.2      # у реки ближе стольких пикселей карты — провинция своего берега
SNAP_SIDE = 4.2     # свой берег пробуем на таком расстоянии от осевой линии


def snap_rivers(out, land_of):
    """Граница провинций по реке — точно по осевой линии: пиксель у реки,
    разделяющей две провинции, берёт провинцию своего берега (по вектору до
    ближайшей точки реки, tools/build_rivers.py). Иначе река в 1× раздаётся
    соседям «зубцами», и после сглаживания вдоль реки — обрезки провинций, а
    линия границы выходит из-под ленты реки пунктиром."""
    path = os.path.join(DATA, "rivers.png.bin")
    if not os.path.exists(path):
        return
    rv = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    # сила реки — в канале g relief.png.bin; вектор в поле приведённый (делён
    # на относительную ширину реки) — вернуть в пиксели карты
    stg = np.asarray(Image.open(os.path.join(DATA, "relief.png.bin")).convert("RGB"))[..., 1]
    wk = np.where(stg >= 255, 1.0, np.where(stg >= 170, 0.32 / 0.42, 0.24 / 0.42)).astype(np.float32)
    vec = (rv[..., :2] - 128.0) / 127.0 * 4.0 * wk[..., None]          # RMAX build_rivers
    has = stg > 0
    d1 = np.sqrt((vec ** 2).sum(-1))   # расстояние до реки у текселя 1×, пикс. карты
    d1[~has] = 99.0
    H2, W2 = out.shape
    H, W = has.shape
    src = out.copy()
    changed = 0
    band = 256
    for y0 in range(0, H2, band):
        y1 = min(H2, y0 + band)
        ys = (np.arange(y0, y1) + 0.5) / SCALE
        xs = (np.arange(W2) + 0.5) / SCALE
        gy, gx = np.meshgrid(ys, xs, indexing="ij")
        # билинейно вектор (центры текселей 1× в +0.5)
        fx = gx - 0.5
        fy = gy - 0.5
        ix = np.clip(np.floor(fx).astype(np.int64), 0, W - 2)
        iy = np.clip(np.floor(fy).astype(np.int64), 0, H - 2)
        tx = (fx - ix)[..., None]
        ty = (fy - iy)[..., None]
        v = (vec[iy, ix] * (1 - tx) * (1 - ty) + vec[iy, ix + 1] * tx * (1 - ty)
             + vec[iy + 1, ix] * (1 - tx) * ty + vec[iy + 1, ix + 1] * tx * ty)
        hh = has[iy, ix] | has[iy, ix + 1] | has[iy + 1, ix] | has[iy + 1, ix + 1]
        d = np.sqrt((v ** 2).sum(-1))
        m = hh & (d < SNAP_FAR) & (d > 1e-3)
        if not m.any():
            continue
        yy, xx = np.nonzero(m)
        vv = v[yy, xx]
        dd = d[yy, xx][:, None]
        n = vv / dd
        rx = gx[yy, xx] + vv[:, 0]
        ry = gy[yy, xx] + vv[:, 1]
        # проба не должна перескочить через изгиб реки на тот берег (внутренняя
        # сторона излучины): если точка пробы снова у реки — проба ближе
        ps = None
        okp = np.zeros(len(yy), bool)
        for side in (SNAP_SIDE, 2.6, 1.8):
            qx = rx - n[:, 0] * side
            qy = ry - n[:, 1] * side
            q1x = np.clip(qx.astype(np.int64), 0, W - 1)
            q1y = np.clip(qy.astype(np.int64), 0, H - 1)
            dq = d1[q1y, q1x]
            good = ~okp & (dq > side * 0.6)
            sx = np.clip((qx * SCALE).astype(np.int64), 0, W2 - 1)
            sy = np.clip((qy * SCALE).astype(np.int64), 0, H2 - 1)
            cand = src[sy, sx]
            ps = cand if ps is None else np.where(good, cand, ps)
            okp |= good
        ps = np.where(okp, ps, src[y0 + yy, xx])
        cur = src[y0 + yy, xx]
        # пиксель берёт провинцию, лежащую прямо от реки на его стороне: и
        # у реки-раздела (полоска провинции того берега на этом), и у границы
        # районов (geoBoundaries), смещённой от линии Natural Earth на 1–3
        # пикс., — иначе вдоль берега тянулась отдельная линия или «крючок»;
        # линии провинций подходят к реке поперёк
        ok = (ps != cur) & (land_of[ps] == 1) & (land_of[cur] == 1)
        out[y0 + yy[ok], xx[ok]] = ps[ok]
        changed += int(ok.sum())
    # узкая провинция у реки (полоса между рукавами) не должна исчезнуть с
    # карты отрисовки: потерявшей больше 40 % пикселей возвращаем её пиксели
    n = int(max(src.max(), out.max())) + 1
    before = np.bincount(src.ravel(), minlength=n)
    after = np.bincount(out.ravel(), minlength=n)
    lost = (after < before * 0.6) & (before > 0)
    if lost.any():
        back = lost[src] & (out != src)
        out[back] = src[back]
        changed -= int(back.sum())
    print(f"Пикселей 2× у рек отдано своему берегу: {changed} (провинций сохранено от поглощения: {int(lost.sum())})")
    # барьер для поиска кусков за рекой — вся видимая лента у крупного плана
    # (приведённое расстояние < 1,5: полуширина крупной реки 1,22 + берег):
    # кусок провинции, отрезанный лентой от тела, на карте выглядит обрывком
    near = np.repeat(np.repeat((d1 / wk < 1.5) & has, SCALE, 0), SCALE, 1)
    return near[:H2, :W2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ne", required=True)
    args = ap.parse_args()
    W, H = bm.WIDTH, bm.HEIGHT
    W2, H2 = W * SCALE, H * SCALE
    rgb = np.asarray(Image.open(os.path.join(DATA, "provinces.png.bin")).convert("RGB")).astype(np.int32)
    p1 = rgb[..., 0] + rgb[..., 1] * 256
    meta = json.load(open(os.path.join(DATA, "map.json")))
    land_of = np.array([pr["land"] for pr in meta["provinces"]], np.int8)
    global OWN_OF
    tags = {}
    OWN_OF = np.array([tags.setdefault(pr.get("owner", ""), len(tags)) for pr in meta["provinces"]], np.int64)
    np_ = land_of.size
    # область каждой провинции суши — чаще всего встречающаяся на её пикселях (1×)
    r1 = regions(args.ne, 1)
    key = p1.astype(np.int64) * 100000 + r1
    u, cnt = np.unique(key[land_of[p1] == 1], return_counts=True)
    reg_of = np.full(np_, -1, np.int64)
    best = np.zeros(np_, np.int64)
    for kk, c in zip(u, cnt):
        p = int(kk // 100000)
        if c > best[p]:
            best[p] = c
            reg_of[p] = kk % 100000
    del r1, key
    r2 = regions(args.ne, SCALE)
    cov = np.asarray(Image.open(os.path.join(DATA, "relief.png.bin")).convert("RGB"))[..., 2]
    land2 = np.asarray(Image.fromarray(cov).resize((W2, H2), Image.BILINEAR)) >= 128
    out = np.zeros((H2, W2), np.int32)
    xs = (np.arange(W2) + 0.5) / SCALE - 0.5
    ix0 = np.floor(xs).astype(np.int64)
    fx = (xs - ix0).astype(np.float32)
    wx = bspline(fx)
    band = 64
    for y0 in range(0, H2, band):
        y1 = min(H2, y0 + band)
        ys = (np.arange(y0, y1) + 0.5) / SCALE - 0.5
        iy0 = np.floor(ys).astype(np.int64)
        fy = (ys - iy0).astype(np.float32)
        wy = bspline(fy)
        labs = []
        wts = []
        for oy in range(4):
            yy = np.clip(iy0 + oy - 1, 0, H - 1)
            for ox in range(4):
                xx = np.clip(ix0 + ox - 1, 0, W - 1)
                labs.append(p1[yy][:, xx])
                wts.append(wy[oy][:, None] * wx[ox][None, :])
        L = np.stack(labs, -1)
        Wt = np.stack(wts, -1)
        # одинаковые провинции в окне — веса складываются
        tot = np.zeros_like(Wt)
        for i in range(16):
            tot[..., i] = (Wt * (L == L[..., i:i + 1])).sum(-1)
        ld = land2[y0:y1][..., None]
        rg = r2[y0:y1][..., None]
        is_land = land_of[L] == 1
        score = tot + 4.0 * (is_land == ld) + 2.0 * (is_land & ld & (reg_of[L] == rg))
        k = np.argmax(score, -1)
        out[y0:y1] = np.take_along_axis(L, k[..., None], -1)[..., 0]
    near = snap_rivers(out, land_of)
    if near is not None:
        print(f"Пикселей кусков провинций за рекой отдано окружающим (пикс. 2×): {river_pieces(out, land_of, near, p1)}")
    for _ in range(4):
        n = thin_strips(out, land_of)
        print(f"Пикселей тонких полосок отдано соседям (пикс. 2×): {n}")
        if n == 0:
            break
    for _ in range(8):
        n = despeckle(out)
        print(f"Осколков провинций убрано (пикс. 2×): {n}")
        if n == 0:
            break
    if near is not None:
        # чистка полосок и осколков могла отдать куску за рекой пиксели из-под
        # ленты — ещё раз (и осколки после неё)
        print(f"Пикселей кусков за рекой (второй проход): {river_pieces(out, land_of, near, p1)}")
        print(f"Осколков провинций убрано (пикс. 2×): {despeckle(out)}")
    os.makedirs(OUT_DIR, exist_ok=True)
    half = W2 // 2
    for nm, a in (("w", out[:, : half + PAD]), ("e", out[:, half - PAD:])):
        img = np.zeros(a.shape + (3,), np.uint8)
        img[..., 0] = a & 255
        img[..., 1] = (a >> 8) & 255
        path = os.path.abspath(os.path.join(OUT_DIR, f"ids2_{nm}.png.bin"))
        Image.fromarray(img, "RGB").save(path, "PNG", optimize=True)
        print(f"ids_{nm} {a.shape[1]}x{a.shape[0]}: {path} ({os.path.getsize(path) // 1024} КБ)")
    changed = (out[::SCALE, ::SCALE] != p1).mean()
    print(f"Доля пикселей 1×, сменивших провинцию: {changed:.4f}")


if __name__ == "__main__":
    sys.exit(main())
