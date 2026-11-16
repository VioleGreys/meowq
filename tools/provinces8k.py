"""Нарезка суши на области и провинции из административных районов и рек
(для tools/build_map.py). Как в стратегиях жанра: провинция целиком лежит в
своей области, области — по реальным регионам страны (мелкие склеены,
огромные поделены), провинции — неровные: собраны из районов (geoBoundaries
ADM2), разрезанных крупными реками; граница провинций по возможности идёт по
реке (переход через реку в игре штрафуется — признак на ребре соседства).

Порядок:
  1. «атомы» — связные куски (страна × область admin-1 × район ADM2), реки
     вырезаны (пиксели реки потом отданы соседним атомам — река становится
     краем атома); крошечные атомы вливаются в соседа той же области;
     атомы крупнее провинции режутся на части (k-средних по пикселям);
  2. области: регионы admin-1 одной страны; мелкие склеиваются с соседом,
     крупные делятся на k частей ростом по графу атомов;
  3. провинции: каждая область делится на k = площадь / целевая частей ростом
     по графу атомов от затравок (Дейкстра; ребро через реку дороже) — части
     связные, границы тянутся к рекам.
"""
import heapq
import math

import numpy as np
from scipy import ndimage
from scipy.spatial import cKDTree

RIVER_COST = 6.0        # во сколько раз дороже шаг через реку при росте областей
RIVER_EDGE = 0.4        # граница по реке больше этой доли — «через реку»: провинции
                        # реку не переходят (решение пользователя, ноябрь 2026)
MIN_ATOM = 6            # атомы меньше (пикс.) вливаются в соседа
STATE_PROVS = 9.5       # провинций суши в области (как в жанре: ~10 тыс. суши на ~1,1 тыс. областей)
STATE_MERGE_BELOW = 0.85  # область мельче (доля целевой) — склеить с соседней
STATE_MERGE_MAX = 2.0     # если вместе не крупнее (доля целевой)
STATE_SPLIT = 1.6         # крупнее — делить на части по столько
ELONG = 3.0              # отношение главных осей куска больше — «полоса», резать поперёк
THIN_FRAC = 0.8          # доля пикселей у края больше — «тонкий» кусок (полоска)
ISLAND_UNITS = 0.33       # остров меньше (доля провинции) — к провинции ближнего берега
ISLAND_KM = 300.0         # не дальше


def _relabel(a):
    u, inv = np.unique(a, return_inverse=True)
    return inv.reshape(a.shape).astype(np.int32), u


def _pairs(lab):
    """Пары соседних пикселей разных меток (4-связность): (u, v) с повторами."""
    a = lab[:, :-1].ravel(); b = lab[:, 1:].ravel()
    c = lab[:-1, :].ravel(); d = lab[1:, :].ravel()
    u = np.concatenate([a, c]); v = np.concatenate([b, d])
    m = (u != v) & (u >= 0) & (v >= 0)
    return u[m], v[m]


def _edge_table(lab, n, river=None):
    """Рёбра графа меток: (u<v) → длина общей границы и сколько из неё — по реке."""
    a = lab[:, :-1]; b = lab[:, 1:]
    c = lab[:-1, :]; d = lab[1:, :]
    u = np.concatenate([a.ravel(), c.ravel()]); v = np.concatenate([b.ravel(), d.ravel()])
    if river is not None:
        ra = river[:, :-1] | river[:, 1:]
        rc = river[:-1, :] | river[1:, :]
        r = np.concatenate([ra.ravel(), rc.ravel()])
    m = (u != v) & (u >= 0) & (v >= 0)
    u, v = u[m], v[m]
    lo = np.minimum(u, v).astype(np.int64); hi = np.maximum(u, v).astype(np.int64)
    key = lo * n + hi
    uk, inv = np.unique(key, return_inverse=True)
    length = np.bincount(inv)
    rl = np.bincount(inv, weights=r[m].astype(np.float64)) if river is not None else np.zeros_like(length, np.float64)
    return (uk // n).astype(np.int32), (uk % n).astype(np.int32), length, rl


def _grow(nodes, k, cx, cy, area, nbr, rng, iters=4):
    """Делит связный набор узлов графа на k частей ростом от затравок.
    nbr[u] — список (v, вес шага-множитель). Возвращает метку части для узлов."""
    nodes = list(nodes)
    if k <= 1 or len(nodes) <= 1:
        return {u: 0 for u in nodes}
    k = min(k, len(nodes))
    idx = np.array(nodes)
    w = area[idx].astype(np.float64)
    # затравки: k-средних по центрам узлов с весом площади
    pts = np.stack([cx[idx], cy[idx]], 1)
    seeds = pts[rng.choice(len(idx), size=k, replace=False, p=w / w.sum())]
    for _ in range(6):
        _, lab = cKDTree(seeds).query(pts)
        for j in range(k):
            m = lab == j
            if m.any():
                seeds[j] = (pts[m] * w[m, None]).sum(0) / w[m].sum()
    in_set = set(nodes)
    lab = {}
    for it in range(iters):
        # затравка — узел, ближайший к центру части
        _, sidx = cKDTree(pts).query(seeds)
        src = {}
        for j, si in enumerate(sidx):
            src.setdefault(int(idx[si]), j)
        dist = {}
        lab = {}
        heap = [(0.0, u, j) for u, j in src.items()]
        heapq.heapify(heap)
        while heap:
            dd, u, j = heapq.heappop(heap)
            if u in lab:
                continue
            lab[u] = j
            for v, mult in nbr[u]:
                if v in lab or v not in in_set:
                    continue
                step = math.hypot(cx[u] - cx[v], cy[u] - cy[v]) * mult
                nd = dd + step
                if nd < dist.get(v, 1e30):
                    dist[v] = nd
                    heapq.heappush(heap, (nd, v, j))
        for u in nodes:            # недостижимые (не должно быть) — к ближайшей затравке
            if u not in lab:
                lab[u] = int(cKDTree(seeds).query([cx[u], cy[u]])[1])
        if it == iters - 1:
            break
        # сдвиг затравок к центру масс части; части с перебором площади тянут затравку
        tot = np.zeros(k); sx = np.zeros(k); sy = np.zeros(k)
        for u, j in lab.items():
            tot[j] += area[u]; sx[j] += area[u] * cx[u]; sy[j] += area[u] * cy[u]
        ok = tot > 0
        seeds[ok, 0] = sx[ok] / tot[ok]
        seeds[ok, 1] = sy[ok] / tot[ok]
    return lab


def build(owner, region, land, area_px, river_cut, river_cls, adm2, lat_px_km, rng, region_tag_ok=None):
    """owner, region, adm2 — растры (−1/0 — нет); area_px — целевая площадь
    провинции в пикселях; river_cut — маска пикселей крупных рек (разрез);
    river_cls — класс реки на пикселе (1 малая, 2 крупная).
    Возвращает prov (−1 — вода), state_of[prov], n_land, rivers_adj {(u,v): класс}."""
    H, W = owner.shape
    # --- 1. атомы ------------------------------------------------------------
    key = np.where(land, (owner.astype(np.int64) + 1) * 1_000_000_000 + region.astype(np.int64) * 100_000
                   + (adm2.astype(np.int64) % 100_000), -1)
    cut = land & river_cut
    key_c = np.where(cut, -1, key)
    lab = np.full((H, W), -1, np.int32)
    keyu, keyinv = np.unique(key_c[key_c >= 0], return_inverse=True)
    kimg = np.full((H, W), -1, np.int64)
    kimg[key_c >= 0] = keyinv
    # связные куски каждого ключа: метки по 4-связности на изображении ключей
    # (граница между разными ключами разрывает связность)
    nxt = 0
    same_r = np.zeros((H, W), bool); same_d = np.zeros((H, W), bool)
    same_r[:, :-1] = (kimg[:, :-1] == kimg[:, 1:]) & (kimg[:, :-1] >= 0)
    same_d[:-1, :] = (kimg[:-1, :] == kimg[1:, :]) & (kimg[:-1, :] >= 0)
    lab = _components(kimg >= 0, same_r, same_d)
    n_atoms = int(lab.max()) + 1
    # пиксели рек — ближайшему атому той же страны и области (по ключу без района)
    if cut.any():
        idx = ndimage.distance_transform_edt(lab < 0, return_distances=False, return_indices=True)
        fill = lab[idx[0], idx[1]]
        lab = np.where(cut & (lab < 0), fill, lab)
    lab = np.where(land, lab, -1)
    # оставшиеся пиксели суши без атома — ближайшему
    if ((lab < 0) & land).any():
        idx = ndimage.distance_transform_edt(lab < 0, return_distances=False, return_indices=True)
        lab = np.where(land & (lab < 0), lab[idx[0], idx[1]], lab)
    lab, _ = _relabel_keep_neg(lab)
    n_atoms = int(lab.max()) + 1
    print(f"  атомов: {n_atoms}", flush=True)

    # --- свойства атомов ---------------------------------------------------
    flat = lab.ravel(); ok = flat >= 0
    yy, xx = np.mgrid[0:H, 0:W]
    cnt = np.bincount(flat[ok], minlength=n_atoms).astype(np.float64)
    cx = np.bincount(flat[ok], weights=xx.ravel()[ok] + 0.5, minlength=n_atoms) / np.maximum(cnt, 1)
    cy = np.bincount(flat[ok], weights=yy.ravel()[ok] + 0.5, minlength=n_atoms) / np.maximum(cnt, 1)
    a_own = np.full(n_atoms, -1, np.int64); a_own[flat[ok]] = owner.ravel()[ok]
    a_reg = np.zeros(n_atoms, np.int64); a_reg[flat[ok]] = region.ravel()[ok]
    a_tgt = np.bincount(flat[ok], weights=area_px.ravel()[ok], minlength=n_atoms) / np.maximum(cnt, 1)

    # крошечные и тонкие атомы (полоски по стыку контуров Natural Earth и
    # geoBoundaries: 1–2 пикс. шириной, длинные) — в соседа той же страны (лучше
    # той же области) с самой длинной общей границей
    for _ in range(8):
        u, v, ln, rl = _edge_table(lab, n_atoms, cut)
        thin = _edge_count(lab, n_atoms) > THIN_FRAC * cnt
        small = (cnt < MIN_ATOM) | thin
        if not small.any():
            break
        best = {}
        for a, b, l, r in zip(u.tolist(), v.tolist(), ln.tolist(), rl.tolist()):
            for s_, t in ((a, b), (b, a)):
                if small[s_] and a_own[s_] == a_own[t]:
                    # через реку — только если на своём берегу соседа нет
                    key = (0 if r > RIVER_EDGE * l else 1, 1 if a_reg[s_] == a_reg[t] else 0, 0 if small[t] else 1, l)
                    if key > best.get(s_, ((-1, -1, -1, 0), -1))[0]:
                        best[s_] = (key, t)
        if not best:
            break
        remap = np.arange(n_atoms)
        done = set()
        for s_ in sorted(best, key=lambda q: cnt[q]):
            t = best[s_][1]
            if s_ in done or t in done:
                continue
            remap[s_] = t
            done.add(s_)
            done.add(t)
        lab = np.where(lab >= 0, remap[np.maximum(lab, 0)], -1)
        lab, _ = _relabel_keep_neg(lab)
        n_atoms = int(lab.max()) + 1
        flat = lab.ravel(); ok = flat >= 0
        cnt = np.bincount(flat[ok], minlength=n_atoms).astype(np.float64)
        cx = np.bincount(flat[ok], weights=xx.ravel()[ok] + 0.5, minlength=n_atoms) / np.maximum(cnt, 1)
        cy = np.bincount(flat[ok], weights=yy.ravel()[ok] + 0.5, minlength=n_atoms) / np.maximum(cnt, 1)
        a_own = np.full(n_atoms, -1, np.int64); a_own[flat[ok]] = owner.ravel()[ok]
        a_reg = np.zeros(n_atoms, np.int64); a_reg[flat[ok]] = region.ravel()[ok]
        a_tgt = np.bincount(flat[ok], weights=area_px.ravel()[ok], minlength=n_atoms) / np.maximum(cnt, 1)

    # атомы крупнее 1,4 провинции — режем k-средними по пикселям (тайга, пустыни)
    # и вытянутые (полосы наискось: отношение главных осей > ELONG) крупнее 0,7 провинции
    elg = _elongation(lab, n_atoms, xx, yy, cnt)
    big = np.nonzero((cnt > 1.4 * a_tgt) | ((elg > ELONG) & (cnt > 0.7 * a_tgt)))[0]
    if big.size:
        objs = ndimage.find_objects(lab + 1)
        nxt = n_atoms
        for a in big.tolist():
            sl = objs[a]
            sub = lab[sl] == a
            ys, xs = np.nonzero(sub)
            k = int(round(cnt[a] / a_tgt[a]))
            if elg[a] > ELONG:
                k = max(k, 2, int(round(elg[a] / 2.0)))
            if k < 2:
                continue
            pts = np.stack([xs, ys], 1).astype(np.float64)
            seeds = pts[rng.choice(len(pts), size=k, replace=False)]
            samp = pts if len(pts) <= 40000 else pts[rng.choice(len(pts), 40000, replace=False)]
            for _ in range(8):
                _, sl_lab = cKDTree(seeds).query(samp)
                for j in range(k):
                    m = sl_lab == j
                    if m.any():
                        seeds[j] = samp[m].mean(0)
            _, pl = cKDTree(seeds).query(pts)
            ys0 = ys + sl[0].start; xs0 = xs + sl[1].start
            newid = np.where(pl == 0, a, nxt + pl - 1)
            lab[ys0, xs0] = newid
            nxt += k - 1
        lab, _ = _relabel_keep_neg(lab)
        n_atoms = int(lab.max()) + 1
        flat = lab.ravel(); ok = flat >= 0
        cnt = np.bincount(flat[ok], minlength=n_atoms).astype(np.float64)
        cx = np.bincount(flat[ok], weights=xx.ravel()[ok] + 0.5, minlength=n_atoms) / np.maximum(cnt, 1)
        cy = np.bincount(flat[ok], weights=yy.ravel()[ok] + 0.5, minlength=n_atoms) / np.maximum(cnt, 1)
        a_own = np.full(n_atoms, -1, np.int64); a_own[flat[ok]] = owner.ravel()[ok]
        a_reg = np.zeros(n_atoms, np.int64); a_reg[flat[ok]] = region.ravel()[ok]
        a_tgt = np.bincount(flat[ok], weights=area_px.ravel()[ok], minlength=n_atoms) / np.maximum(cnt, 1)
    print(f"  атомов после разрезки крупных: {n_atoms}", flush=True)

    # граф атомов: шаг через реку дороже
    u, v, ln, rl = _edge_table(lab, n_atoms, river_cut)
    nbr = [[] for _ in range(n_atoms)]
    nbr_p = [[] for _ in range(n_atoms)]   # для провинций — без рёбер через реку
    for a, b, l, r in zip(u.tolist(), v.tolist(), ln.tolist(), rl.tolist()):
        if a_own[a] != a_own[b]:
            continue
        across = r > RIVER_EDGE * l
        mult = RIVER_COST if across else 1.0
        nbr[a].append((b, mult))
        nbr[b].append((a, mult))
        if not across:
            nbr_p[a].append((b, 1.0))
            nbr_p[b].append((a, 1.0))
    # «вес» атома для роста частей — доля целевой провинции
    unit = cnt / np.maximum(a_tgt, 1.0)

    # мелкие острова (куски страны без соседей той же страны, меньше трети
    # провинции) — связь с ближайшим атомом своей страны не дальше ISLAND_KM:
    # остров войдёт в провинцию соседнего берега (как прежде), а не будет
    # отдельной провинцией и областью
    parent = list(range(n_atoms))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for a in range(n_atoms):
        for b, _ in nbr[a]:
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[ra] = rb
    roots = np.array([find(a) for a in range(n_atoms)])
    c_units = np.bincount(roots, weights=unit, minlength=n_atoms)
    linked = 0
    for o in np.unique(a_own[a_own >= 0]).tolist():
        ids = np.nonzero(a_own == o)[0]
        if np.unique(roots[ids]).size < 2:
            continue
        tree = cKDTree(np.stack([cx[ids], cy[ids]], 1))
        small = sorted({int(roots[a]) for a in ids if c_units[find(int(a))] < ISLAND_UNITS},
                       key=lambda r: c_units[r])
        for r in small:
            rr = find(r)
            if c_units[rr] >= ISLAND_UNITS:
                continue
            mem = [int(a) for a in ids if find(int(a)) == rr]
            best = (1e18, -1, -1)
            for a in mem:
                kk = min(len(ids), 24)
                dd, jj = tree.query([cx[a], cy[a]], k=kk)
                for d_, j_ in zip(np.atleast_1d(dd), np.atleast_1d(jj)):
                    b = int(ids[j_])
                    if find(b) != rr and d_ < best[0]:
                        best = (float(d_), a, b)
                        break
            if best[1] < 0:
                continue
            km = best[0] * (lat_px_km[int(cy[best[1]])] if lat_px_km is not None else 7.0)
            if km > ISLAND_KM:
                continue
            a, b = best[1], best[2]
            nbr[a].append((b, 1.0))
            nbr[b].append((a, 1.0))
            nbr_p[a].append((b, 1.0))   # остров — через море, не через реку
            nbr_p[b].append((a, 1.0))
            rb = find(b)
            parent[rr] = rb
            c_units[rb] += c_units[rr]
            linked += 1
    print(f"  островов присоединено к берегу: {linked}", flush=True)

    # --- 2. области -----------------------------------------------------------
    # регион admin-1 одной страны, связный по графу атомов
    st_key = a_own * 100_000 + a_reg
    st_of = np.full(n_atoms, -1, np.int64)
    n_st = 0
    for a in range(n_atoms):
        if st_of[a] >= 0:
            continue
        st_of[a] = n_st
        stack = [a]
        while stack:
            x = stack.pop()
            for y, _ in nbr[x]:
                if st_of[y] < 0 and st_key[y] == st_key[a]:
                    st_of[y] = n_st
                    stack.append(y)
        n_st += 1
    st_units = np.bincount(st_of, weights=unit, minlength=n_st)
    # мелкие области — к соседней области той же страны и того же admin-1-страны
    # (сначала самой мелкой), пока не наберут половину целевой
    changed = True
    while changed:
        changed = False
        st_units = np.bincount(st_of, weights=unit, minlength=n_st)
        border = {}
        for a in range(n_atoms):
            for b, _ in nbr[a]:
                sa, sb = st_of[a], st_of[b]
                if sa != sb:
                    border[(sa, sb)] = border.get((sa, sb), 0) + 1
        order = np.argsort(st_units)
        merged = set()
        for s in order.tolist():
            if st_units[s] <= 0 or st_units[s] >= STATE_PROVS * STATE_MERGE_BELOW or s in merged:
                continue
            cands = [(st_units[t], t) for (x, t), c in border.items() if x == s and t not in merged]
            if not cands:
                continue
            # к самой мелкой соседней (склеиваем мелочь в разумные области)
            _, t = min(cands)
            if st_units[t] + st_units[s] > STATE_PROVS * STATE_MERGE_MAX:
                continue
            st_of[st_of == s] = t
            merged.add(s); merged.add(t)
            changed = True
    st_of, _ = _relabel(st_of)
    n_st = int(st_of.max()) + 1
    # крупные области — делим на части ростом по графу
    st_units = np.bincount(st_of, weights=unit, minlength=n_st)
    nxt = n_st
    for s in range(n_st):
        k = int(round(st_units[s] / (STATE_PROVS * STATE_SPLIT)))
        if k < 2:
            continue
        nodes = np.nonzero(st_of == s)[0].tolist()
        part = _grow(nodes, k, cx, cy, unit, nbr, rng)
        for a, j in part.items():
            if j > 0:
                st_of[a] = nxt + j - 1
        nxt += k - 1
    st_of, _ = _relabel(st_of)
    n_st = int(st_of.max()) + 1
    print(f"  областей: {n_st}", flush=True)

    # --- 3. провинции ---------------------------------------------------------
    pr_of = np.full(n_atoms, -1, np.int64)
    st_units = np.bincount(st_of, weights=unit, minlength=n_st)
    n_pr = 0
    prov_state = []
    for s in range(n_st):
        # провинция не переходит реку (решение пользователя): область делим на
        # куски, связные без рёбер через реку, и растим провинции в каждом
        left = set(np.nonzero(st_of == s)[0].tolist())
        comps = []
        while left:
            a0 = left.pop()
            comp = [a0]
            stack = [a0]
            while stack:
                x = stack.pop()
                for y, _ in nbr_p[x]:
                    if y in left:
                        left.remove(y)
                        comp.append(y)
                        stack.append(y)
            comps.append(comp)
        for nodes in comps:
            cu = float(unit[nodes].sum())
            k = max(1, int(round(cu)))
            k = min(k, len(nodes))
            part = _grow(nodes, k, cx, cy, unit, nbr_p, rng)
            used = sorted(set(part.values()))
            remap = {j: n_pr + i for i, j in enumerate(used)}
            for a, j in part.items():
                pr_of[a] = remap[j]
            for _ in used:
                prov_state.append(s)
            n_pr += len(used)
    prov = np.where(lab >= 0, pr_of[np.maximum(lab, 0)], -1).astype(np.int32)
    # части могли выйти несвязными (через ребро другой страны) — куски к соседу
    prov, prov_state = _fix_disconnected(prov, np.array(prov_state), owner, cut)
    prov, prov_state = _merge_small(prov, prov_state, owner, area_px, cut)
    prov, prov_state = _split_elongated(prov, prov_state, area_px)
    prov, prov_state = _enforce_rivers(prov, prov_state, cut, owner, area_px)
    n_pr = int(prov.max()) + 1
    print(f"  провинций суши: {n_pr}", flush=True)
    return prov, prov_state, n_pr


def _elongation(lab, n, xx, yy, cnt):
    """Вытянутость каждой метки: корень отношения собственных чисел ковариации
    координат пикселей (полоса наискось ловится, в отличие от рамки)."""
    f = lab.ravel()
    ok = f >= 0
    f = f[ok]
    x = xx.ravel()[ok].astype(np.float64)
    y = yy.ravel()[ok].astype(np.float64)
    c = np.maximum(cnt, 1.0)
    mx = np.bincount(f, x, n) / c
    my = np.bincount(f, y, n) / c
    sxx = np.bincount(f, x * x, n) / c - mx * mx
    syy = np.bincount(f, y * y, n) / c - my * my
    sxy = np.bincount(f, x * y, n) / c - mx * my
    tr = sxx + syy
    det = sxx * syy - sxy * sxy
    disc = np.sqrt(np.maximum(tr * tr / 4 - det, 0))
    l1 = tr / 2 + disc
    l2 = np.maximum(tr / 2 - disc, 0.08)
    return np.sqrt(l1 / l2)


def _split_elongated(prov, prov_state, area_px):
    """Провинции-полосы (вытянутость > ELONG_PROV, не меньше целевой) — пополам
    поперёк длинной оси (по медиане проекции)."""
    H, W = prov.shape
    yy, xx = np.mgrid[0:H, 0:W]
    n = int(prov.max()) + 1
    flat = prov.ravel()
    ok = flat >= 0
    cnt = np.bincount(flat[ok], minlength=n).astype(np.float64)
    tgt = np.bincount(flat[ok], weights=area_px.ravel()[ok], minlength=n) / np.maximum(cnt, 1)
    elg = _elongation(prov, n, xx, yy, cnt)
    cand = np.nonzero((elg > ELONG_PROV) & (cnt > 1.0 * tgt))[0]
    if cand.size == 0:
        return prov, prov_state
    objs = ndimage.find_objects(prov + 1)
    nxt = n
    extra = []
    for i in cand.tolist():
        sl = objs[i]
        sub = prov[sl] == i
        ys, xs = np.nonzero(sub)
        pts = np.stack([xs, ys], 1).astype(np.float64)
        pts -= pts.mean(0)
        _, _, vt = np.linalg.svd(pts, full_matrices=False)
        proj = pts @ vt[0]
        half = proj > np.median(proj)
        prov[ys[half] + sl[0].start, xs[half] + sl[1].start] = nxt
        extra.append(prov_state[i])
        nxt += 1
    print(f"  провинций-полос разрезано: {len(extra)}", flush=True)
    return prov, np.concatenate([prov_state, np.array(extra, prov_state.dtype)])


def _edge_count(lab, n):
    """Сколько пикселей каждой метки лежит у края (сосед по 4-связности — другая метка)."""
    e = np.zeros(lab.shape, bool)
    d = lab[:, 1:] != lab[:, :-1]
    e[:, 1:] |= d
    e[:, :-1] |= d
    d = lab[1:, :] != lab[:-1, :]
    e[1:, :] |= d
    e[:-1, :] |= d
    m = e & (lab >= 0)
    return np.bincount(lab[m], minlength=n).astype(np.float64)


def _relabel_keep_neg(lab):
    out = np.full(lab.shape, -1, np.int32)
    m = lab >= 0
    u, inv = np.unique(lab[m], return_inverse=True)
    out[m] = inv
    return out, u


def _components(mask, same_r, same_d):
    """Связные компоненты по заданным связям вправо и вниз (union-find через scipy)."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    H, W = mask.shape
    ids = np.arange(H * W).reshape(H, W)
    r0 = ids[:, :-1][same_r[:, :-1]]; r1 = ids[:, 1:][same_r[:, :-1]]
    d0 = ids[:-1, :][same_d[:-1, :]]; d1 = ids[1:, :][same_d[:-1, :]]
    src = np.concatenate([r0, d0]); dst = np.concatenate([r1, d1])
    g = coo_matrix((np.ones(src.size, np.int8), (src, dst)), shape=(H * W, H * W))
    n, lab = connected_components(g, directed=False)
    lab = lab.reshape(H, W)
    lab = np.where(mask, lab, -1)
    out, _ = _relabel_keep_neg(lab)
    return out


def _fix_disconnected(prov, prov_state, owner, river=None):
    n = int(prov.max()) + 1
    lab, nc = ndimage.label(prov >= 0)
    # компоненты одной провинции: по 4-связности внутри провинции
    same_r = np.zeros(prov.shape, bool); same_d = np.zeros(prov.shape, bool)
    same_r[:, :-1] = (prov[:, :-1] == prov[:, 1:]) & (prov[:, :-1] >= 0)
    same_d[:-1, :] = (prov[:-1, :] == prov[1:, :]) & (prov[:-1, :] >= 0)
    comp = _components(prov >= 0, same_r, same_d)
    nc = int(comp.max()) + 1
    flat = comp.ravel(); ok = flat >= 0
    csize = np.bincount(flat[ok], minlength=nc)
    cprov = np.full(nc, -1, np.int64); cprov[flat[ok]] = prov.ravel()[ok]
    # главный кусок провинции — самый большой; остальные — к соседу той же страны
    main = np.full(n, -1, np.int64)
    order = np.argsort(-csize)
    for c in order.tolist():
        if main[cprov[c]] < 0:
            main[cprov[c]] = c
    extra = [c for c in range(nc) if main[cprov[c]] != c]
    if extra:
        u, v, ln, rl = _edge_table(comp, nc, river)
        c_own = np.full(nc, -1, np.int64); c_own[flat[ok]] = owner.ravel()[ok]
        best = {}
        ex = set(extra)
        for a, b, l, r in zip(u.tolist(), v.tolist(), ln.tolist(), rl.tolist()):
            for s, t in ((a, b), (b, a)):
                key = (0 if r > RIVER_EDGE * l else 1, l)   # сначала свой берег
                if s in ex and t not in ex and c_own[s] == c_own[t] and key > best.get(s, ((-1, 0), -1))[0]:
                    best[s] = (key, t)
        remap = cprov.copy()
        for s, (key, t) in best.items():
            remap[s] = cprov[t]
        prov = np.where(comp >= 0, remap[np.maximum(comp, 0)], -1).astype(np.int32)
    # пустые номера — убрать
    used = np.unique(prov[prov >= 0])
    m = np.full(n, -1, np.int64); m[used] = np.arange(used.size)
    prov = np.where(prov >= 0, m[np.maximum(prov, 0)], -1).astype(np.int32)
    return prov, prov_state[used]


def _enforce_rivers(prov, prov_state, cut, owner, area_px):
    """Запрет (решение пользователя): провинция не лежит на двух берегах.
    Всё, что за рекой от тела провинции (самого большого куска; пиксели
    разреза — не связь), — уже другая провинция: кусок отходит соседней
    провинции на своём берегу (лучше той же страны, иначе чужой — с её
    страной). Новых провинций не создаём, порогов размера нет. Пиксели
    разреза — ближайшему куску. Соседи «по прямому касанию» — тот же берег."""
    n = int(prov.max()) + 1
    land = prov >= 0
    free = land & ~cut
    same_r = np.zeros(prov.shape, bool); same_d = np.zeros(prov.shape, bool)
    same_r[:, :-1] = (prov[:, :-1] == prov[:, 1:]) & free[:, :-1] & free[:, 1:]
    same_d[:-1, :] = (prov[:-1, :] == prov[1:, :]) & free[:-1, :] & free[1:, :]
    comp = _components(free, same_r, same_d)
    nc = int(comp.max()) + 1
    flat = comp.ravel(); ok = flat >= 0
    csize = np.bincount(flat[ok], minlength=nc)
    cprov = np.full(nc, -1, np.int64); cprov[flat[ok]] = prov.ravel()[ok]
    c_own = np.full(nc, -1, np.int64); c_own[flat[ok]] = owner.ravel()[ok]
    main = np.full(n, -1, np.int64)
    for c in np.argsort(-csize).tolist():
        if main[cprov[c]] < 0:
            main[cprov[c]] = c
    new_of = cprov.copy()
    extra = [c for c in range(nc) if main[cprov[c]] != c]
    # соседи куска по прямому касанию (без разреза между ними) — свой берег;
    # куски присоединяем цепочкой: сосед мог сам быть куском за рекой
    u, v, ln, _ = _edge_table(comp, nc)
    nb = {}
    for a, b, l in zip(u.tolist(), v.tolist(), ln.tolist()):
        nb.setdefault(a, []).append((b, l))
        nb.setdefault(b, []).append((a, l))
    moved = 0
    pending = set(extra)
    for _ in range(50):
        if not pending:
            break
        done = []
        for c in sorted(pending, key=lambda q: csize[q]):
            best = None
            for t, l in nb.get(c, []):
                if t in pending:
                    continue
                if new_of[t] == cprov[c]:
                    continue   # сосед — та же провинция за рекой (тело) — не она
                key = (1 if c_own[c] == c_own[t] else 0, l)
                if best is None or key > best[0]:
                    best = (key, t)
            if best is not None:
                new_of[c] = new_of[best[1]]
                done.append(c)
        if not done:
            break
        pending -= set(done)
        moved += len(done)
    nxt = n
    lab = np.where(comp >= 0, new_of[np.maximum(comp, 0)], -1)
    # пиксели разреза — ближайшему куску
    if (land & (lab < 0)).any():
        idx = ndimage.distance_transform_edt(lab < 0, return_distances=False, return_indices=True)
        lab = np.where(land & (lab < 0), lab[idx[0], idx[1]], lab)
    lab = np.where(land, lab, -1)
    # страна пикселя — страна провинции (крошка могла уйти соседу-чужаку)
    pf = lab.ravel(); okp = pf >= 0
    p_own = np.full(nxt, -1, np.int64)
    big_own = np.zeros(nxt, np.int64)
    oc = np.bincount(pf[okp] * 4096 + owner.ravel()[okp].astype(np.int64), minlength=0)
    for key in np.nonzero(oc)[0].tolist():
        q, o = divmod(key, 4096)
        if oc[key] > big_own[q]:
            big_own[q] = oc[key]
            p_own[q] = o
    fix = okp.copy(); fix[okp] = p_own[pf[okp]] != owner.ravel()[okp]
    if fix.any():
        ow = owner.ravel()
        ow[fix] = p_own[pf[fix]]
    used = np.unique(lab[lab >= 0])
    m = np.full(nxt, -1, np.int64); m[used] = np.arange(used.size)
    lab = np.where(lab >= 0, m[np.maximum(lab, 0)], -1).astype(np.int32)
    print(f"  кусков провинций за рекой отдано провинциям своего берега: {moved} (без соседа: {len(pending)})", flush=True)
    return lab, np.asarray(prov_state)[used]


MIN_FRAC = 0.4     # провинция меньше этой доли целевой площади — склеить с соседом
MIN_PX = 30        # и в любом случае не меньше стольких пикселей карты
ELONG_PROV = 3.2   # провинция вытянутее — пополам поперёк
THIN_PROV = 0.7    # провинция-полоска (почти вся у края) — тоже склеить


def _merge_small(prov, prov_state, owner, area_px, river=None):
    """Обрезки (провинции в несколько пикселей) — к соседу той же области (иначе
    той же страны) с самой длинной общей границей; мельчайшие первыми."""
    for _ in range(6):
        n = int(prov.max()) + 1
        flat = prov.ravel()
        ok = flat >= 0
        cnt = np.bincount(flat[ok], minlength=n).astype(np.float64)
        tgt = np.bincount(flat[ok], weights=area_px.ravel()[ok], minlength=n) / np.maximum(cnt, 1)
        own = np.full(n, -1, np.int64)
        own[flat[ok]] = owner.ravel()[ok]
        small = (cnt < MIN_FRAC * tgt) | (cnt < MIN_PX) | (_edge_count(prov, n) > THIN_PROV * cnt)
        if not small.any():
            break
        u, v, ln, rl = _edge_table(prov, n, river)
        best = {}
        for a, b, l, r in zip(u.tolist(), v.tolist(), ln.tolist(), rl.tolist()):
            for s, t in ((a, b), (b, a)):
                if not small[s] or own[s] != own[t]:
                    continue
                same = prov_state[s] == prov_state[t]
                # через реку — только если на своём берегу соседа нет
                key = (0 if r > RIVER_EDGE * l else 1, 1 if same else 0, l)
                if key > best.get(s, ((-1, -1, 0), -1))[0]:
                    best[s] = (key, t)
        if not best:
            break
        remap = np.arange(n)
        done = set()
        for s in sorted(best, key=lambda s: cnt[s]):
            t = best[s][1]
            if s in done or t in done:
                continue   # за проход — одна склейка на провинцию (цепочки — в следующем)
            remap[s] = t
            done.add(s)
            done.add(t)
        prov = np.where(prov >= 0, remap[np.maximum(prov, 0)], -1).astype(np.int32)
        used = np.unique(prov[prov >= 0])
        m = np.full(n, -1, np.int64)
        m[used] = np.arange(used.size)
        prov = np.where(prov >= 0, m[np.maximum(prov, 0)], -1).astype(np.int32)
        prov_state = prov_state[used]
    # обрезки страны внутри материка (без своих соседей и без моря рядом, меньше
    # MIN_PX/3) — ошибки стыка контуров: отдать соседу с самой длинной границей
    # (и пиксели — его стране). Анклавы у моря (Макао, Гуантанамо) остаются
    n = int(prov.max()) + 1
    flat = prov.ravel()
    ok = flat >= 0
    cnt = np.bincount(flat[ok], minlength=n)
    own = np.full(n, -1, np.int64)
    own[flat[ok]] = owner.ravel()[ok]
    wet = np.zeros(n, bool)
    sea = prov < 0
    for sh in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        nb = np.roll(sea, sh, (0, 1))
        wet[np.unique(prov[nb & (prov >= 0)])] = True
    u, v, ln, rl = _edge_table(prov, n, river)
    same_nb = np.zeros(n, bool)
    river_only = np.zeros(n, bool)   # своя страна — только за рекой
    best = {}
    for a, b, l, r in zip(u.tolist(), v.tolist(), ln.tolist(), rl.tolist()):
        across = r > RIVER_EDGE * l
        for s, t in ((a, b), (b, a)):
            if own[s] == own[t]:
                if across:
                    river_only[s] = True
                else:
                    same_nb[s] = True
            elif not across and l > best.get(s, (0, -1))[0]:
                best[s] = (l, t)
    for s, (l, t) in best.items():
        # обрезок страны на чужом берегу (граница страны из одних данных
        # пересекает реку не там, где линия реки из других) — тоже соседу
        lim = MIN_PX if river_only[s] else MIN_PX / 3
        if cnt[s] < lim and not same_nb[s] and not wet[s]:
            m = prov == s
            owner[m] = own[t]
            prov[m] = t
    used = np.unique(prov[prov >= 0])
    m = np.full(n, -1, np.int64)
    m[used] = np.arange(used.size)
    prov = np.where(prov >= 0, m[np.maximum(prov, 0)], -1).astype(np.int32)
    return prov, prov_state[used]
