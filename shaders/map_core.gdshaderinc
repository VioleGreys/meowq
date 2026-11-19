// Ядро шейдера карты: map.gdshader (живой кадр), map_bake.gdshader (BAKE_OUT —
// заготовка неподвижной части: V, S), map_baked.gdshader (BAKED — неподвижная часть
// из заготовок, MapBake). До каймы цвет суши линеен по цвету страны base:
// col = S·base + V (S — скаляр, V — rgb; море: S = 0) — заготовка хранит (V/BK_V,
// 1 − S/BK_S: у моря альфа 1 — сжатие WebP не трогает цвет под прозрачным),
// политика (штриховка, кайма, границы, фронты, выбор), реки и зернистость — вживую.
#ifdef BAKE_OUT
#define LC highp vec4
#define K(x) vec4((x), 0.0)
#else
#define LC mediump vec3
#define K(x) (x)
#endif
const float BK_V = 1.5;
const float BK_S = 2.0;
// Карта провинций: id провинции закодирован в RG текстуры id_tex, цвет
// берётся из палитры (64 x N) — смена владельца = обновление одного пикселя
// палитры, без перерисовки всей карты.

// ТЕКСТУР В ШЕЙДЕРЕ — НЕ БОЛЬШЕ 8 (ноябрь 2026): на Adreno 619 (Realme) с 19
// шейдер не собирался («Sampler location … exceeds max allowed»), карта не
// рисовалась; часть блоков занимает сам Godot. Половины запад/восток и
// однотипные карты — массивами текстур (один блок), палитры — одной текстурой.
// палитры провинций (64 в строке) одной текстурой, по pal_rows строк на раздел:
// 0 — контролёр/режим (rgb цвет, a — (нация+1)/255, 0 = море), 1 — владелец,
// 2 — область (r + g·256 = номер + 1), 3 — фронт (rgb цвет армии, a — роль)
uniform sampler2D pal_tex : filter_nearest;
uniform int pal_rows = 1;
uniform bool has_states = false;
// слой 0 — рельеф (r — высота, 0.5 = уровень моря; g — сила реки; b — доля суши;
// a — 1 − сухость), слой 1 — поле рек (tools/build_rivers.py). Рельеф — без
// mipmap (textureLod 0, как было): с ними берег издали шёл ступеньками
uniform sampler2DArray base_tex : filter_linear_mipmap;
uniform vec2 map_size = vec2(800.0, 500.0);   // сетка карты провинций (с ids2 — вдвое подробнее)
// карта провинций для отрисовки вдвое подробнее (tools/build_ids2x.py), половинами
// запад/восток: восточная — со сдвигом ids_off; id_k — во сколько раз сетка
// подробнее пикселя карты (узоры и толщины линий — в пикселях карты)
uniform sampler2DArray ids_tex : filter_nearest;   // слои 0/1 — запад/восток (без 2× — оба слоя 1×)
uniform bool has_ids2 = false;
uniform int ids_half = 5632;
uniform int ids_off = 5600;
uniform float id_k = 1.0;
// поле расстояний до границ провинций (tools/build_sdf.py): L8, сетка 2×,
// половинами как ids2; 0…1 → 0…2 текселя сетки. Линии стран и провинций —
// по нему (билинейно — гладкие на любом приближении)
uniform sampler2DArray sdf_tex : filter_linear_mipmap;   // слои 0/1 — запад/восток
uniform bool has_sdf = false;
// кайма границ стран (MapView._update_band): 1 у границы, 0 — внутри (L8, четверть карты)
uniform sampler2D band_tex : filter_linear;
uniform bool has_band = false;
// нормали волн (tools/build_water.py, свои): бесшовный тайл, блики и рябь вблизи
// плитки: слой 0 — нормали волн (rg), слой 1 — фактура местности (трава, скалы, песок, снег)
uniform sampler2DArray tile_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_water = false;
// поле рек (tools/build_rivers.py): rg — приведённый вектор до ближайшей реки
// (±RIVER_MAX), b — расстояние со слиянием соседних русел (крупный план), a — до
// ближайшей; сила реки — в канале g рельефа. Билинейный вектор → точное
// расстояние и между текселями: река гладкая на любом приближении
uniform bool has_rivers = false;
const float RIVER_MAX = 4.0;
const float WATER_TILE = 90.0;   // пикселей карты на тайл
uniform float sdf_wd = 5664.0;   // ширина половины
uniform int selected_id = -1;
uniform int highlight_nation = -1;
uniform bool show_occupation = true;
uniform float cam_zoom = 1.0;   // масштаб в центре экрана (пикселей экрана на единицу мира)
// Камера (MapView.screen_to_world — та же формула): плоскость карты под
// перспективной камерой с наклоном cam_tilt (рад, 0 — сверху); центр экрана
// смотрит на cam_pos (единицы мира: пиксель карты × 2); cam_f — фокус, пикс.
// экрана; scr_size — логический размер экрана. Каждый пиксель — луч до плоскости.
uniform vec2 cam_pos = vec2(0.0);
uniform float cam_tilt = 0.0;
uniform float cam_f = 1000.0;
uniform vec2 scr_size = vec2(1280.0, 720.0);
uniform vec2 buf_size = vec2(1.0);   // размер буфера в пикселях
// закольцованный буфер (плоский кэш для движения, MapView._cache_*): окно буфера
// начинается с пикселя torus_n кадра камеры cam_pos; пиксель буфера b хранит пиксель
// кадра torus_n + mod(b − torus_n, buf_size). Для экранного буфера torus_n = 0.
uniform vec2 torus_n = vec2(0.0);
varying vec2 v_bp;   // пиксель буфера (прямоугольники рисуются на своих местах буфера)

void vertex() {
	v_bp = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}
uniform vec2 world_size = vec2(11264.0, 5250.0);
const float RELIEF_H = 6.0;   // высота самых высоких гор при наклоне, единиц мира
uniform float res_k = 1.0;   // пикселей буфера карты на логический пиксель экрана
// спутниковая подложка (NASA Blue Marble) убрана из шейдера (ноябрь 2026): на телефоне
// не хватало текстурных блоков (21 > лимита — карта не рисовалась), её заменила has_art
uniform bool terrain_mode = false;              // режим «Местность»: подложка без цветов стран
// графика карты в полном разрешении (tools/build_map_art.py): цвет природных
// зон (Natural Earth NE1_HR_LC) и нормали рельефа суши и дна (ETOPO1)
// вдвое подробнее карты, половинами запад/восток с перекрытием (шире 8192
// текстуры есть не на всех телефонах); art_geom — ширина подложки, сдвиг
// восточной половины, ширина половины, высота
// графика карты, слои 0/1 — запад/восток: цвет природных зон (a — высота суши
// √(h/6000 м), tools/etopo.py) и нормали рельефа (rg)
#ifndef BAKED
uniform sampler2DArray color_tex : filter_linear_mipmap;
uniform sampler2DArray normal_tex : filter_linear_mipmap;
#else
// заготовки (MapBake): атлас тайлов 256² (248 + поля по 4) и таблица страниц —
// на уровень k (масштаб 2^(k/2 − 3) · bk_r пикселей на единицу мира) строки с
// pg_row[k]; тексель — номер слоя + 1 (r + g·256), 0 — тайла нет
uniform sampler2D page_tex : filter_nearest;
uniform sampler2DArray atlas_tex : filter_linear;
uniform int pg_row[13];
uniform float bk_r = 1.0;
const float BK_T = 248.0;

// выборка тайла: вдали от берега — Catmull-Rom (5 билинейных выборок: резче
// билинейной при сдвиге на долю пикселя), у берега — только тексели своей
// стихии (суша — S > 0, море — S = 0, альфа 1), иначе по берегу смешивались цвета
vec4 bake_lv(int k, vec2 wp, bool land, bool coast, out bool ok) {
	float z = exp2(float(k) * 0.5 - 3.0) * bk_r;
	vec2 p = wp * z;
	ivec2 t = max(ivec2(floor(p / BK_T)), ivec2(0));
	vec4 e = texelFetch(page_tex, ivec2(t.x, pg_row[k] + t.y), 0);
	int layer = int(e.r * 255.0 + 0.5) + int(e.g * 255.0 + 0.5) * 256 - 1;
	ok = layer >= 0;
	float lf = float(max(layer, 0));
	vec2 q = p - vec2(t) * BK_T + 4.0;   // пиксели тайла (центры — +0.5)
	vec2 c = q - 0.5;
	vec2 tc = floor(c);
	vec2 f = c - tc;
	if (coast) {
		ivec2 i0 = ivec2(tc);
		vec4 acc = vec4(0.0);
		float ws = 0.0;
		for (int j = 0; j < 4; j++) {
			ivec2 o = ivec2(j & 1, j >> 1);
			vec4 v = texelFetch(atlas_tex, ivec3(i0 + o, max(layer, 0)), 0);
			float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
			if ((v.a < 0.996) == land) {
				acc += v * w;
				ws += w;
			}
		}
		if (ws > 1e-4) {
			return acc / ws;
		}
		return textureLod(atlas_tex, vec3(q / 256.0, lf), 0.0);
	}
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	vec2 w12 = w1 + w2;
	vec2 c0 = (tc - 0.5) / 256.0;
	vec2 c3 = (tc + 2.5) / 256.0;
	vec2 c12 = (tc + 0.5 + w2 / w12) / 256.0;
	vec4 r = textureLod(atlas_tex, vec3(c12.x, c0.y, lf), 0.0) * (w12.x * w0.y)
		+ textureLod(atlas_tex, vec3(c0.x, c12.y, lf), 0.0) * (w0.x * w12.y)
		+ textureLod(atlas_tex, vec3(c12, lf), 0.0) * (w12.x * w12.y)
		+ textureLod(atlas_tex, vec3(c3.x, c12.y, lf), 0.0) * (w3.x * w12.y)
		+ textureLod(atlas_tex, vec3(c12.x, c3.y, lf), 0.0) * (w12.x * w3.y);
	float ws = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
	return clamp(r / ws, 0.0, 1.0);
}

// два ближайших уровня по масштабу точки, смешение по log2; нет тайла — самый
// дальний уровень (всегда в атласе). Берег — по доле суши, огрублённой до
// размера окна выборки (mipmap)
vec4 bake_at(vec2 wp, float zoom, bool land) {
	float lf = clamp(2.0 * log2(max(zoom, 1e-4)) + 6.0, 0.0, 12.0);
	int k0 = min(int(floor(lf)), 11);
	float w = lf - float(k0);
	// окно ±2.5 пикселя уровня k0 в текселях доли суши (2 единицы мира)
	float lod = max(0.0, log2(2.5 / (exp2(float(k0) * 0.5 - 3.0) * bk_r * 2.0))) + 1.0;
	float cv = textureLod(base_tex, vec3(wp / world_size, 0.0), lod).b;
	bool coast = cv > 0.002 && cv < 0.998;
	bool ok0;
	bool ok1 = false;
	vec4 a = w < 0.999 ? bake_lv(k0, wp, land, coast, ok0) : vec4(0.0);
	if (w >= 0.999) {
		ok0 = false;
	}
	vec4 b = w > 0.001 ? bake_lv(k0 + 1, wp, land, coast, ok1) : vec4(0.0);
	if (ok0 && ok1) {
		return mix(a, b, w);
	}
	if (ok0) {
		return a;
	}
	if (ok1) {
		return b;
	}
	bool okf;
	return bake_lv(0, wp, land, coast, okf);
}
#endif
uniform vec4 art_geom = vec4(11264.0, 5600.0, 5664.0, 5250.0);
uniform bool has_art = false;
// детальные текстуры местности вблизи (ambientCG, tools/build_detail.py):
// r — трава, g — скалы, b — песок, a — снег; среднее 0.5
uniform bool has_detail = false;
// высоты суши вдвое подробнее карты (вид вблизи, только высокое качество): √(h / 6000 м)
uniform bool has_elev = false;
// покров суши (data/world1936/cover.png.bin, tools/build_cover.py) — слой 2 base_tex:
// r — лес (доля крон), g — болото, b — застройка 1936 г., a — рисовые поля
uniform bool has_cover = false;
// постройки и деревья (data/world1936/sprites.png.bin, tools/render_sprites.gd) — слои
// 2–7 tile_tex: в слое 4×4 ячейки по 128 пикс., модели CC0 сверху с юга, тень на юго-восток
uniform bool has_sprites = false;
// покрытия (data/world1936/road_tex.png.bin, ambientCG CC0): слои tile_tex 8 — брусчатка,
// 9 — грунт, 10 — камень мостов
uniform bool has_road_tex = false;
// дороги и железные дороги вблизи (data/world1936/roads.json, tools/build_roads.py) —
// разделы палитры 4…21 (MapView._roads_pal): от провинции к провинции, центр → K → W
uniform bool has_roads = false;
const int RD_SEC = 4;
const float RD_OFF = 0.42;     // дорога рядом с жд — сбоку, пикс. карты
const float TIE_P = 0.30;      // шаг шпал, пикс. карты
uniform float winter = 1.0;   // зима в северном полушарии 0…1 (MapView.set_day)
const float DETAIL_TILE = 48.0;   // пикселей карты на тайл
// проекция Миллера для сетки широт и долгот (как tools/build_map.py)
uniform float lon_min = -169.0;
uniform float lat_top = 80.0;
// качество карты: 2 — высокое (окно 4×4, B-сплайн), 1 — среднее (2×2 билинейно),
// 0 — низкое (один тексель, границы по соседям — дёшево для слабых телефонов);
// берег по векторной доле суши — на среднем и высоком
uniform int quality = 2;
// фронты армий игрока (MapView.set_front): rgb — цвет армии, a — роль/255:
// 1 — наш участок фронта, 2 — чужая сторона линии, 4 — выделено кистью (правка
// участка), 8 — цель атаки (штриховка)
uniform bool front_on = false;

const int NS = 8;

// минимальная полуширина линии в пикселях буфера: в пониженном разрешении
// тоньше пикселя линия рвётся пунктиром
float lw_min(float w) {
	return res_k < 0.99 ? max(w, 1.15) : w;
}   // сколько разных провинций учитываем в окне сглаживания

int pid(ivec2 p) {
	p = clamp(p, ivec2(0), ivec2(map_size) - 1);
	vec4 c;
	{
		c = p.x < ids_half ? texelFetch(ids_tex, ivec3(p, 0), 0) : texelFetch(ids_tex, ivec3(p - ivec2(ids_off, 0), 1), 0);
	}
	return int(c.r * 255.0 + 0.5) + int(c.g * 255.0 + 0.5) * 256;
}

// плавный шум (значения в узлах решётки, квинтическая интерполяция) — для
// изгиба гряд дюн: фактура местности на грубом mipmap давала лесенку и «водовороты»
float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), u.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), u.x), u.y);
}

// широта точки карты (проекция Миллера, как tools/build_map.py), градусы
float lat_at(vec2 px) {
	float s_px = map_size.x / 6.2831853;
	float y_top = 1.25 * log(tan(0.78539816 + 0.4 * radians(lat_top)));
	float yy = y_top - px.y / s_px;
	return degrees(2.5 * atan(exp(0.8 * yy)) - 1.9634954);
}

vec4 pal(int sec, int id) {
	return texelFetch(pal_tex, ivec2(id % 64, id / 64 + sec * pal_rows), 0);
}

// Расстояние до границы (тексели сетки провинций) по «запасу» весов окна
// d = (свои − чужие) / (свои + чужие): для прямой границы это известная функция
// расстояния (кубический B-сплайн + перевес ближних 0,35, как в окне 4×4) —
// обратная подобрана численно (ошибка ≤ 0,05 текселя). Меряет расстояние ровно
// до своей границы (страны, провинции): внутренние границы рядом не мешают
// (поле расстояний меряет до любой — линия страны «затекала» вдоль них).
float border_tx(float d, bool bilinear) {
	if (bilinear) {
		return d >= 0.999 ? 1.4 : 0.5 * d;   // окно 2×2: доля линейна до полутекселя
	}
	if (d >= 0.995) {
		return 1.4;                // дальше окна — линии тут нет
	}
	float d2 = d * d;
	return d * (0.6714 + d2 * (-0.82813 + d2 * (3.77264 + d2 * (-6.06485 + d2 * 3.66793))));
}

// свет по соседним высотам растра (берега рек, карта без графики)
float light_at(vec2 muv) {
	vec2 t = 1.0 / map_size;
	float h_r = textureLod(base_tex, vec3(muv + vec2(t.x, 0.0), 0.0), 0.0).r;
	float h_l = textureLod(base_tex, vec3(muv - vec2(t.x, 0.0), 0.0), 0.0).r;
	float h_d = textureLod(base_tex, vec3(muv + vec2(0.0, t.y), 0.0), 0.0).r;
	float h_u = textureLod(base_tex, vec3(muv - vec2(0.0, t.y), 0.0), 0.0).r;
	if (quality > 0) {
		// у берега растровая высота резко падает к морю — светотень рисовала бы
		// ступенчатый силуэт пикселей; берег уже дан векторным контуром
		h_r = max(h_r, 0.5); h_l = max(h_l, 0.5); h_d = max(h_d, 0.5); h_u = max(h_u, 0.5);
	}
	float hx = h_r - h_l;
	float hy = h_d - h_u;
	mediump vec3 n = normalize(vec3(-hx * 7.0, -hy * 7.0, 1.0));
	return clamp(dot(n, normalize(vec3(-0.55, -0.65, 0.75))), 0.0, 1.0);
}

int nation(vec4 c) {
	return int(c.a * 255.0 + 0.5) - 1;
}

// бикубическая (B-сплайн) выборка 4 билинейными: вблизи — без ромбиков сетки
// (с явными производными: выборка — в ветвлении по половине подложки)
vec4 tex_bicubic(sampler2DArray t, vec2 uv, float layer, vec2 ts, vec2 gx, vec2 gy) {
	vec2 st = uv * ts - 0.5;
	vec2 i = floor(st);
	vec2 f = st - i;
	vec2 f2 = f * f;
	vec2 f3 = f2 * f;
	vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
	vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
	vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
	vec2 w3 = f3 / 6.0;
	vec2 g0 = w0 + w1;
	vec2 g1 = w2 + w3;
	vec2 p0 = (i - 0.5 + w1 / g0) / ts;
	vec2 p1 = (i + 1.5 + w3 / g1) / ts;
	return g0.y * (g0.x * textureGrad(t, vec3(vec2(p0.x, p0.y), layer), gx, gy) + g1.x * textureGrad(t, vec3(vec2(p1.x, p0.y), layer), gx, gy))
		+ g1.y * (g0.x * textureGrad(t, vec3(vec2(p0.x, p1.y), layer), gx, gy) + g1.x * textureGrad(t, vec3(vec2(p1.x, p1.y), layer), gx, gy));
}

vec2 qc0(vec2 px) {
	return px / id_k;
}

// Ячейка атласа построек: idx — номер (слой 2 + idx / 16), lu — 0…1 внутри ячейки.
vec3 atl_uv(int idx, vec2 lu) {
	int w = idx % 16;
	return vec3((vec2(float(w % 4), float(w / 4)) + lu) / 4.0, 2.0 + float(idx / 16));
}

// Спрайт атласа в ячейке сетки q / cell (q — пиксели карты 1×): есть с вероятностью
// prob, сдвинут внутри ячейки, занимает долю fill; вариант — base + [0, nvar).
// Спрайт не выходит за свою ячейку — одна выборка на пиксель. gx, gy — изменение q на
// пиксель экрана (до ветвлений): mipmap без швов на краях ячеек.
vec4 spr_cell(vec2 q, vec2 cell, float seed, float prob, int base, int nvar, float fill, vec2 gx, vec2 gy) {
	vec2 g = q / cell;
	g.x += h21(vec2(floor(g.y), seed)) * 0.5;   // ряды со сдвигом
	vec2 c = floor(g);
	if (h21(c + vec2(seed, 1.7)) >= prob) {
		return vec4(0.0);
	}
	vec2 off = (vec2(h21(c + vec2(seed, 3.1)), h21(c + vec2(seed, 5.9))) - 0.5) * (1.0 - fill);
	vec2 lu = (fract(g) - 0.5 - off) / fill + 0.5;
	if (lu.x < 0.0 || lu.y < 0.0 || lu.x > 1.0 || lu.y > 1.0) {
		return vec4(0.0);
	}
	int idx = base + min(int(h21(c + vec2(seed, 8.3)) * float(nvar)), nvar - 1);
	vec3 auv = atl_uv(idx, lu);
	vec2 k = 1.0 / (cell * fill * 4.0);
	return textureGrad(tile_tex, auv, gx * k, gy * k);
}

// Сплошной полог леса (как в жанре): кроны крупнее ячейки и перекрывают соседей —
// на пиксель четыре ближайшие ячейки, с севера на юг (южные кроны поверх северных:
// камера с юга). Пород — пятнами ~9 пикс.: хвойные доля conif, иначе лиственные и
// берёзы. Пропуски в пологе — по плотности prob.
vec4 canopy(vec2 q, float cell, float prob, float conif, vec2 gx, vec2 gy) {
	vec2 g = q / cell - 0.5;
	vec2 b = floor(g);
	vec4 acc = vec4(0.0);
	const float SZ = 1.75;   // поперечник кроны в ячейках
	float k = 1.0 / (cell * SZ * 4.0);
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			vec2 c = b + vec2(float(i), float(j));
			if (h21(c + vec2(61.0, 1.7)) >= prob) {
				continue;
			}
			vec2 jit = (vec2(h21(c + vec2(61.0, 3.1)), h21(c + vec2(61.0, 5.9))) - 0.5) * 0.55;
			vec2 lu = (g - c - jit) / SZ + 0.5;
			if (lu.x < 0.0 || lu.y < 0.0 || lu.x > 1.0 || lu.y > 1.0) {
				continue;
			}
			bool pine = h21(floor(c * cell / 9.0) + vec2(3.0, 3.0)) < conif;
			float hv = h21(c + vec2(61.0, 8.3));
			int idx = pine ? 56 + min(int(hv * 5.0), 4) : 40 + min(int(hv * 8.0), 7);
			vec3 auv = atl_uv(idx, lu);
			vec4 t = textureGrad(tile_tex, auv, gx * k, gy * k);
			acc = vec4(mix(acc.rgb, t.rgb, t.a), acc.a + t.a * (1.0 - acc.a));
		}
	}
	return acc;
}

// Постройка города в ячейке: класс и вероятность — по застройке (cover.b) в центре
// ячейки (по пикселю — спрайты резались бы на краю пятна): центр крупного города —
// доходные дома (0–7), соборы (24, 25) и заводы на окраинах (28–31); городок — дома
// (8–15); деревня и окраина — дома и хозяйства (16–19, 32–39).
// Город как в жанре, но без «квадратной» сетки: кварталы — ячейки Вороного по
// случайным точкам (треугольники, четырёх-, пятиугольники разной величины), улицы —
// по их границам под любыми углами; дома — внутри квартала с отступом от улицы
// (место дома целиком в своём квартале), в изогнутом ряду от точки квартала. Класс
// квартала — по застройке у его точки: центр — доходные дома, дальше — дома, на
// окраине изредка заводской квартал целиком; одна церковь у середины квартала.
// Деревня — редкие дома своей сеткой, без мостовой. На воде и у реки — пусто.
const int TOWN_C = 0;
const int TOWN_H = 12;
const int VIL = 24;
const int IZBA = 30;
const int FACT = 34;
const int CHURCH = 38;
const vec2 SLOT = vec2(1.5, 1.3);     // место дома, пикселей карты 1× (условно крупно)
const float BLK_CS = 5.5;             // шаг точек кварталов
const float STREET = 0.4;             // ширина улицы

vec2 h22(vec2 p) {
	return vec2(h21(p), h21(p + vec2(17.3, 41.9)));
}

// расстояние до ближайшей границы ячейки (x, пикс.) и номер ячейки (yz) —
// границы Вороного (два прохода: ближайшая точка, затем расстояние до биссектрис)
vec3 town_vor_n(vec2 p, out vec2 nrm) {
	nrm = vec2(1.0, 0.0);
	vec2 g = p / BLK_CS;
	vec2 n = floor(g);
	vec2 f = g - n;
	vec2 mg = vec2(0.0);
	vec2 mr = vec2(0.0);
	float md = 8.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 r = o + 0.1 + 0.8 * h22(n + o) - f;
			float d = dot(r, r);
			if (d < md) { md = d; mr = r; mg = o; }
		}
	}
	md = 8.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 o = mg + vec2(float(i), float(j));
			vec2 r = o + 0.1 + 0.8 * h22(n + o) - f;
			if (dot(mr - r, mr - r) > 1e-5) {
				float e = dot(0.5 * (mr + r), normalize(r - mr));
				if (e < md) { md = e; nrm = normalize(r - mr); }
			}
		}
	}
	return vec3(md * BLK_CS, n + mg);
}

// поля: ячейки Вороного в своей сетке (шаг 1) — x: до края ячейки (доли шага),
// yz → (номер ячейки); проще town_vor_n: второй проход 3×3
vec3 field_vor3(vec2 g) {
	vec2 n = floor(g);
	vec2 f = g - n;
	vec2 mg = vec2(0.0);
	vec2 mr = vec2(0.0);
	float md = 8.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 r = o + 0.15 + 0.7 * h22(n + o + vec2(91.0, 37.0)) - f;
			float d = dot(r, r);
			if (d < md) { md = d; mr = r; mg = o; }
		}
	}
	md = 8.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = mg + vec2(float(i), float(j));
			vec2 r = o + 0.15 + 0.7 * h22(n + o + vec2(91.0, 37.0)) - f;
			if (dot(mr - r, mr - r) > 1e-5) {
				md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
			}
		}
	}
	return vec3(md, n + mg);
}

vec3 town_vor(vec2 p) {
	vec2 nn;
	return town_vor_n(p, nn);
}

vec2 town_seed(vec2 c) {
	return (c + 0.1 + 0.8 * h22(c)) * BLK_CS;
}

// застройка города — по провинциям (решение пользователя): город заполняет свою
// провинцию (класс из палитры, раздел 2, b: 3 — столица и от 1 млн, 2 — от 400 тыс.,
// 1 — от 150 тыс.), пригород — полоса ~1,6 пикс. в соседних провинциях, не дальше
int town_cls(vec2 p) {
	int id = pid(ivec2(floor(p * id_k)));
	return int(pal(2, id).b * 255.0 + 0.5);
}

float town_scale(vec2 p) {
	int id = pid(ivec2(floor(p * id_k)));
	return max(pal(2, id).a, 0.5);
}

float town_d(vec2 p, vec2 msz) {
	int c = town_cls(p);
	if (c > 0) {
		return c == 3 ? 0.6 : (c == 2 ? 0.4 : 0.22);
	}
	return 0.0;   // за провинцией города — ни домов, ни улиц (решение пользователя)
}

// мягкая доля города около точки (5 выборок в радиусе r со сдвигом по шуму) — край
// без ступенек сетки провинций
// id0, c0 — любая провинция и её класс (town_cls): выборка в ней палитру не читает
float town_soft_k(vec2 p, vec2 msz, float r, int id0, int c0) {
	// 8 выборок по кругу, угол и радиус плавно меняются по месту — край округлый,
	// без ступенек сетки провинций
	float a0 = vnoise(p * 0.7) * 6.283;
	float sum = 0.0;
	for (int k = 0; k < 8; k++) {
		float a = a0 + float(k) * 0.785398;
		float rr = r * (0.5 + 0.5 * float(k & 1));
		int id = pid(ivec2(floor((p + vec2(cos(a), sin(a)) * rr) * id_k)));
		int c = id == id0 ? c0 : int(pal(2, id).b * 255.0 + 0.5);
		sum += step(0.1, c > 0 ? (c == 3 ? 0.6 : (c == 2 ? 0.4 : 0.22)) : 0.0);   // как town_d
	}
	return sum / 8.0;
}

float town_soft(vec2 p, vec2 msz, float r) {
	return town_soft_k(p, msz, r, -1, 0);
}

bool town_wet(vec2 p, vec2 msz) {
	vec2 uv = p / msz;
	float cov_c = textureLod(base_tex, vec3(uv, 0.0), 0.0).b;
	float rv_c = textureLod(base_tex, vec3(uv, 1.0), 0.0).a * RIVER_MAX;
	float rs_c = textureLod(base_tex, vec3(uv, 0.0), 0.0).g;
	return cov_c < 0.9 || (rs_c > 0.01 && rv_c < 2.2);   // от реки — с запасом на ширину ленты вблизи
}

vec4 town_spr(int idx, vec2 lu, vec2 cell, vec2 gx, vec2 gy) {
	if (lu.x < 0.0 || lu.y < 0.0 || lu.x > 1.0 || lu.y > 1.0) {
		return vec4(0.0);
	}
	vec2 k = 1.0 / (cell * 4.0);
	return textureGrad(tile_tex, atl_uv(idx, lu), gx * k, gy * k);
}

// мост: улица города, пересекающая реку, — вдоль улицы в обе стороны недалеко суша
// (граница квартала вдоль реки мостом не становится)
float town_bridge(vec2 q, vec2 msz, out vec3 buv) {
	vec2 nrm;
	vec3 v = town_vor_n(q, nrm);
	buv = vec3(dot(q, vec2(-nrm.y, nrm.x)), v.x, STREET * 0.45);
	float d = town_d(q, msz);
	if (d < 0.2) {
		return 0.0;
	}
	vec2 e = vec2(-nrm.y, nrm.x);   // направление улицы
	// суша по обе стороны недалеко, а поперёк улицы — вода с обеих сторон (не вдоль
	// берега) и рядом нет третьей улицы (развилки над водой)
	bool ok = false;
	for (int i = 1; i <= 2; i++) {
		float L = 0.9 * float(i);
		if (!town_wet(q + e * L, msz) && !town_wet(q - e * L, msz)) {
			ok = true;
		}
	}
	ok = ok && town_wet(q + nrm * 0.8, msz) && town_wet(q - nrm * 0.8, msz);
	vec2 n2;
	ok = ok && town_vor_n(q + e * 0.7, n2).x < STREET && town_vor_n(q - e * 0.7, n2).x < STREET
		&& abs(dot(n2, nrm)) > 0.95;
	return ok ? (1.0 - smoothstep(STREET * 0.3, STREET * 0.45, v.x)) : 0.0;
}

// Дом по региону (решение пользователя: больше материалов): ll — долгота, широта;
// kind: 0 — центр города, 1 — дома города, 2 — деревня. Ячейки: 0–23 Франция и
// Бельгия, 24–29 деревня Запада, 64–71 дерево (СССР), 72–77 кирпич (Восточная Европа),
// 78–83 штукатурка и черепица (юг), 84, 86, 89 — Германия, 90–91 доходные дома.
int town_pick(vec2 ll, int kind, float hv, float hr) {
	float lon = ll.x + (hr - 0.5) * 4.0;   // размытая граница регионов
	float lat = ll.y;
	bool south = lat < 44.5 && lon < 30.0;
	bool west = !south && lon < 6.5;
	bool central = !south && !west && lon < 15.5;
	bool poland = !south && lon >= 15.5 && lon < 25.0;
	int n;
	if (kind == 0) {
		if (south) { return hv < 0.4 ? 78 + int(hv * 5.0) : TOWN_C + min(int(hv * 12.0), 11); }
		if (west) { return TOWN_C + min(int(hv * 12.0), 11); }
		return hv < 0.35 ? 90 + int(hv * 5.7) : TOWN_C + min(int(hv * 12.0), 11);
	}
	if (kind == 1) {
		if (south) { return 78 + min(int(hv * 6.0), 5); }
		if (west) { return TOWN_H + min(int(hv * 12.0), 11); }
		if (central) { return hv < 0.4 ? (hv < 0.13 ? 84 : hv < 0.26 ? 86 : 89) : TOWN_H + min(int(hv * 12.0), 11); }
		if (poland) { return hv < 0.6 ? 72 + min(int(hv * 10.0), 5) : TOWN_H + min(int(hv * 12.0), 11); }
		return hv < 0.55 ? 72 + min(int(hv * 10.9), 5) : 64 + min(int((hv - 0.55) * 17.8), 7);
	}
	if (south) { return 80 + min(int(hv * 4.0), 3); }
	if (west) { return VIL + min(int(hv * 6.0), 5); }
	if (central) { return hv < 0.5 ? (hv < 0.17 ? 84 : hv < 0.34 ? 86 : 89) : VIL + min(int(hv * 6.0), 5); }
	if (poland) { return hv < 0.5 ? 72 + min(int(hv * 12.0), 5) : 64 + min(int((hv - 0.5) * 16.0), 7); }
	return hv < 0.85 ? 64 + min(int(hv * 9.4), 7) : 72 + min(int((hv - 0.85) * 40.0), 5);
}

vec4 town_cell(vec2 q, vec2 msz, vec2 gx, vec2 gy, vec2 ll, out float dens, out float street, out vec3 suv) {
	street = 0.0;
	suv = vec3(0.0);   // деревне не нужен (улиц нет)
	float d = town_d(q, msz);
	dens = d;
	bool urban = d > 0.12;
	if (!urban) {
		// деревня: редкие дома своей неровной сеткой, без улиц
		const vec2 VS = vec2(3.4, 3.0);
		vec2 g = q / VS;
		g.x += h21(vec2(floor(g.y), 29.0)) * 0.7;
		vec2 vc = floor(g);
		vec2 ctr = (vc + 0.5 - vec2(h21(vec2(vc.y, 29.0)) * 0.7, 0.0)) * VS;
		float dn = textureLod(base_tex, vec3(ctr / msz, 2.0), 1.0).b * 1.6;
		float hp = h21(vc + vec2(29.0, 1.7));
		// отказы от дешёвых к дорогим (итог тот же — любой из них даёт пусто)
		if (dn < 0.05 || hp >= smoothstep(0.05, 0.16, dn) * 0.5 || textureLod(base_tex, vec3(ctr / msz, 2.0), 0.0).r > 0.3
				|| town_wet(ctr, msz) || town_soft(ctr, msz, 4.0) > 0.0 || town_soft(ctr, msz, 9.0) > 0.0) {
			return vec4(0.0);
		}
		float hv = h21(vc + vec2(29.0, 8.3));
		int idx = town_pick(ll, 2, hv, h21(vc + vec2(31.0, 3.0)));
		vec2 jit = (h22(vc + vec2(5.0, 5.0)) - 0.5) * 0.25;
		return town_spr(idx, (fract(g) - 0.5 - jit) * VS / SLOT + 0.5, SLOT, gx, gy);
	}
	vec2 nrm;
	vec3 v = town_vor_n(q, nrm);
	vec2 e_st = vec2(-nrm.y, nrm.x);
	suv = vec3(dot(q, e_st), v.x, 0.0);   // вдоль улицы, от её края до оси
	vec2 c = v.yz;
	vec2 sp = town_seed(c);
	// улица по границе квартала (у границы большого города — мягче)
	float sw = STREET * mix(0.7, 1.4, h21(c + vec2(2.0, 7.0)));
	float st = 1.0 - smoothstep(sw * 0.3, sw * 0.65, v.x);
	street = st * step(0.2, d);
	suv.z = sw * 0.5;   // полуширина
	if (st > 0.6) {
		return vec4(0.0);
	}
	vec2 SL = SLOT * town_scale(q);   // мельче в маленьких провинциях
	// места домов — ряды от точки квартала (свой сдвиг рядов в каждом квартале)
	vec2 rel = (q - sp) / SL + 0.5;
	rel.x += floor(rel.y) * (h21(c + vec2(8.0, 3.0)) - 0.5) * 0.8;
	vec2 sl = floor(rel);
	vec2 ctr = sp + (sl - vec2(floor(rel.y) * (h21(c + vec2(8.0, 3.0)) - 0.5) * 0.8, 0.0)) * SL;
	// место целиком в своём квартале, с отступом от улицы
	vec2 nrm_h;
	vec3 vc = town_vor_n(ctr, nrm_h);
	if (any(notEqual(vc.yz, c)) || vc.x < max(SL.x, SL.y) * 0.15 + sw * 0.5) {
		return vec4(0.0);
	}
	// дом целиком в провинции города (половинки на границе не ставим)
	// (центр в провинции города и до её границы не ближе полудиагонали дома — по полю
	// расстояний до границ провинций)
	vec2 hc = SL * 0.33;
	float ds = town_d(ctr, msz);   // место — в провинции города или в полосе пригорода
	if (urban && (ds < 0.2 || town_d(ctr + hc, msz) < 0.2 || town_d(ctr - hc, msz) < 0.2
			|| town_d(ctr + vec2(hc.x, -hc.y), msz) < 0.2 || town_d(ctr + vec2(-hc.x, hc.y), msz) < 0.2)) {
		return vec4(0.0);
	}
	vec2 hs = SL * 0.3;
	if (town_wet(ctr, msz) || town_wet(ctr + hs, msz) || town_wet(ctr - hs, msz)
			|| town_wet(ctr + vec2(hs.x, -hs.y), msz) || town_wet(ctr + vec2(-hs.x, hs.y), msz)) {
		return vec4(0.0);
	}
	vec2 key = c * 17.0 + sl;
	float hp = h21(key + vec2(11.0, 1.7));
	float hv = h21(key + vec2(11.0, 8.3));
	// занятость мест: центр плотно, город и городок реже, пригород — редкие дома
	float occ = ds > 0.5 ? 0.85 : ds > 0.3 ? 0.72 : ds > 0.2 ? 0.6 : ds > 0.12 ? 0.32 : 0.0;
	if (hp >= occ) {
		return vec4(0.0);
	}
	float hb = h21(c + vec2(11.0, 4.4));
	int idx;
	if (d < 0.5 && hb < 0.12) {
		idx = FACT + min(int(hv * 4.0), 3);            // заводской квартал
	} else if (hb > 0.8 && all(equal(sl, vec2(0.0)))) {
		idx = CHURCH + min(int(hv * 2.0), 1);           // церковь у середины квартала
	} else {
		idx = town_pick(ll, d > 0.45 ? 0 : 1, hv, h21(c + vec2(31.0, 3.0)));
	}
	// дом развёрнут к ближайшей улице (угол её края, сведённый к ±45°) и чуть
	// случайно — не строго по сетке
	float ang = atan(nrm_h.y, nrm_h.x);
	ang = ang - 1.5707963 * floor(ang / 1.5707963 + 0.5) + (hv - 0.5) * 0.12;
	float ca = cos(ang);
	float sa = sin(ang);
	vec2 dq = q - ctr;
	dq = vec2(ca * dq.x + sa * dq.y, -sa * dq.x + ca * dq.y);
	const float fill = 0.92;
	vec2 jit = (h22(key + vec2(5.0, 5.0)) - 0.5) * 0.06;
	vec2 lu = (dq / SL - jit) / fill + 0.5;
	vec2 rgx = vec2(ca * gx.x + sa * gx.y, -sa * gx.x + ca * gx.y);
	vec2 rgy = vec2(ca * gy.x + sa * gy.y, -sa * gy.x + ca * gy.y);
	return town_spr(idx, lu, SL * fill, rgx, rgy);
}

// --- дороги и железные дороги -------------------------------------------------
vec2 rd_pt(vec4 t) {
	t = floor(t * 255.0 + 0.5);
	return vec2(t.r + t.g * 256.0, t.b + t.a * 256.0) * 0.125;
}

float rd_seg(vec2 q, vec2 a, vec2 b, out float h) {
	vec2 ba = b - a;
	h = clamp(dot(q - a, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
	return length(q - a - ba * h);
}

// расстояние до кривой Безье (квадратичной — p1 = p2) ломаной из RD_N частей; дуга от
// p0 (s, растянута до целого числа шагов шпал — у концов фаза шпал 0); сбоку
// на off0 → off1 (дорога рядом с жд; слева по ходу p0 → p3)
const int RD_N = 6;
void rd_bez(vec2 q, vec2 p0, vec2 p1, vec2 p2, vec2 p3, float off0, float off1, inout float dm, inout float sm) {
	vec2 pr = p0;
	float len = 0.0;
	for (int k = 1; k <= RD_N; k++) {
		float t = float(k) / float(RD_N);
		float u = 1.0 - t;
		vec2 pt = u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
		len += length(pt - pr);
		pr = pt;
	}
	float sc = max(1.0, floor(len / TIE_P + 0.5)) * TIE_P / max(len, 1e-4);
	vec2 a = p0;
	vec2 ta = normalize(p1 - p0 + vec2(1e-5, 0.0));
	a += vec2(-ta.y, ta.x) * off0;
	float acc = 0.0;
	for (int k = 1; k <= RD_N; k++) {
		float t = float(k) / float(RD_N);
		float u = 1.0 - t;
		vec2 pt = u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
		vec2 tg = normalize(3.0 * u * u * (p1 - p0) + 6.0 * u * t * (p2 - p1) + 3.0 * t * t * (p3 - p2) + vec2(1e-5, 0.0));
		pt += vec2(-tg.y, tg.x) * mix(off0, off1, smoothstep(0.25, 0.75, t));
		float h;
		float d = rd_seg(q, a, pt, h);
		float sl = length(pt - a);
		if (d < dm) {
			dm = d;
			sm = (acc + h * sl) * sc;
		}
		acc += sl;
		a = pt;
	}
}

// плавное петляние линий (по месту на карте — с обеих сторон границы одно и то же)
vec2 rd_warp(vec2 q, float f) {
	return vec2(vnoise(q * f + vec2(3.1, 9.7)), vnoise(q * f + vec2(17.3, 4.4))) - 0.5;
}

// половины дорог провинции id у точки q (пикс. карты 1×): расстояние до жд (d_rail),
// дуга вдоль жд (s_rail — для шпал: у точки W на границе 0 с обеих сторон),
// расстояние до дороги (d_road). Ровно два выхода вида и бит «насквозь» — кривая
// от границы до границы мимо центра; иначе — дуги центр → K → W (в W касательная
// по прямой центр — центр, как у соседа: линия без излома)
void road_prov(int id, vec2 q, inout float d_rail, inout float s_rail, inout float d_road) {
	vec4 m = floor(pal(RD_SEC + 1, id) * 255.0 + 0.5);
	int n = int(m.r) & 15;
	if (n == 0) {
		return;
	}
	vec2 c = rd_pt(pal(RD_SEC, id));
	if (length(q - c) > 400.0) {
		return;
	}
	int tb = int(m.g) | (int(m.b) << 8);
	int fb = int(m.a);
	bool thr_r = (int(m.r) & 16) != 0;
	bool thr_d = (int(m.r) & 32) != 0;
	vec4 m2 = floor(pal(RD_SEC + 18, id) * 255.0 + 0.5);
	vec2 qr = q + rd_warp(q, 0.12) * 0.30;   // жд — едва петляет
	vec2 qd = q + rd_warp(q, 0.22) * 0.55;   // грунтовка — заметнее
	// сквозная кривая: два самых противоположных выхода; середина — для отворотов
	ivec2 pr = ivec2(int(m2.r) & 7, int(m2.r) >> 3);
	ivec2 pd = ivec2(int(m2.g) & 7, int(m2.g) >> 3);
	vec2 end_r = c;
	vec2 end_d = c;
	for (int j = 0; j < 2; j++) {
		bool on = j == 0 ? thr_r : thr_d;
		if (!on) {
			continue;
		}
		ivec2 pp = j == 0 ? pr : pd;
		vec2 k0 = rd_pt(pal(RD_SEC + 2 + 2 * pp.x, id));
		vec2 w0 = rd_pt(pal(RD_SEC + 3 + 2 * pp.x, id));
		vec2 k1 = rd_pt(pal(RD_SEC + 2 + 2 * pp.y, id));
		vec2 w1 = rd_pt(pal(RD_SEC + 3 + 2 * pp.y, id));
		float L = length(w1 - w0);
		// опоры: 0,25…0,4 расстояния W0–W1, при крутом повороте короче — скруглённый
		// угол (как build_roads.thr_ctrl)
		float dt = dot(normalize(k0 - w0 + vec2(1e-5, 0.0)), normalize(k1 - w1 + vec2(1e-5, 0.0)));
		float f = 0.25 + 0.15 * clamp(-dt, 0.0, 1.0);
		k0 = w0 + (k0 - w0) * min(1.0, f * L / max(length(k0 - w0), 1e-4));
		k1 = w1 + (k1 - w1) * min(1.0, f * L / max(length(k1 - w1), 1e-4));
		vec2 mid = 0.125 * (w0 + w1) + 0.375 * (k0 + k1);
		float s = 0.0;
		float d = 9.0;
		if (j == 0) {
			end_r = mid;
			rd_bez(qr, w0, k0, k1, w1, 0.0, 0.0, d, s);
			if (d < d_rail) {
				d_rail = d;
				s_rail = s;
			}
		} else {
			end_d = mid;
			int t0 = (tb >> (2 * pd.x)) & 3;
			int t1 = (tb >> (2 * pd.y)) & 3;
			float o0 = t0 == 3 ? (((fb >> pd.x) & 1) == 1 ? RD_OFF : -RD_OFF) : 0.0;
			float o1 = t1 == 3 ? (((fb >> pd.y) & 1) == 1 ? RD_OFF : -RD_OFF) : 0.0;
			rd_bez(qd, w0, k0, k1, w1, o0, -o1, d_road, s);
		}
	}
	for (int i = 0; i < 8; i++) {
		if (i >= n) {
			break;
		}
		int tp = (tb >> (2 * i)) & 3;
		bool sk_r = thr_r && (i == pr.x || i == pr.y);
		bool sk_d = thr_d && (i == pd.x || i == pd.y);
		if (((tp & 2) == 0 || sk_r) && ((tp & 1) == 0 || sk_d)) {
			continue;
		}
		vec2 k = rd_pt(pal(RD_SEC + 2 + 2 * i, id));
		vec2 w = rd_pt(pal(RD_SEC + 3 + 2 * i, id));
		// отворот W → K → (середина сквозной или центр); в W касательная — как у соседа
		if ((tp & 2) != 0 && !sk_r) {
			float s = 0.0;
			float d = 9.0;
			rd_bez(qr, w, k, mix(k, end_r, 0.5), end_r, 0.0, 0.0, d, s);
			if (d < d_rail) {
				d_rail = d;
				s_rail = s;
			}
		}
		if ((tp & 1) != 0 && !sk_d) {
			// рядом с жд — сбоку (с обеих провинций по одну сторону; по ходу W → центр)
			float sg = tp == 3 ? (((fb >> i) & 1) == 1 ? RD_OFF : -RD_OFF) : 0.0;
			float s = 0.0;
			rd_bez(qd, w, k, mix(k, end_d, 0.5), end_d, sg, sg * 0.3, d_road, s);
		}
	}
}

// цвет полотна: rgb и доля; mp — пикселей экрана на пиксель карты, ql — для текстуры
vec4 road_paint(vec3 under, float d_rail, float s_rail, float d_road, float mp, vec2 q, float gl, float rk, float ok) {
	float fw = 1.0 / mp;   // пикс. карты на пиксель экрана
	vec3 col = under;
	float a = 0.0;
	// дорога: грунтовка, мягкие края, колеи; вдали — тонкая светлая линия
	if (d_road < 1.0 && ok > 0.0) {
		float hw = max(0.13, 0.55 * fw);
		float m = (1.0 - smoothstep(hw - fw, hw + fw * 1.5, d_road)) * ok;
		vec3 dirt = vec3(0.60, 0.53, 0.41);
		if (has_road_tex) {
			vec3 g = textureGrad(tile_tex, vec3(q / 0.8, 9.0), vec2(gl, 0.0) / 0.8, vec2(0.0, gl) / 0.8).rgb;
			dirt *= 0.8 + 0.4 * dot(g, vec3(0.33));
		}
		float rut = smoothstep(0.035, 0.0, abs(d_road - hw * 0.45)) * smoothstep(8.0, 14.0, mp);
		dirt *= 1.0 - 0.18 * rut;
		dirt = mix(dirt, under, 0.25 * smoothstep(hw * 0.4, hw, d_road));   // края в траву
		col = mix(col, dirt, m * 0.8);
		a = max(a, m * 0.8);
	}
	// жд: вдали — тёмная линия; ближе — насыпь из щебня, шпалы и два рельса
	if (d_rail < 1.0 && rk > 0.0) {
		float near = smoothstep(5.0, 9.0, mp);
		float hw = mix(max(0.09, 0.6 * fw), 0.26, near);
		float m = (1.0 - smoothstep(hw - fw, hw + fw, d_rail)) * rk;
		// вдали — буро-коричневая (не путать с серыми линиями границ), шпалы — штрихом
		vec3 bed = mix(vec3(0.33, 0.22, 0.14), vec3(0.50, 0.47, 0.43), near);
		float tick = (1.0 - smoothstep(0.25, 0.45, abs(fract(s_rail / (TIE_P * 3.0) + 0.5) - 0.5) * 2.0)) * (1.0 - near);
		hw += tick * 0.6 * fw * smoothstep(3.0, 5.0, mp);
		m = (1.0 - smoothstep(hw - fw, hw + fw, d_rail)) * rk;
		bed *= 0.92 + 0.16 * h21(floor(q * 14.0));   // щебень
		bed = mix(bed, under * 0.7, 0.35 * smoothstep(hw * 0.6, hw, d_rail) * near);   // откос
		float tk = smoothstep(3.0, 6.0, TIE_P * mp) * near;
		float tie = (1.0 - smoothstep(0.30, 0.40, abs(fract(s_rail / TIE_P + 0.5) - 0.5) * 2.0))
			* (1.0 - smoothstep(0.17, 0.19, d_rail));
		bed = mix(bed, vec3(0.26, 0.19, 0.13), tie * tk * 0.9);
		float rl = 1.0 - smoothstep(0.022, 0.022 + fw, abs(d_rail - 0.095));
		bed = mix(bed, vec3(0.20, 0.20, 0.22), rl * smoothstep(7.0, 11.0, mp));
		bed = mix(bed, vec3(0.62, 0.62, 0.64), smoothstep(7.0, 11.0, mp) * 0.4 * (1.0 - smoothstep(0.0, 0.01 + fw * 0.5, abs(d_rail - 0.088))));   // блик рельса
		col = mix(col, bed, m);
		a = max(a, m);
	}
	return vec4(col, a);
}

void fragment() {
	// луч из пикселя экрана до плоскости карты (см. cam_*)
	// центр пикселя буфера: прямоугольник (частичная перерисовка, полосы) лежит на
	// своём месте буфера — те же центры, что при полной перерисовке
	vec2 bp = floor(v_bp) + 0.5;
	bp = torus_n + mod(bp - torus_n, buf_size);
	vec2 sc = bp / buf_size * scr_size - scr_size * 0.5;
	float st = sin(cam_tilt);
	float ct = cos(cam_tilt);
	float dist = cam_f / cam_zoom;
	float den = ct + st * sc.y / cam_f;
	float tr = dist * ct / max(den, 1e-4);           // глубина точки (вдоль взгляда)
	vec2 wp = vec2(cam_pos.x + tr * sc.x / cam_f,
		cam_pos.y + dist * st + tr * (-st + ct * sc.y / cam_f));
	// рельеф при наклоне: луч встречает возвышенность раньше плоскости — сдвиг
	// выборки навстречу камере на высоту × наклон луча (параллакс, «подъём» гор)
	if (cam_tilt > 0.001) {
		float hh = max(textureLod(base_tex, vec3(wp / world_size, 0.0), 0.0).r - 0.5, 0.0) * 2.0;
		vec2 ray = vec2(sc.x / cam_f, -st + ct * sc.y / cam_f) / max(den, 1e-4);
		wp -= ray * hh * RELIEF_H;
	}
	vec2 muv = wp / world_size;
	// масштаб в этой точке экрана (вдали — мельче): по нему все приближения
	float zoom = cam_zoom * dist / tr;
	// вне карты — фон (без discard до производных: на GLES они тогда не определены)
	bool outside = den <= 1e-4 || muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0;
	muv = clamp(muv, vec2(0.0), vec2(1.0));
	float haze = clamp((tr / dist - 1.0) * 0.35, 0.0, 0.22) * smoothstep(0.05, 0.5, cam_tilt);
	vec2 px = muv * map_size;
	ivec2 ip = ivec2(floor(px));
	// координаты волн и их производные (до ветвлений по пикселю)
	vec2 wv_uv = px / (WATER_TILE * id_k);
	vec2 wv_gx = dFdx(wv_uv);
	vec2 wv_gy = dFdy(wv_uv);
	// изменение пикселей карты 1× на пиксель экрана — для спрайтов (mipmap)
	vec2 q_gx = dFdx(px) / id_k;
	vec2 q_gy = dFdy(px) / id_k;
	// реки: расстояние до осевой линии (пикселей карты) и его изменение на пиксель
	// экрана — до ветвлений (fwidth)
	// сила реки (1 — крупная, 0,67 — средняя, 0,39 — малая) — в канале g рельефа
	vec2 rv = vec2(0.0, has_rivers ? textureLod(base_tex, vec3(muv, 0.0), 0.0).g : 0.0);
	// приведённые расстояния: до ближайшей реки и до реки «с другой стороны»
	// (второе русло, угол слияния)
	vec4 rv4 = has_rivers ? texture(base_tex, vec3(muv, 1.0)) : vec4(1.0, 1.0, 1.0, 1.0);
#ifndef BAKED
	// покров суши — до ветвлений (mipmap по производным)
	mediump vec4 cv = has_cover ? texture(base_tex, vec3(muv, 2.0)) : vec4(0.0);
#endif
	// вблизи — расстояние с гладким слиянием соседних русел (готово в данных)
	float rv_ds = rv4.b * RIVER_MAX;
	// длина билинейного вектора — точна у одной реки; между двумя реками векторы
	// гасятся — тогда держит билинейное расстояние (a): у осевой линии оно
	// недобирает до ~0,7 текселя (допуск 0,75), а где 4 соседних текселя
	// смотрят на разные реки (средняя линия между руслами) — почти точно
	// (допуск 0,1, иначе вдоль средней линии тянется ложный «палец» воды)
	float rv_slack = 0.75;
	if (has_rivers) {
		ivec2 rsz = textureSize(base_tex, 0).xy;
		ivec2 rc = ivec2(floor(muv * vec2(rsz) - 0.5));
		vec2 rn[4];
		float rl[4];
		for (int k = 0; k < 4; k++) {
			vec2 q = texelFetch(base_tex, ivec3(clamp(rc + ivec2(k & 1, k >> 1), ivec2(0), rsz - 1), 1), 0).rg * 255.0 - 128.0;
			rl[k] = length(q) / 127.0 * RIVER_MAX;
			rn[k] = q / max(length(q), 1e-3);
		}
		float mc = 1.0;
		for (int i = 0; i < 4; i++) {
			for (int j = i + 1; j < 4; j++) {
				// средняя линия между руслами — векторы смотрят ПРОЧЬ друг от друга;
				// по разные стороны одной реки они смотрят навстречу (это не развилка:
				// иначе тонкая река, идущая между текселями, рвалась пунктиром)
				vec2 oij = vec2(ivec2(j & 1, j >> 1) - ivec2(i & 1, i >> 1));
				if (rl[i] > 0.15 && rl[j] > 0.15 && dot(rn[i], oij) < 0.0 && dot(rn[j], oij) > 0.0) {
					mc = min(mc, dot(rn[i], rn[j]));
				}
			}
		}
		rv_slack = mix(0.75, 0.1, smoothstep(0.3, -0.3, mc));
	}
	float rv_d = max(length((rv4.rg * 255.0 - 128.0) / 127.0) * RIVER_MAX, rv4.a * RIVER_MAX - rv_slack);
	float rv_fw = max(fwidth(rv_d), 1e-4);
	float river_m = 0.0;   // доля ленты реки в пикселе (под ней линию провинций не рисуем)
	float river_out = 0.0;   // край ленты с берегами от осевой линии, пикс. карты (0 — реки нет)
	float river_nk = 0.0;    // вблизи — лента (0…1)
	// поле расстояний до границ провинций (текселей сетки; без поля — далеко)
	float sdf_tx = 1e4;
	if (has_sdf) {
		bool s_east = px.x >= float(ids_half);
		vec2 suv = vec2((s_east ? px.x - float(ids_off) : px.x) / sdf_wd, muv.y);
		vec2 sgx = vec2(dFdx(px.x) / sdf_wd, dFdx(muv.y));
		vec2 sgy = vec2(dFdy(px.x) / sdf_wd, dFdy(muv.y));
		float sd = textureGrad(sdf_tex, vec3(suv, s_east ? 1.0 : 0.0), sgx, sgy).r;
		sdf_tx = sd * 2.0;
	}
	// Сглаженные границы: берём 4 ближайших текселя карты и выбираем провинцию с
	// наибольшим весом билинейной интерполяции — граница идёт плавной кривой, а не
	// «лесенкой» пикселей. diff — запас победителя над вторым: 0 на самой границе.
	// Сглаживание: соперники — провинции 4 ближайших текселей; их веса считаются
	// по окну 4×4 текселя с кубическими B-сплайн весами — граница выходит гладкой
	// кривой без изломов. Ближайший тексель получает небольшой перевес, чтобы
	// мелкие острова и узкие перешейки не «таяли» от размытия.
	vec2 q = px - 0.5;
	ivec2 i0 = ivec2(floor(q));
	vec2 tf = fract(q);
	// до NS разных провинций в окне; веса непрерывны при сдвиге окна (вклад
	// B-сплайна / билинейный на краях окна плавно уходит в ноль) — без ложных полос
	int uid[NS] = int[](-1, -1, -1, -1, -1, -1, -1, -1);
	float uw[NS] = float[](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
	bool win_bl = true;   // окно 2×2 (билинейные веса) — для border_tx
	// сколько разных провинций в окне: все циклы по провинциям — до un (а не NS):
	// у большинства пикселей одна провинция, полный перебор массивов дорог на ГП телефона
	int un = 1;
	if (quality == 0) {
		// низкое качество: провинция ближайшего текселя, без сглаживания (1 выборка)
		uid[0] = pid(ip);
		uw[0] = 1.0;
	} else if (has_sdf && sdf_tx > 1.98) {
		// быстрый путь (ноябрь 2026, оптимизация для телефона): до сглаженной
		// границы не меньше 2 текселей (поле насыщено) — в окне одна провинция,
		// перебор окна 4×4 с массивами (дорог на мобильных ГП) не нужен
		uid[0] = pid(ip);
		uw[0] = 1.0;
	} else {
	bool far = zoom * 2.0 / id_k < 1.2 || quality < 2;
	if (far && sdf_tx < 1.6 && quality == 1 && zoom * 2.0 / id_k >= 1.2) {
		// среднее качество с полем расстояний: у границы — окно 4×4, как у линий
		// (иначе заливка идёт лесенкой мимо гладкой линии); вдали — 2×2
		far = false;
	}
	win_bl = far;
	vec4 wx;
	vec4 wy;
	vec4 bx = vec4(0.0, 1.0 - tf.x, tf.x, 0.0);   // билинейные веса (перевес ближних)
	vec4 by = vec4(0.0, 1.0 - tf.y, tf.y, 0.0);
	if (far) {
		wx = bx;
		wy = by;
	} else {
		vec2 t2 = tf * tf;
		vec2 t3 = t2 * tf;
		wx = vec4((1.0 - tf.x) * (1.0 - tf.x) * (1.0 - tf.x), 3.0 * t3.x - 6.0 * t2.x + 4.0,
			-3.0 * t3.x + 3.0 * t2.x + 3.0 * tf.x + 1.0, t3.x) / 6.0;
		wy = vec4((1.0 - tf.y) * (1.0 - tf.y) * (1.0 - tf.y), 3.0 * t3.y - 6.0 * t2.y + 4.0,
			-3.0 * t3.y + 3.0 * t2.y + 3.0 * tf.y + 1.0, t3.y) / 6.0;
		// плавный перевес ближних текселей: мелкие острова и перешейки не тают
		wx = wx + bx * 0.35;
		wy = wy + by * 0.35;
	}
	int o0 = far ? 1 : 0;
	int o1 = far ? 3 : 4;
	un = 0;
	for (int oy = o0; oy < o1; oy++) {
		for (int ox = o0; ox < o1; ox++) {
			int cidv = pid(i0 + ivec2(ox - 1, oy - 1));
			float w = wx[ox] * wy[oy];
			int k = -1;
			for (int j = 0; j < un; j++) {
				if (uid[j] == cidv) {
					k = j;
				}
			}
			if (k < 0 && un < NS) {
				k = un;
				uid[k] = cidv;
				un++;
			}
			if (k >= 0) {
				uw[k] += w;
			}
		}
	}
	}
	int top = 0;
	for (int j = 1; j < un; j++) {
		if (uw[j] > uw[top]) {
			top = j;
		}
	}
	int sec = -1;
	for (int j = 0; j < un; j++) {
		if (j != top && uid[j] >= 0 && (sec < 0 || uw[j] > uw[sec])) {
			sec = j;
		}
	}
	int id = uid[top];
	float diff = sec >= 0 ? (uw[top] - uw[sec]) / (uw[top] + uw[sec]) : 1.0;
	int id2 = sec >= 0 ? uid[sec] : id;
	// Берег — по доле суши из векторных контуров (канал b рельефа, tools/build_map.py):
	// уровень 0.5 даёт настоящую плавную линию берега. Если победила провинция не той
	// стихии — берём лучшего соперника нужной (суша) или рисуем воду.
	float cov = quality > 0 ? textureLod(base_tex, vec3(muv, 0.0), 0.0).b : 0.5;
	int nat_c[NS] = int[](-2, -2, -2, -2, -2, -2, -2, -2);
	for (int j = 0; j < un; j++) {
		nat_c[j] = uid[j] >= 0 ? nation(pal(0, uid[j])) : -2;
	}
	bool wide_land = false;   // суша найдена вне окна — границ стран/провинций тут не рисуем
	bool cov_land = quality > 0 ? cov >= 0.5 : nation(pal(0, uid[top])) >= 0;
	if (cov_land && nat_c[top] < 0) {
		int bl = -1;
		for (int j = 0; j < un; j++) {
			if (nat_c[j] >= 0 && (bl < 0 || uw[j] > uw[bl])) {
				bl = j;
			}
		}
		if (bl >= 0) {
			top = bl;
			id = uid[top];
		} else {
			// векторный контур уже суша, а в окне сглаживания одна вода (берег
			// большого озера-зоны) — ищем ближайшую сушу чуть дальше, иначе тут
			// остаётся квадратик воды за линией берега
			float bd = 1e9;
			for (int oy = -2; oy <= 2; oy++) {
				for (int ox = -2; ox <= 2; ox++) {
					ivec2 cp = ip + ivec2(ox, oy);
					int cid = pid(cp);
					if (nation(pal(0, cid)) < 0) {
						continue;
					}
					vec2 dd = vec2(cp) + 0.5 - px;
					float d = dot(dd, dd);
					if (d < bd) {
						bd = d;
						id = cid;
					}
				}
			}
			wide_land = bd < 1e8;
		}
	}
	vec4 cc = pal(0, id);
	vec4 oc = pal(1, id);
	int ctrl = nation(cc);
	bool land = ctrl >= 0;
	bool sea_px = !cov_land && land;   // суша по провинции, но по контуру — уже вода

#ifndef BAKED
	float h = textureLod(base_tex, vec3(muv, 0.0), 0.0).r;
	mediump float light = light_at(muv);
#endif

#ifndef BAKED
	// свет по нормалям рельефа (has_art): ближе — рельеф сильнее (как на картах
	// жанра: горы объёмны вблизи); вблизи на высоком качестве — бикубически
	float near_k = smoothstep(0.35, 1.6, zoom);
	mediump float rf = 1.0;
	mediump float slope = 0.0;
	float elev_m = 0.0;          // высота суши, м
	mediump float mnt = 0.0;     // доля «горы»: скалы
	mediump float snow = 0.0;    // доля снега
	float rel_m = 0.0;           // высота против окрестности, м (гребень +, долина −)
	mediump float rock_v = 0.5;  // разброс цвета скал
	mediump float alp = 0.0;     // высокогорный пояс у снеговой линии
	mediump float hill = 0.0;    // доля «холмы»: средний уклон ниже гор
	mediump vec4 dnw = vec4(0.5);   // фактура крупной шкалы (рисунок дюн, разброс цвета)
	// половина подложки и производные координат (до ветвлений по пикселю)
	float ax = muv.x * art_geom.x;
	bool a_east = ax >= art_geom.x * 0.5;
	vec2 auv = vec2((a_east ? ax - art_geom.y : ax) / art_geom.z, muv.y);
	vec2 agx = vec2(dFdx(muv.x) * art_geom.x / art_geom.z, dFdx(muv.y));
	vec2 agy = vec2(dFdy(muv.x) * art_geom.x / art_geom.z, dFdy(muv.y));
	vec2 ats = art_geom.zw;
	float a_layer = a_east ? 1.0 : 0.0;
	if (has_art) {
		vec2 g;
		if (quality == 2 && zoom > 0.9) {
			g = tex_bicubic(normal_tex, auv, a_layer, ats, agx, agy).rg;
		} else {
			g = textureGrad(normal_tex, vec3(auv, a_layer), agx, agy).rg;
		}
		vec2 nxy = g * 2.0 - 1.0;
		slope = length(nxy);
		vec3 nn = normalize(vec3(nxy * mix(0.7, 1.3, near_k), sqrt(max(0.0, 1.0 - dot(nxy, nxy)))));
		vec3 ld = normalize(vec3(-0.55, -0.65, 0.75));
		// горы (как в жанре): высота суши ETOPO1 (relief.r = 0.5 + 0.5·√(h/6000 м)),
		// скалы — крутые склоны выше предгорий, снег — выше снеговой линии по широте;
		// в горах светотень сильнее
		elev_m = pow(max(h - 0.5, 0.0) * 2.0, 2.0) * 6000.0;
		// вблизи (высокое качество) — высоты вдвое подробнее (elev_*, tools/etopo.py),
		// издали — карта высот 1× и детали из нормалей и фактуры (решение пользователя)
		float ek = (has_elev && quality == 2) ? smoothstep(0.9, 1.6, zoom) : 0.0;
		if (ek > 0.0) {
			float e2 = textureGrad(color_tex, vec3(auv, a_layer), agx, agy).a;
			elev_m = mix(elev_m, e2 * e2 * 6000.0, ek);
		}
		// крупный рельеф 1× в ±2 пикс.: гребни и долины (высота против средней) и
		// уклон для масок гор — на самом гребне и дне долины нормаль ровная (уклон 0),
		// маски по нему давали прожилки; соседние тексели 1× давали лесенку (8 бит)
		float s_mask = slope;
		if (elev_m > 300.0) {
			vec2 t2 = 2.0 / map_size;
			float q_e = textureLod(base_tex, vec3(muv + vec2(t2.x, 0.0), 0.0), 0.0).r;
			float q_w = textureLod(base_tex, vec3(muv - vec2(t2.x, 0.0), 0.0), 0.0).r;
			float q_s = textureLod(base_tex, vec3(muv + vec2(0.0, t2.y), 0.0), 0.0).r;
			float q_n = textureLod(base_tex, vec3(muv - vec2(0.0, t2.y), 0.0), 0.0).r;
			s_mask = max(slope, length(vec2(q_e - q_w, q_s - q_n)) * 10.0);
			float hb = 0.25 * (q_e + q_w + q_s + q_n);
			float rel1 = pow(max(h - 0.5, 0.0) * 2.0, 2.0) * 6000.0 - pow(max(hb - 0.5, 0.0) * 2.0, 2.0) * 6000.0;
			rel_m = rel1;
			if (ek > 0.0) {
				// то же по подробной карте: ±2 текселя подложки (вдвое ближе)
				vec2 o = 2.0 / ats;
				float eb = textureGrad(color_tex, vec3(auv + vec2(o.x, 0.0), a_layer), agx, agy).a + textureGrad(color_tex, vec3(auv - vec2(o.x, 0.0), a_layer), agx, agy).a
					+ textureGrad(color_tex, vec3(auv + vec2(0.0, o.y), a_layer), agx, agy).a + textureGrad(color_tex, vec3(auv - vec2(0.0, o.y), a_layer), agx, agy).a;
				eb *= 0.25;
				rel_m = mix(rel1, elev_m - eb * eb * 6000.0, ek);
			}
		}
		mnt = smoothstep(0.10, 0.36, s_mask) * smoothstep(200.0, 1100.0, elev_m);
		// холмы (как в жанре): холмистый рельеф ниже гор — по уклону и высоте над окрестностью
		// холмы (как в жанре): холмистость края (разброс высот в ~60 км, cover.a)
		// ниже гор — Арденны, Богемия; равнины Парижа и Украины — нет
		hill = smoothstep(0.2, 0.45, cv.a) * (1.0 - smoothstep(0.15, 0.5, mnt));
		rf = clamp(mix(1.0, dot(nn, ld) / ld.z, mix(0.55, 0.8, near_k) + 0.2 * mnt), 0.36, 1.4);
		rf *= 1.0 + clamp(rel_m / 1400.0, -0.22, 0.10) * smoothstep(0.0, 0.5, mnt);
		float lat_d = lat_at(px);
		// снеговая линия по широте и сезону (решение пользователя: зимой горы в снегу,
		// летом снег только на высочайших вершинах — проступают скалы и гребни);
		// в южном полушарии сезоны наоборот
		float wint = lat_d >= 0.0 ? winter : 1.0 - winter;
		float sline = mix(4800.0, 800.0, smoothstep(8.0, 72.0, abs(lat_d)))
			- wint * mix(500.0, 2000.0, smoothstep(20.0, 62.0, abs(lat_d)));
		// граница снега — по рельефу, не по текселям: выше на солнечных и крутых
		// гранях, ниже на склонах к полюсу и в цирках; рваный край — по фактуре
		// (две шкалы), на отвесных стенах снег не держится
		mediump vec4 dn = has_detail ? texture(tile_tex, vec3(px / (DETAIL_TILE * id_k), 1.0)) : vec4(0.5);
		mediump vec4 dn2 = has_detail ? texture(tile_tex, vec3(px / (DETAIL_TILE * 4.7 * id_k) + vec2(0.37, 0.61), 1.0)) : vec4(0.5);
		float pole = lat_d >= 0.0 ? -nxy.y : nxy.y;
		float e_eff = elev_m + max(rel_m, 0.0) * 0.7 + min(rel_m, 0.0) * mix(0.5, 0.15, wint) + pole * 400.0 - (rf - 1.0) * 700.0 - slope * 300.0
			+ ((dn.a - 0.5) * 450.0 * (1.0 - ek) + (dn2.g - 0.5) * 900.0);
		snow = smoothstep(sline - 220.0 - 130.0 * ek, sline + 160.0 + 90.0 * ek, e_eff) * (1.0 - 0.45 * smoothstep(0.85, 1.0, slope));
		// на ровных высоких плато (Тибет, Альтиплано) вечного снега нет — он на гребнях
		// и склонах (зимой ложится и на плато); снег — только в горах, не на равнинах
		// долина среди гор (ниже окрестности) — тоже горы; плато и равнины (вровень) — нет
		float vly = max(-rel_m, 0.0) / 500.0;
		snow *= mix(smoothstep(0.05, 0.2, s_mask + max(rel_m, 0.0) / 1200.0 + vly), 1.0, wint * 0.3);
		snow *= smoothstep(350.0, 900.0, elev_m) * smoothstep(0.0, 0.35, mnt + max(rel_m, 0.0) / 900.0 + vly);
		rock_v = dn.g * 0.6 + dn2.r * 0.4;
		dnw = dn2;
		// высокогорье у снеговой линии (луга, осыпи, каменистые днища долин) — без
		// него долины в снегу проступали цветом страны пятнами
		alp = smoothstep(sline - 1000.0, sline - 250.0, elev_m) * smoothstep(700.0, 1200.0, elev_m)
			* smoothstep(0.0, 0.25, mnt + snow);
	}
#endif
#ifdef BAKE_OUT
	vec4 bk_out = vec4(0.0);
#endif
	mediump vec3 col;   // цвет — в половинной точности (дешевле на мобильных ГП)
	// мелкие озёра входят в провинции суши, но по высоте ниже уровня моря — вода
	// (только на низком качестве: на среднем и высоком озёра — в векторном контуре)
	bool lake = quality == 0 && land && textureLod(base_tex, vec3((vec2(ip) + 0.5) / map_size, 0.0), 0.0).r < 0.49;
#ifdef BAKED
	vec4 bk = bake_at(wp, zoom, land && !lake && !sea_px);
#endif
	if (!land || lake || sea_px) {
#ifdef BAKED
		col = bk.rgb * BK_V;
#else
		// вода: мелководье у берегов светлее, глубина темнее, лёгкая рябь
		float depth = clamp((0.5 - h) * 2.4, 0.0, 1.0);
		if (has_art) {
			// глубина ETOPO1 (relief.r, лог. шкала): шельф — светлый сине-зелёный,
			// склон — синий, впадины — тёмно-синие; рельеф дна — светом (слабее суши)
			depth = clamp((0.5 - h) / 0.45, 0.0, 1.0) * (1.0 - smoothstep(0.0, 0.5, cov) * 0.4);
			col = mix(vec3(0.26, 0.46, 0.52), vec3(0.10, 0.25, 0.36), smoothstep(0.0, 0.5, depth));
			col = mix(col, vec3(0.035, 0.09, 0.17), smoothstep(0.45, 1.0, depth));
			col *= mix(1.0, rf, 0.55);
			if (has_water && quality > 0) {
				// волны (две октавы), свет и блик солнца; издали гаснут (иначе муар)
				float wk = smoothstep(0.5, 1.8, zoom);
				vec2 w1 = textureGrad(tile_tex, vec3(wv_uv, 0.0), wv_gx, wv_gy).rg * 2.0 - 1.0;
				vec2 w2 = textureGrad(tile_tex, vec3(wv_uv * 2.7 + vec2(0.37, 0.61), 0.0), wv_gx * 2.7, wv_gy * 2.7).rg * 2.0 - 1.0;
				vec3 wn = normalize(vec3((w1 + w2 * 0.5) * 0.45, 1.0));
				vec3 sl = normalize(vec3(-0.55, -0.65, 0.75));
				float wd = dot(wn, sl) / sl.z;
				float spec = pow(max(dot(wn, normalize(sl + vec3(0.0, 0.0, 1.0))), 0.0), 70.0);
				col *= mix(1.0, wd, 0.22 * wk);
				col += vec3(0.85, 0.92, 1.0) * spec * 0.22 * wk * (0.4 + 0.6 * depth);
				// прибой: светлая полоса вдоль берега (по доле суши)
				col = mix(col, vec3(0.62, 0.76, 0.78), smoothstep(0.04, 0.45, cov) * 0.3 * smoothstep(0.8, 2.0, zoom));
			}
		} else {
			if (quality > 0) {
				// глубина по растру не доходит до нуля у самого берега (иначе светлая
				// кайма повторяет пиксели), мелководье — узкой полосой по контуру
				depth = clamp((0.5 - min(h, 0.45)) * 2.4, 0.0, 1.0) * (1.0 - smoothstep(0.0, 0.5, cov) * 0.7);
			}
			col = mix(vec3(0.22, 0.42, 0.50), vec3(0.07, 0.15, 0.25), pow(depth, 0.45));
		}
		float wave = sin(px.x / id_k * 0.21 + sin(px.y / id_k * 0.13) * 2.0);   // рябь (неподвижная: карта рисуется по изменениям)
		col += vec3(0.015) * wave * (1.0 - depth * 0.5);
		// сетка широт и долгот через 15° — как на штабной карте
		float s_px = map_size.x / 6.2831853;
		float lon = degrees(px.x / s_px) + lon_min;
		float lat = lat_at(px);
		float gl = abs(fract(lon / 15.0 + 0.5) - 0.5) * 15.0;
		float ga = abs(fract(lat / 15.0 + 0.5) - 0.5) * 15.0;
		float pxdeg = 360.0 / map_size.x;   // градусов долготы в пикселе карты
		float line = max(1.0 - smoothstep(0.0, pxdeg * 1.2, gl), 1.0 - smoothstep(0.0, pxdeg * 1.2, ga));
		col = mix(col, vec3(0.55, 0.68, 0.74), line * 0.18 * smoothstep(0.15, 0.5, zoom));
#ifdef BAKE_OUT
		bk_out = vec4(clamp(col / BK_V, 0.0, 1.0), 1.0);
#endif
#endif
	} else {
#ifdef BAKE_OUT
		LC base = vec4(0.0, 0.0, 0.0, 1.0);
#else
		mediump vec3 base = cc.rgb;
		int own = nation(oc);
		if (show_occupation && own != ctrl) {
			float s = step(0.5, fract((px.x + px.y) / id_k * 0.28));
			base = mix(base, oc.rgb, s * 0.75);
		}
#endif
#ifdef BAKED
		col = base * ((1.0 - bk.a) * BK_S) + bk.rgb * BK_V;
#else
		LC lc;
		if (has_art) {
			// как на картах жанра: издали — «бумажная» политическая карта (цвет
			// страны, рельеф едва заметен), вблизи — природные зоны (Natural Earth)
			// сквозь полупрозрачный цвет страны и объёмный свет рельефа (ETOPO1)
			mediump vec3 terr = textureGrad(color_tex, vec3(auv, a_layer), agx, agy).rgb;
			mediump float tl = dot(terr, vec3(0.299, 0.587, 0.114));
			terr = clamp(vec3(tl) + (terr - vec3(tl)) * 1.35, 0.0, 1.0) * 0.96;
			// горы: серо-бурые скалы и белый снег поверх природных зон
			// скалы: от тёмно-серых до охристых осыпей, в тени долин темнее
			mediump vec3 rock = mix(vec3(0.43, 0.41, 0.39), vec3(0.62, 0.55, 0.45), rock_v) * (0.85 + 0.3 * tl);
			// пустыни и степи по климату (relief.a = 1 − сухость: пустыня BW — 1,
			// степь BS — 0,5; Кёппен — Гейгер 1901–1930, build_map --kg): пески (эрги)
			// на ровном, каменистая пустыня (хамада) на склонах и плато; степь — выгоревшая
			float dry = 1.0 - textureLod(base_tex, vec3(muv, 0.0), 0.0).a;
			mediump float des = smoothstep(0.55, 0.9, dry);
			mediump float stp = smoothstep(0.2, 0.5, dry) * (1.0 - des);
			// разнообразие (решение пользователя: не один узор на всю пустыню):
			// крупно — песчаные моря (эрги) и щебнистые равнины (реги) пятнами, тон
			// песка от светлого до оранжево-красного; на склонах — хамада
			vec2 qd = px / id_k;
			mediump float ergf = 0.0;
			mediump vec3 des_c = terr;
			if (des > 0.0) {
				float f1 = vnoise(qd / 95.0) * 0.65 + vnoise(qd / 33.0 + vec2(7.1, 3.3)) * 0.35;
				ergf = smoothstep(0.30, 0.52, f1);
				float tn = vnoise(qd / 140.0 + vec2(19.0, 2.0)) * 0.7 + vnoise(qd / 45.0 + vec2(5.0, 31.0)) * 0.3;
				mediump vec3 sand = tn < 0.5
					? mix(vec3(0.95, 0.88, 0.68), vec3(0.91, 0.76, 0.50), smoothstep(0.2, 0.5, tn))
					: mix(vec3(0.91, 0.76, 0.50), vec3(0.85, 0.59, 0.37), smoothstep(0.5, 0.82, tn));
				// рег: серо-бурый щебень с тёмными пятнами «пустынного загара»
				// мелкие пятна — только вблизи (издали шум 3,5 пикс. давал квадратную рябь)
				float sp = mix(0.5, vnoise(qd / 3.5 + vec2(2.3, 8.1)), smoothstep(1.4, 2.6, zoom));
				float sp2 = vnoise(qd / 18.0 + vec2(12.3, 4.1));
				mediump vec3 reg = mix(vec3(0.84, 0.72, 0.55), vec3(0.76, 0.62, 0.47), sp2);
				reg = mix(reg, vec3(0.60, 0.49, 0.39), smoothstep(0.5, 0.85, sp) * 0.6);
				mediump vec3 hamada = mix(vec3(0.60, 0.44, 0.31), vec3(0.73, 0.59, 0.43), rock_v);
				des_c = mix(reg, sand, ergf);
				des_c = mix(hamada, des_c, 1.0 - smoothstep(0.06, 0.28, slope));
				des_c = mix(des_c, terr, 0.15) * (0.92 + 0.16 * tl);
			}
			mediump float erg = (1.0 - smoothstep(0.06, 0.28, slope)) * ergf;
			terr = mix(terr, terr * vec3(1.06, 0.98, 0.80) + vec3(0.03, 0.02, 0.0), stp * 0.55);
			terr = mix(terr, des_c, des * 0.85);
			terr = mix(terr, rock, max(mnt * 0.8, alp * 0.85));
			terr = mix(terr, vec3(0.94, 0.95, 0.97), snow);
			// --- покров суши (как в жанре): лес, болота, пашни, холмы, города -------
			// издали — лёгкий тон поверх цвета страны, вблизи — рисунок
			// (кроны, окна воды, поля, кварталы); всё неподвижно — уходит в заготовки
			vec2 qc = px / id_k;   // пиксели карты 1×
			float lat_c = abs(lat_at(px));
			float free_k = (1.0 - des) * (1.0 - max(mnt, alp)) * (1.0 - snow);
			// рваный край леса и болота — шумом, не по текселям
			float edge_n = vnoise(qc * 0.9 + vec2(3.1, 7.7)) - 0.5;
			// лес — по сглаженной доле (mip 1,5): без мелких островков, колечек и острых углов
			float cv_f = has_cover ? textureLod(base_tex, vec3(muv, 2.0), 1.5).r : 0.0;
			mediump float fo = smoothstep(0.40, 0.48, max(cv_f, cv.r * 0.6) + edge_n * 0.12) * (1.0 - 0.5 * mnt) * (1.0 - des) * (1.0 - snow);
			// в провинции города леса нет вовсе (решение пользователя: где лес заходит на
			// провинцию города — убрать полностью); край чуть шире провинции — под линией границы
			bool town_px = quality == 2 && has_sprites && zoom > 1.5;
			float town_here = town_px ? smoothstep(0.0, 0.45, town_soft_k(qc0(px), map_size / id_k, 1.1, id, int(pal(2, id).b * 255.0 + 0.5))) : 0.0;
			// рощи и перелески на равнинах и холмах (как в жанре; решение пользователя:
			// «равнины и холмы живее»): пятна неправильной формы тем же пологом, что лес
			// (не одиночные деревья — их пользователь отверг); на холмах гуще, в степи
			// реже, не в застройке и не в тундре; только вблизи (издали — крапины)
			// форма — вытянутая и неровная: шум растянут по случайному на край направлению
			vec2 gq = qc / 2.6;
			gq = vec2(gq.x * 0.8 + gq.y * 0.35, gq.y * 1.25 - gq.x * 0.2);
			float gr_n = vnoise(gq + vec2(41.0, 13.0)) * 0.62 + vnoise(qc / 1.0 + vec2(7.0, 29.0)) * 0.26 + vnoise(qc * 2.4 + vec2(3.0, 3.0)) * 0.12;
			float gr_th = mix(0.75, 0.66, hill) + 0.06 * stp;
			mediump float grove = smoothstep(gr_th, gr_th + 0.035, gr_n) * free_k * (1.0 - smoothstep(0.02, 0.15, cv.b))
				* (1.0 - smoothstep(0.15, 0.35, cv.g)) * (1.0 - smoothstep(60.0, 66.0, lat_c)) * smoothstep(1.8, 2.6, zoom);
			fo = max(fo, grove);
			fo *= 1.0 - town_here;
			hill *= 1.0 - town_here;
			mediump float ms = smoothstep(0.10, 0.42, cv.g + edge_n * 0.15) * free_k * (1.0 - town_here);
			mediump float ub = smoothstep(0.02, 0.45, cv.b) * (1.0 - snow);
			// рисовые чеки — муссонная Азия (Индия, Индокитай, Китай южнее Хуанхэ, Япония)
			float lon_c = degrees(px.x / (map_size.x / 6.2831853)) + lon_min;
			mediump float rc = smoothstep(68.0, 74.0, lon_c) * (1.0 - smoothstep(142.0, 146.0, lon_c))
				* (1.0 - smoothstep(34.0, 38.0, lat_at(px))) * smoothstep(-9.0, -5.0, lat_at(px)) * (1.0 - stp) * free_k * (1.0 - ub);
			fo *= 1.0 - ms * 0.6;
			// пашня: ровные обжитые места умеренного пояса (1936 г.: распахано почти
			// всё, что не лес, не болото, не степь и не пустыня)
			mediump float fl = (1.0 - smoothstep(0.55, 0.9, cv.a)) * free_k * (1.0 - fo) * (1.0 - ms) * (1.0 - ub)
				* (1.0 - stp * 0.6) * (1.0 - smoothstep(58.0, 64.0, lat_c));
			fl *= 1.0 - town_here;   // в городе — ни полей, ни травы
			// пойменные луга вдоль рек — полоса свежей зелени вместо пашни
			mediump float mead = has_rivers ? (1.0 - smoothstep(0.7, 2.0, rv_d)) * step(0.01, rv.g) * free_k
				* (1.0 - smoothstep(0.02, 0.2, cv.b)) * (1.0 - town_here) * (1.0 - fo) : 0.0;
			fl *= 1.0 - mead * 0.8;
			rc *= fl;
			fl *= 1.0 - rc;
			float dk_c = (quality == 2) ? smoothstep(1.6, 3.0, zoom) : 0.0;   // рисунок вблизи
			mediump float tex_c = 0.0;   // светотень рисунка (−…+)
			mediump float hedge_m = 0.0; // доля изгороди в пикселе (цвет страны под ней слабее)
			// пойменный луг: свежая зелень, кое-где кусты
			if (mead > 0.0 && dk_c > 0.0) {
				mediump vec3 mcol = mix(vec3(0.44, 0.57, 0.29), vec3(0.52, 0.61, 0.33), vnoise(qc * 0.8 + vec2(6.0, 2.0)));
				terr = mix(terr, mcol, mead * dk_c * 0.6);
				tex_c += (vnoise(qc * 7.0 + vec2(2.0, 5.0)) - 0.5) * 0.08 * mead * dk_c;
			}
			float pool_m = 0.0;          // окно воды болота (кувшинки атласа)
			// холмы: оливково-бурый тон, вблизи — округлые бугры (свет с северо-запада)
			if (hill > 0.0) {
				terr = mix(terr, terr * vec3(1.02, 0.98, 0.86) + vec3(0.03, 0.02, 0.0), hill * 0.5 * free_k);
				if (dk_c > 0.0) {
					vec2 hq = qc * 1.3;
					float e = 0.35;
					float h0 = vnoise(hq) * 0.65 + vnoise(hq * 2.3 + vec2(5.0, 1.0)) * 0.35;
					float h1 = vnoise(hq + vec2(-e, -e)) * 0.65 + vnoise((hq + vec2(-e, -e)) * 2.3 + vec2(5.0, 1.0)) * 0.35;
					tex_c += (h1 - h0) * 1.6 * hill * free_k * (1.0 - fo * 0.5);
				}
			}
			// лес: тайга — тёмная сине-зелёная, широколиственный — светлее, тропики — сочные
			if (fo > 0.0) {
				mediump vec3 fc = mix(vec3(0.20, 0.31, 0.16), vec3(0.15, 0.24, 0.17), smoothstep(50.0, 60.0, lat_c));
				fc = mix(vec3(0.13, 0.30, 0.12), fc, smoothstep(20.0, 32.0, lat_c));
				fc *= 0.9 + 0.2 * vnoise(qc / 14.0 + vec2(2.0, 9.0));
				terr = mix(terr, mix(terr, fc, 0.75), fo);
				if (dk_c > 0.0) {
					// кроны: бугорки двух размеров, тень с юго-востока
					vec2 tq = qc * 4.2;
					float c0 = vnoise(tq);
					float c1 = vnoise(tq + vec2(-0.3, -0.3));
					float c2 = vnoise(qc * 9.5 + vec2(1.7, 4.4));
					tex_c += ((c1 - c0) * 0.9 + (c2 - 0.5) * 0.25 - (1.0 - c0) * 0.12) * fo;
				}
			}
			// болото: оливковая осока и мох, вблизи — окна тёмной воды с бликом и протоки,
			// кочки (как в жанре)
			if (ms > 0.0) {
				mediump vec3 mc = mix(vec3(0.37, 0.42, 0.26), vec3(0.45, 0.43, 0.29), vnoise(qc / 6.0 + vec2(8.0, 3.0)));
				terr = mix(terr, mix(terr, mc, 0.75), ms);
				if (dk_c > 0.0) {
					float pw = vnoise(qc * 0.75 + vec2(1.0, 6.0)) * 0.6 + vnoise(qc * 2.1 + vec2(9.0, 2.0)) * 0.3 + vnoise(qc * 5.3) * 0.1;
					float lim = mix(0.68, 0.56, smoothstep(0.3, 0.8, cv.g));   // гуще болото — больше воды
					float pool = smoothstep(lim, lim + 0.05, pw) * ms * dk_c;
					float rim = smoothstep(lim - 0.05, lim, pw) * (1.0 - smoothstep(lim, lim + 0.05, pw));
					mediump vec3 wcol = mix(vec3(0.24, 0.34, 0.36), vec3(0.40, 0.50, 0.52), smoothstep(lim + 0.05, lim + 0.2, pw));
					terr = mix(terr, wcol, pool * 0.9);
					pool_m = pool;
					terr = mix(terr, vec3(0.30, 0.36, 0.20), rim * ms * dk_c * 0.6);   // заросший край
					float tuft = vnoise(qc * 11.0 + vec2(2.0, 2.0));
					tex_c += (tuft - 0.5) * 0.16 * ms * (1.0 - pool);
				}
			}
			// пашни: лоскуты полей (пшеница, зелень, пар, луг), в каждом крае свой
			// наклон и шаг; живые изгороди — тёмные края
			if (fl > 0.01 && dk_c > 0.0) {
				// угол, шаг и вытянутость полей — свои на неровный участок ~11 пикс. (поворот
				// координат углом из плавного шума давал муар-«кольца»: фаза ∝ координате);
				// шов участков — межа
				vec2 rid = floor((qc + (vec2(vnoise(qc / 7.0), vnoise(qc / 7.0 + vec2(5.2, 1.3))) - 0.5) * 7.0) / 11.0);
				float hr = h21(rid + vec2(4.0, 4.0));
				float ang = (hr - 0.5) * 3.0;
				vec2 rq = vec2(cos(ang) * qc.x + sin(ang) * qc.y, -sin(ang) * qc.x + cos(ang) * qc.y) + h21(rid) * 13.0;
				// поля — ячейки Вороного (неправильные многоугольники разного размера, не
				// «кирпичная кладка» рядов прямоугольников — замечание пользователя),
				// в каждом крае свой размер и вытянутость вдоль своего направления
				float fsz = mix(0.75, 1.5, h21(rid + vec2(9.0, 1.0)));
				vec2 fst = vec2(mix(1.0, 2.0, h21(rid + vec2(2.0, 7.0))), 1.0);
				vec3 fv = field_vor3(rq / (fst * fsz));
				vec2 cid = fv.yz;   // номер ячейки
				float fe = fv.x * fsz;   // до края поля, пикс. (приближённо)
				float hc = h21(cid);
				// тон края + свой у поля: соседние поля ближе по цвету, изредка — иная культура
				float hb = h21(rid + vec2(21.0, 5.0));
				float pick = h21(cid + vec2(31.0, 7.0)) < 0.65 ? fract(hb + hc * 0.35) : hc;
				mediump vec3 fcol = pick < 0.3 ? vec3(0.74, 0.68, 0.45)
					: pick < 0.55 ? vec3(0.55, 0.61, 0.36)
					: pick < 0.75 ? vec3(0.62, 0.65, 0.43)
					: pick < 0.9 ? vec3(0.60, 0.53, 0.40) : vec3(0.68, 0.64, 0.48);
				// на холмах — больше пастбищ (зелень разных оттенков)
				if (h21(cid + vec2(5.0, 11.0)) < 0.25 + 0.55 * hill) {
					fcol = mix(vec3(0.46, 0.56, 0.31), vec3(0.57, 0.62, 0.38), h21(cid + vec2(13.0, 2.0)));
				}
				fcol *= 0.93 + 0.14 * h21(cid + vec2(3.0, 3.0));
				// чересполосица (Восточная Европа, Россия): часть наделов — узкие полосы
				float strip_k = smoothstep(14.0, 22.0, lon_c) * 0.5 + 0.12;
				if (h21(cid + vec2(7.0, 19.0)) < strip_k) {
					float sp = fract(rq.y / (fsz * 0.22) + hc * 7.0);
					float si = floor(rq.y / (fsz * 0.22) + hc * 7.0);
					fcol *= 0.9 + 0.2 * h21(vec2(si, cid.x + cid.y * 3.0));
					tex_c -= (1.0 - smoothstep(0.0, 0.12, min(sp, 1.0 - sp))) * 0.03 * fl * smoothstep(3.0, 4.5, zoom);
				}
				float wnt = (lat_at(px) >= 0.0 ? winter : 1.0 - winter) * smoothstep(30.0, 45.0, lat_c);
				fcol = mix(fcol, vec3(0.56, 0.50, 0.38) + (hc - 0.5) * 0.08, wnt * 0.7);   // зимой — пашня и стерня
				terr = mix(terr, mix(terr, fcol, 0.55), fl * dk_c);
				// борозды вдоль поля (у половины полей), межа — едва заметная полоса
				float furrow = step(0.5, h21(cid + vec2(8.0, 2.0))) * (sin(rq.y / fsz * 6.2831853 * (4.0 + 3.0 * hc)) * 0.5 + 0.5);
				tex_c += (furrow - 0.5) * 0.04 * fl * smoothstep(3.0, 4.5, zoom);
				tex_c -= (1.0 - smoothstep(0.02, 0.06, fe)) * 0.03 * fl * smoothstep(2.2, 3.4, zoom);
				// живые изгороди: полосы деревьев по краю части полей (бокаж — Нормандия,
				// Бретань, Англия, Ирландия; в других краях редки), с просветами; вблизи
				// бокаж: Нормандия и Бретань, Англия и Ирландия; вне его — только на холмах, редко
				float boc = max((1.0 - smoothstep(-0.5, 1.0, lon_c)) * smoothstep(46.5, 47.5, lat_c) * (1.0 - smoothstep(49.6, 50.2, lat_c)),
					(1.0 - smoothstep(1.5, 2.5, lon_c)) * smoothstep(49.8, 50.3, lat_c) * (1.0 - smoothstep(55.5, 57.5, lat_c)));
				float hg_on = step(h21(cid + vec2(17.0, 3.0)), 0.7 * boc + 0.12 * hill);
				float hg = (1.0 - smoothstep(0.07, 0.14, fe)) * hg_on * smoothstep(0.3, 0.45, vnoise(qc * 2.2 + vec2(3.0, 8.0)))
					* fl * dk_c * smoothstep(2.4, 3.4, zoom);
				// кроны изгороди: зелёные, бугорками (не тёмная линия)
				mediump vec3 hgc = vec3(0.24, 0.34, 0.17) * (0.8 + 0.4 * vnoise(qc * 9.0 + vec2(1.0, 1.0)));
				terr = mix(terr, hgc, hg * 0.7);
				hedge_m = hg;
			}
			// рис: мелкие залитые чеки, бирюзовый отблеск
			if (rc > 0.0 && dk_c > 0.0) {
				vec2 g = qc / vec2(0.55, 0.42);
				g.x += h21(vec2(floor(g.y), 7.0));
				float hc = h21(floor(g));
				mediump vec3 rcol = mix(vec3(0.42, 0.58, 0.40), vec3(0.40, 0.55, 0.55), step(0.6, hc));
				terr = mix(terr, mix(terr, rcol, 0.55), rc * dk_c);
				vec2 fq = fract(g);
				tex_c -= step(min(min(fq.x, 1.0 - fq.x), min(fq.y, 1.0 - fq.y)), 0.05) * 0.08 * rc * dk_c;
			}
			// города 1936 г.: издали — серо-бурые пятна, вблизи — кварталы с улицами
			mediump float ub_n = ub;
			if (ub > 0.0) {
				// сетка улиц — своя на участок ~5 пикс. (старый город, новые кварталы)
				vec2 rid = floor((qc + (vec2(vnoise(qc / 3.0), vnoise(qc / 3.0 + vec2(5.2, 1.3))) - 0.5) * 3.0) / 5.0);
				float ang = (h21(rid + vec2(1.0, 13.0)) - 0.5) * 1.6;
				vec2 rq = vec2(cos(ang) * qc.x + sin(ang) * qc.y, -sin(ang) * qc.x + cos(ang) * qc.y) + h21(rid) * 7.0;
				vec2 g = rq / vec2(0.55, 0.42);
				vec2 cid = floor(g);
				vec2 fq = fract(g);
				float hc = h21(cid + vec2(17.0, 3.0));
				float built = step(hc, cv.b * 1.5 + 0.1);   // окраины — редкие кварталы
				float street = step(min(min(fq.x, 1.0 - fq.x) * 0.55, min(fq.y, 1.0 - fq.y) * 0.42), 0.035);
				// крыши: черепица, шифер, жесть — приглушённые; дворы темнее
				float hr = h21(cid + vec2(2.0, 9.0));
				mediump vec3 roof = hr < 0.4 ? vec3(0.55, 0.43, 0.37) : hr < 0.75 ? vec3(0.47, 0.46, 0.45) : vec3(0.58, 0.54, 0.48);
				roof *= 0.86 + 0.24 * vnoise(g * 2.3);
				mediump vec3 uc_far = vec3(0.53, 0.50, 0.47);
				mediump vec3 uc_near = mix(vec3(0.74, 0.72, 0.67), roof, built * (1.0 - street));
				float dk_u = has_sprites ? dk_c * (1.0 - smoothstep(2.0, 3.0, zoom)) : dk_c;   // ближе — постройки атласа
				ub_n = ub * mix(1.0, max(built, 0.35), dk_u) * (has_sprites ? 1.0 - smoothstep(2.0, 3.0, zoom) : 1.0);
				terr = mix(terr, mix(uc_far, uc_near, dk_u), ub_n);
				tex_c += (built * (1.0 - street) - 0.5) * 0.1 * ub_n * dk_c;
			}
			// --- постройки и деревья атласа (вблизи, высокое качество) ---------------
			mediump float bld = 0.0;   // доля спрайта в пикселе (цвет страны под ним слабее)
			float dk_s = (has_sprites && quality == 2) ? smoothstep(2.0, 3.0, zoom) : 0.0;
			if (dk_s > 0.0) {
				vec2 msz = map_size / id_k;
				// лес: сплошной полог крон; хвойных больше к северу
				if (fo > 0.05) {
					float conif = smoothstep(45.0, 60.0, lat_c) * 0.85 + 0.1;
					// у городов и деревень леса нет (не растёт между домами)
					float cprob = smoothstep(0.15, 0.55, fo) * 1.05;
					vec4 tt = cprob > 0.0 ? canopy(qc, 0.95, cprob, conif, q_gx, q_gy) : vec4(0.0);
					terr = mix(terr, terr * 0.55, smoothstep(0.2, 0.5, fo) * dk_s);   // тень под пологом
					terr = mix(terr, tt.rgb, tt.a * dk_s);
					bld = max(bld, tt.a * 0.85);
				}
				// города и деревни: кварталы с улицами; к востоку от ~24° в. д. — избы
				float dens = 0.0;
				float street = 0.0;
				// каменная подложка города: старый камень под всей провинцией города
				float tdc = town_d(qc, msz);
				if (tdc > 0.2 && has_road_tex) {
					float gl2 = length(vec2(length(q_gx), length(q_gy)));
					vec3 stn = textureGrad(tile_tex, vec3(qc / 1.2, 10.0), vec2(gl2, 0.0) / 1.2, vec2(0.0, gl2) / 1.2).rgb;
					stn = mix(vec3(dot(stn, vec3(0.33))), stn, 0.4) * vec3(0.92, 0.88, 0.82) * (0.85 + 0.2 * vnoise(qc * 0.7));
					terr = mix(terr, stn, dk_s * 0.75 * step(0.2, tdc));
					bld = max(bld, 0.6 * step(0.2, tdc));
				}
				if (cv.b > 0.002 || tdc > 0.1) {   // город по провинции, деревни по застройке
					float lon_t = degrees(px.x / (map_size.x / 6.2831853)) + lon_min;
					vec3 suv;
					vec4 sp = town_cell(qc, msz, q_gx, q_gy, vec2(lon_t, lat_at(px)), dens, street, suv);
					if (sp.a > 0.0) {
						// тон построек к карте: чуть приглушить
						// старение (сильнее): выгоревшие краски, серо-бурый налёт и копоть, мох на
						// крышах, пятна грязи и потёки, у каждого дома свой износ
						float lum_s = dot(sp.rgb, vec3(0.3, 0.59, 0.11));
						vec2 hid = floor(qc / 1.5);
						float wear = h21(hid + vec2(4.0, 1.0));
						vec3 aged = mix(sp.rgb, vec3(lum_s), 0.2);
						aged = mix(aged, vec3(0.52, 0.47, 0.40) * (0.75 + 0.5 * lum_s), 0.1 + 0.12 * wear);
						float grime = vnoise(qc * 9.0) * 0.55 + vnoise(qc * 23.0 + vec2(3.0, 7.0)) * 0.45;
						float streak = vnoise(vec2(qc.x * 30.0, qc.y * 4.0));
						aged *= 0.9 + 0.18 * grime - 0.08 * smoothstep(0.5, 0.85, streak);
						aged = mix(aged, vec3(0.36, 0.39, 0.28), smoothstep(0.62, 0.8, vnoise(qc * 6.0 + vec2(9.0, 2.0))) * 0.12);   // мох
						aged = mix(aged, aged * 0.75, smoothstep(0.72, 0.9, vnoise(qc * 4.0 + vec2(1.0, 5.0))) * 0.15);    // копоть
						aged *= 0.88 + 0.16 * vec3(h21(hid + vec2(1.0, 0.0)), h21(hid + vec2(2.0, 0.0)), h21(hid + vec2(3.0, 0.0))) * vec3(1.0, 0.9, 0.8);
						sp.rgb = clamp(aged * 1.12, 0.0, 1.0);
					}
					// мостовая: старая брусчатка вдоль улицы, приглушённая к цвету земли, края
					// мягкие (без резкого бордюра), к краю — пыль и тень от домов
					vec3 pave = mix(terr, vec3(0.52, 0.50, 0.46), 0.6);
					if (has_road_tex && street > 0.0) {
						float gl = length(vec2(length(q_gx), length(q_gy)));
						vec2 tuv = suv.xy / 0.5;
						vec3 tx = textureGrad(tile_tex, vec3(tuv, 8.0), vec2(gl, 0.0) / 0.5, vec2(0.0, gl) / 0.5).rgb;
						float tl2 = dot(tx, vec3(0.33));
						pave *= 0.85 + 0.3 * tl2;   // только рисунок камней, цвет — свой
						float side = 1.0 - suv.y / max(suv.z, 1e-3);   // 0 — ось, 1 — край
						pave = mix(pave, terr * 0.9, smoothstep(0.55, 1.0, side) * 0.55);   // пыль к краю
						pave *= 1.0 - 0.12 * smoothstep(0.75, 1.0, side);
						pave *= 0.9 + 0.2 * vnoise(qc * 3.0 + vec2(4.0, 4.0));   // заплаты и грязь
					}
					terr = mix(terr, pave, street * dk_s * 0.7);
					terr = mix(terr, sp.rgb, sp.a * dk_s);
					bld = max(bld, max(sp.a, street * 0.8));
				}
				// болото: камыш, ивы и сухие берёзы; в окнах воды — кувшинки
				if (ms > 0.05) {
					vec4 mm;
					if (pool_m > 0.5) {
						mm = spr_cell(qc + vec2(0.3, 0.5), vec2(1.1), 57.0, 0.4, 53, 1, 0.7, q_gx, q_gy);
					} else {
						vec4 sh2 = spr_cell(qc + vec2(2.4, 1.6), vec2(3.0), 53.0, 0.5 * ms, 51, 2, 0.8, q_gx, q_gy);
						mm = sh2.a > 0.3 ? sh2 : spr_cell(qc, vec2(1.2), 51.0, 0.6 * ms, 48, 2, 0.9, q_gx, q_gy);
					}
					terr = mix(terr, mm.rgb, mm.a * dk_s);
					bld = max(bld, mm.a * 0.7);
				}
			}
			ub_n = max(ub_n * (1.0 - dk_s), bld * dk_s);
			// дороги и жд (высокое качество): поверх леса и кварталов, цвет страны под ними
			// слабее; дороги в провинции города гаснут (там улицы), жд идёт до центра
			if (has_roads && quality == 2 && zoom > 1.3) {
				float d_rail = 9.0;
				float s_rail = 0.0;
				float d_road = 9.0;
				road_prov(id, qc, d_rail, s_rail, d_road);
				if (id2 != id) {
					road_prov(id2, qc, d_rail, s_rail, d_road);
				}
				if (min(d_rail, d_road) < 1.0) {
					float gl = length(vec2(length(q_gx), length(q_gy)));
					vec4 rp = road_paint(terr, d_rail, s_rail, d_road, zoom * 2.0 * res_k, qc, gl,
						smoothstep(1.3, 1.9, zoom), smoothstep(2.0, 2.8, zoom) * (1.0 - town_here));
					terr = rp.rgb;
					ub_n = max(ub_n, rp.a);
				}
			}
			if (terrain_mode) {
				lc = K(terr * 0.95 * rf);
			} else {
				LC far_c = base * (0.9 + 0.14 * (tl - 0.75));
				far_c = mix(far_c, mix(base, K(rock * 1.1), 0.35), mnt * 0.5);
				far_c = mix(far_c, mix(base, K(des_c), 0.3), des * 0.45);
				far_c = mix(far_c, mix(base, K(vec3(0.95)), 0.7), snow * 0.7);
				// издали: лес темнит цвет страны, болото — оливковый тон, город — серое пятно
				far_c = mix(far_c, far_c * 0.86, fo * 0.6);
				far_c = mix(far_c, mix(base, K(vec3(0.42, 0.44, 0.30)), 0.3), ms * 0.45);
				far_c = mix(far_c, mix(base, K(vec3(0.50, 0.47, 0.44)), 0.6), ub * 0.75);
				LC near_c = mix(K(terr * 0.92), base, 0.45 * (1.0 - 0.8 * snow) * (1.0 - 0.7 * max(mnt, alp)) * (1.0 - 0.65 * des)
					* (1.0 - 0.45 * fo - 0.3 * fo * dk_s) * (1.0 - 0.8 * ub_n) * (1.0 - 0.4 * ms)
					* (1.0 - 0.3 * fl * dk_c) * (1.0 - 0.25 * hill * dk_c) * (1.0 - 0.3 * mead * dk_c) * (1.0 - 0.5 * hedge_m));
				lc = mix(far_c, near_c, near_k) * rf;
			}
			lc *= 1.0 + tex_c * dk_c;
			if (quality == 2 && des > 0.01) {
				// гряды дюн вблизи (эрги): пологий наветренный склон светлее, крутой
				// подветренный — тень
				float dkd = smoothstep(1.0, 2.4, zoom);
				if (dkd > 0.0) {
					vec2 q = px / id_k;
					// три типа дюн, плавно сменяющих друг друга по крупному шуму (весами, без
					// поворота угла внутри dot(q, …) — тот давал замкнутые «кольца»):
					// поперечные гряды (барханные цепи), сейфы — длинные острые гряды вдоль
					// ветра, звёздчатые — бугры на пересечении двух волн; извилистость — сдвиг
					// координат плавным шумом; сила рисунка тоже меняется по местности
					float n1 = vnoise(q / 23.0);
					float n2 = vnoise(q / 23.0 + vec2(41.7, 9.3));
					float n3 = vnoise(q / 6.0 + vec2(3.7, 11.9));
					vec2 qq = q + vec2(n1 - 0.5, n2 - 0.5) * 7.0 + (n3 - 0.5) * 1.2;
					float tsel = vnoise(q / 110.0 + vec2(13.0, 77.0));
					float w_tr = 1.0 - smoothstep(0.35, 0.5, tsel);
					float w_st = smoothstep(0.62, 0.75, tsel);
					float w_sf = max(0.0, 1.0 - w_tr - w_st);
					float sh = 0.0;
					if (w_tr > 0.0) {
						// гребни рвутся на отдельные барханы
						// (сила вдоль гребня — шум, вытянутый поперёк ветра)
						// (переменный шаг в делителе фазы давал муар-«кольца»: фаза ∝ координате;
						// неровный шаг — сдвиг вдоль ветра плавным шумом)
						float wv = fract((dot(qq, vec2(0.80, 0.60)) + (vnoise(q / 9.0 + vec2(3.0, 60.0)) - 0.5) * 3.0) / 2.8);
						float d = wv < 0.72 ? smoothstep(0.0, 0.72, wv) : 1.0 - smoothstep(0.72, 1.0, wv);   // пологий наветренный, крутой подветренный
						vec2 qa = vec2(dot(qq, vec2(0.80, 0.60)) / 2.0, dot(qq, vec2(-0.60, 0.80)) / 7.0);
						float seg = 0.25 + 0.95 * smoothstep(0.3, 0.7, vnoise(qa + vec2(5.5, 1.5)));
						sh += (d - 0.55) * seg * w_tr;
					}
					if (w_sf > 0.0) {
						// сейф: гребень острый, склоны освещены по разные стороны
						float a = dot(qq + vec2(n2 - 0.5) * 5.0, vec2(-0.55, 0.83)) * 6.2831853 / 4.6;
						float c = pow(1.0 - abs(sin(a * 0.5)), 2.0);
						sh += ((c - 0.3) * 0.9 + sign(cos(a * 0.5)) * 0.18 * c) * w_sf;
					}
					if (w_st > 0.0) {
						vec2 qs = qq + vec2(vnoise(q / 9.0 + vec2(4.0, 2.0)), vnoise(q / 9.0 + vec2(8.0, 5.0))) * 4.0;
						float b1 = sin(dot(qs, vec2(0.97, 0.26)) * 6.2831853 / 3.6);
						float b2 = sin(dot(qs, vec2(-0.26, 0.97)) * 6.2831853 / 3.1);
						float b3 = sin(dot(qs, vec2(0.62, -0.78)) * 6.2831853 / 4.2);
						// неровные по величине и не по сетке: волны сдвинуты шумом, высота — шумом
						float st = (b1 + b2 + b3) / 3.0 * (0.4 + 1.2 * vnoise(q / 4.5 + vec2(1.7, 6.2)));
						sh += (smoothstep(0.05, 0.7, st) - 0.2) * 0.8 * w_st;
					}
					float amp = 0.12 + 0.18 * vnoise(q / 40.0 + vec2(9.0, 4.0));
					float rip = sin(dot(qq, vec2(-0.45, 0.89)) * 6.2831853 / 1.1) * smoothstep(1.8, 3.5, zoom);
					lc *= 1.0 + (sh * amp * 1.6 + rip * 0.035) * des * erg * dkd * (1.0 - snow);
					// реги вблизи — мелкий щебень
					float grit = vnoise(q * 1.7) - 0.5;
					lc *= 1.0 + grit * 0.06 * des * (1.0 - erg) * dkd;
				}
			}
			if (has_detail && quality == 2) {
				// вблизи — фактура местности: веса по цвету природной зоны и крутизне
				float dk = smoothstep(1.2, 3.0, zoom) * (1.0 - town_here);
				if (dk > 0.0) {
					mediump vec4 dt = texture(tile_tex, vec3(px / (DETAIL_TILE * id_k), 1.0));
					mediump float sat = max(terr.r, max(terr.g, terr.b)) - min(terr.r, min(terr.g, terr.b));
					mediump float w_snow = max(snow, smoothstep(0.80, 0.90, tl) * (1.0 - smoothstep(0.06, 0.14, sat)));
					mediump float w_rock = max(smoothstep(0.15, 0.45, slope), mnt) * (1.0 - w_snow);
					mediump float w_sand = smoothstep(0.0, 0.06, terr.r - terr.g) * (1.0 - w_snow - w_rock);
					mediump float w_grass = max(0.0, 1.0 - w_snow - w_rock - w_sand);
					mediump float d = dt.r * w_grass + dt.g * w_rock + dt.b * w_sand + dt.a * w_snow;
					lc *= 1.0 + (d - 0.5) * (0.22 + 0.14 * mnt) * dk;
				}
			}
		} else {
			lc = base * (0.70 + 0.48 * light);
		}
#ifdef BAKE_OUT
		bk_out = vec4(clamp(lc.rgb / BK_V, 0.0, 1.0), 1.0 - clamp(lc.a / BK_S, 0.0, 1.0));
#else
		col = lc;
#endif
#endif
#ifndef BAKE_OUT
		float river;
		if (has_rivers) {
			// Как в жанре: вдали — тонкая линия, вблизи — лента воды с берегами
			// (шире к приближению, в пикселях карты); река сама — граница
			// провинций: линию провинций под ней не рисуем (river_m)
			// ширина — в пикселях экрана и растёт медленно, широкая лента — только у
			// самого приближения (как в жанре: вдали 1–2 пикс., ближе узкая лента
			// ~6–8, у максимума ~25): полуширина 0,8·e^(0,68·(масштаб−1)) для крупной
			float nk = smoothstep(2.8, 4.6, zoom);
			float mp = zoom * 2.0 * res_k;   // пикселей буфера на пиксель карты
			// расстояния в поле приведённые (делённые на относительную ширину реки):
			// полуширина здесь — крупной, узкие выходят уже сами
			float hw_px = max(1.2 * exp(0.58 * (min(zoom, 5.0) - 1.0)), 1.3) * res_k * max(zoom / 5.0, 1.0);   // ближе ×5 — в масштабе карты
			float hw = clamp(hw_px / mp, 1.3 * rv_fw, RIVER_MAX - 0.8);
			float aa = 0.6 * rv_fw;
			// вблизи — со слиянием соседних русел: полоска суши уже ~3/4 ширины
			// ленты и острый клин у развилки заливаются плавной перемычкой
			// (рассчитано на полуширину крупного плана, поэтому — только у него)
			rv_d = min(rv_d, mix(rv_d, rv_ds, smoothstep(0.35, 0.7, hw)));
			float has = step(0.01, rv.g) * (rv.g > 0.5 ? 1.0 : smoothstep(0.4, 0.9, zoom));   // малые — тоньше, с масштаба ~0,5
			river = (1.0 - smoothstep(hw - aa, hw + aa, rv_d)) * has;
			// берег вблизи — неровной ширины (пляжи и отмели по шуму), вдали — узкая кромка
			mediump float bn = has_detail && nk > 0.0 ? textureGrad(tile_tex, vec3(px / (DETAIL_TILE * 2.3 * id_k) + vec2(0.21, 0.77), 1.0), q_gx / (DETAIL_TILE * 2.3), q_gy / (DETAIL_TILE * 2.3)).g : 0.5;
			float bw = (0.16 + 0.50 * smoothstep(0.40, 0.65, bn)) * nk + 0.35 * rv_fw * nk + 0.9 * rv_fw * (1.0 - nk);
			float bank = (1.0 - smoothstep(hw + bw - aa, hw + bw + aa, rv_d)) * has - river;
			river_m = river + max(bank, 0.0);   // лента вместе с берегами
			river_out = (hw + bw) * step(0.5, has);
			river_nk = nk;
			// вода вблизи: глубина — синяя, к берегу мель зеленовато-бурая; струи течения
			// вдоль русла, блики, тень берега с северо-запада, светлая кромка у уреза
			float mid = clamp(1.0 - rv_d / max(hw, 1e-3), 0.0, 1.0);   // 1 — ось, 0 — урез
			vec2 rq = rv4.rg * 255.0 - 128.0;
			vec2 sd = -rq / max(length(rq), 1e-3);   // от оси к точке
			vec2 fl = vec2(-sd.y, sd.x);             // вдоль русла (за осью знак меняется)
			float deep = smoothstep(0.05, 0.8, mid);
			vec3 rw = mix(vec3(0.34, 0.41, 0.36), vec3(0.15, 0.27, 0.35), deep);
			if (has_water && nk > 0.0) {
				// координаты вдоль/поперёк русла; выборки в (a, b) и (−a, −b) —
				// сумма не меняется при смене знака за осью, шва нет
				vec2 q = px / id_k;
				vec2 ka = vec2(0.10, 0.55);
				vec2 fc = vec2(dot(q, fl), dot(q, sd)) * ka;
				vec2 fgx = vec2(dot(q_gx, fl), dot(q_gx, sd)) * ka;
				vec2 fgy = vec2(dot(q_gy, fl), dot(q_gy, sd)) * ka;
				float s1 = textureGrad(tile_tex, vec3(fc, 0.0), fgx, fgy).r;
				float s2 = textureGrad(tile_tex, vec3(-fc + vec2(0.31, 0.57), 0.0), fgx, fgy).r;
				float streak = s1 + s2 - 1.0;   // −1…1
				vec2 wn = textureGrad(tile_tex, vec3(wv_uv * 3.0, 0.0), wv_gx * 3.0, wv_gy * 3.0).rg - 0.5;
				rw *= 1.0 + (streak * 0.45 * (0.35 + 0.65 * deep) + (wn.x - wn.y) * 0.18) * nk;
				rw += vec3(0.38, 0.42, 0.40) * smoothstep(0.18, 0.40, streak) * deep * 0.45 * nk;   // блики
				float shade = max(dot(sd, vec2(-0.707, -0.707)), 0.0) * (1.0 - smoothstep(0.0, 0.45, mid));
				rw *= 1.0 - 0.35 * shade * nk;   // тень берега
				rw = mix(rw, vec3(0.52, 0.56, 0.50), (1.0 - smoothstep(0.0, 0.12, mid)) * (1.0 - shade) * 0.45 * nk);   // урез
			}
			rw = mix(vec3(0.27, 0.43, 0.60), rw, nk);   // вдали — спокойная синяя линия
#ifdef BAKED
			mediump float light = bank > 0.0 && nk > 0.0 ? light_at(muv) : 0.0;
#endif
			// берег вблизи: у воды мокрый ил, дальше песок, к траве — тростник пятнами
			float bt = clamp((rv_d - hw) / max(bw, 1e-3), 0.0, 1.0);
			vec3 bc = mix(vec3(0.33, 0.29, 0.21), vec3(0.63, 0.57, 0.43), smoothstep(0.0, 0.45, bt));
			mediump float reed = smoothstep(0.55, 0.75, bn * 0.6 + (has_detail ? textureGrad(tile_tex, vec3(px / (DETAIL_TILE * 0.35 * id_k), 1.0), q_gx / (DETAIL_TILE * 0.35), q_gy / (DETAIL_TILE * 0.35)).r : 0.5) * 0.6 - 0.1) * smoothstep(0.3, 0.8, bt) * nk;
			bc = mix(bc, vec3(0.22, 0.28, 0.14), reed * 0.85);
			bc *= 0.85 + 0.25 * light;
			col = mix(col, mix(col * 0.62, bc, nk), bank * mix(0.18, mix(0.9, 0.35, smoothstep(0.6, 1.0, bt)), nk));   // вдали — едва заметная кромка
			col = mix(col, rw, river * smoothstep(0.3, 0.7, zoom));
			// мосты: улица города поперёк реки — каменный настил вдоль улицы, парапеты,
			// тень на воде к юго-востоку (вблизи, высокое качество)
			if (quality == 2 && has_sprites && river > 0.01 && zoom > 2.0) {
				vec3 buv;
				vec2 qb = px / id_k;
				float brg = town_bridge(qb, map_size / id_k, buv) * smoothstep(2.0, 3.0, zoom);
				vec3 buv2;
				float sh_b = town_bridge(qb - vec2(0.12, 0.12), map_size / id_k, buv2) * (1.0 - brg);
				col = mix(col, col * 0.55, sh_b * river * smoothstep(2.0, 3.0, zoom));
				if (brg > 0.0) {
					vec3 stone = vec3(0.6, 0.57, 0.52);
					if (has_road_tex) {
						vec2 bg = vec2(length(dFdx(qb)), length(dFdy(qb)));
						stone = textureGrad(tile_tex, vec3(buv.xy / 0.35, 10.0), vec2(bg.x, 0.0) / 0.35, vec2(0.0, bg.y) / 0.35).rgb * 0.85;
					}
					float side = 1.0 - buv.y / max(buv.z, 1e-3);
					stone *= 1.0 + 0.25 * smoothstep(0.75, 0.82, side) - 0.45 * smoothstep(0.9, 1.0, side);   // парапет
					col = mix(col, stone, brg * river);
				}
			}
			// мосты дорог и жд: полотно поверх воды, по краям — фермы/перила, тень на воду
			if (has_roads && quality == 2 && river > 0.01 && zoom > 1.3) {
				float d_rail = 9.0;
				float s_rail = 0.0;
				float d_road = 9.0;
				vec2 qr = px / id_k;
				road_prov(id, qr, d_rail, s_rail, d_road);
				if (id2 != id) {
					road_prov(id2, qr, d_rail, s_rail, d_road);
				}
				if (min(d_rail, d_road) < 1.2) {
					float mp = zoom * 2.0 * res_k;
					float fw = 1.0 / mp;
					float gl = length(vec2(length(q_gx), length(q_gy)));
					float rk = smoothstep(1.3, 1.9, zoom);
					float ok = smoothstep(2.0, 2.8, zoom);
					float near = smoothstep(5.0, 9.0, mp);
					// тень настила к юго-востоку
					float d_sh = min(d_rail + 9.0 * (1.0 - rk), d_road + 9.0 * (1.0 - ok));
					col = mix(col, col * 0.55, (1.0 - smoothstep(0.30, 0.42, d_sh - 0.06)) * near * river * 0.5);
					vec4 rp = road_paint(col, d_rail, s_rail, d_road, mp, qr, gl, rk, ok);
					col = mix(col, rp.rgb, river);
					// фермы жд-моста и перила дорожного — тёмные кромки
					float tr_r = (1.0 - smoothstep(0.03, 0.03 + fw, abs(d_rail - 0.27))) * rk;
					float tr_d = (1.0 - smoothstep(0.025, 0.025 + fw, abs(d_road - 0.16))) * ok;
					col = mix(col, vec3(0.22, 0.22, 0.24), max(tr_r, tr_d) * near * river);
				}
			}
			river = 0.0;
		} else {
			river = smoothstep(0.25, 0.8, textureLod(base_tex, vec3(muv, 0.0), 0.0).g);
		}
		col = mix(col, vec3(0.22, 0.42, 0.58), river * 0.75 * smoothstep(0.35, 0.9, zoom));
		// лёгкая «бумажная» зернистость
		if (quality == 0) {
			col *= 0.97 + 0.03 * fract(sin(dot(vec2(ip), vec2(12.9898, 78.233))) * 43758.5453);
		} else {
			// плавный шум (билинейно между узлами) — без квадратиков вблизи
			vec2 g = floor(px / id_k * 0.5);
			vec2 f = smoothstep(0.0, 1.0, fract(px / id_k * 0.5));
			float n00 = fract(sin(dot(g, vec2(12.9898, 78.233))) * 43758.5453);
			float n10 = fract(sin(dot(g + vec2(1.0, 0.0), vec2(12.9898, 78.233))) * 43758.5453);
			float n01 = fract(sin(dot(g + vec2(0.0, 1.0), vec2(12.9898, 78.233))) * 43758.5453);
			float n11 = fract(sin(dot(g + vec2(1.0, 1.0), vec2(12.9898, 78.233))) * 43758.5453);
			col *= 0.97 + 0.03 * mix(mix(n00, n10, f.x), mix(n01, n11, f.x), f.y);
		}
		if (has_band && !terrain_mode) {
			// кайма: цвет страны гуще у её границы и мягко сходит внутрь (как в жанре)
			mediump float bd = texture(band_tex, muv).r;
			col = mix(col, cc.rgb * 0.5, bd * bd * 0.62 * (1.0 - river_m));   // не поверх реки
		}
		if (highlight_nation >= 0 && ctrl != highlight_nation) {
			col = mix(col, vec3(dot(col, vec3(0.33))), 0.55) * 0.8;
		}
#endif
	}
#ifdef BAKE_OUT
	COLOR = bk_out;
#else

	// Границы — сглаженные линии постоянной толщины на экране. Каждый вид
	// границы считается по своей группировке весов соперников: берег — суша
	// против воды, граница стран — своя страна против лучшей чужой, граница
	// провинций — победитель против второго в своей стране. Так на стыке
	// двух провинций и моря берег не пропадает.
	float texel_px = zoom * 2.0 * res_k / id_k;                        // тексель сетки провинций на экране (масштаб спрайта 2)
	float map_px = texel_px * id_k;                                  // пиксель карты на экране: толщины линий — в нём
	// расстояние до границы провинций, пиксели экрана (с полем расстояний)
	float sdf_px = sdf_tx * texel_px;
	float w_land = 0.0;
	float w_water = 0.0;
	float w_mine = 0.0;      // страна победителя
	float w_other = 0.0;     // лучшая другая страна (суша)
	float w_prov2 = 0.0;     // лучшая другая провинция той же страны
	for (int j = 0; j < un; j++) {
		if (uid[j] < 0) {
			continue;
		}
		if (nat_c[j] >= 0) {
			w_land += uw[j];
		} else {
			w_water += uw[j];
		}
		if (nat_c[j] == ctrl) {
			w_mine += uw[j];
			if (j != top) {
				w_prov2 = max(w_prov2, uw[j]);
			}
		}
	}
	for (int j = 0; j < un; j++) {
		if (uid[j] >= 0 && nat_c[j] >= 0 && nat_c[j] != ctrl) {
			float s2 = 0.0;
			for (int k = 0; k < un; k++) {
				if (uid[k] >= 0 && nat_c[k] == nat_c[j]) {
					s2 += uw[k];
				}
			}
			w_other = max(w_other, s2);
		}
	}
	// области: веса своей области победителя и других областей той же страны
	float w_st_same = 0.0;
	float w_st_oth = 0.0;
	if (has_states) {
		vec4 sc0 = pal(2, uid[top]);
		int st_top = int(sc0.r * 255.0 + 0.5) + int(sc0.g * 255.0 + 0.5) * 256;
		for (int j = 0; j < un; j++) {
			if (uid[j] >= 0 && nat_c[j] == ctrl) {
				vec4 scj = pal(2, uid[j]);
				int stj = int(scj.r * 255.0 + 0.5) + int(scj.g * 255.0 + 0.5) * 256;
				if (stj == st_top) {
					w_st_same += uw[j];
				} else {
					w_st_oth += uw[j];
				}
			}
		}
	}
	// фронт: наш участок против целей — линия по границе между ними (как в жанре)
	float w_fo = 0.0;
	float w_ft = 0.0;
	int fo_j = -1;
	int role_top = 0;
	if (front_on) {
		for (int j = 0; j < un; j++) {
			if (uid[j] < 0) {
				continue;
			}
			int r = int(pal(3, uid[j]).a * 255.0 + 0.5);
			if ((r & 1) != 0) {
				w_fo += uw[j];
				if (fo_j < 0 || uw[j] > uw[fo_j]) {
					fo_j = j;
				}
			}
			if ((r & 2) != 0) {
				w_ft += uw[j];
			}
		}
		role_top = int(pal(3, id).a * 255.0 + 0.5);
	}
	// Производные (fwidth) — только здесь, вне ветвлений: внутри условий они на
	// части мобильных ГП (OpenGL ES) не определены и давали ложные штрихи
	// по пиксельной сетке у берегов.
	float d0 = abs(cov - 0.5) * 2.0;
	float fw0 = fwidth(d0);
	float s1 = w_mine + w_other;
	float d1 = s1 > 0.0 ? abs(w_mine - w_other) / s1 : 1.0;
	float fw1 = fwidth(d1);
	float s2 = uw[top] + w_prov2;
	float d2 = s2 > 0.0 ? (uw[top] - w_prov2) / s2 : 1.0;
	float fw2 = fwidth(d2);
	float s3 = w_fo + w_ft;
	float d3 = s3 > 0.0 ? abs(w_fo - w_ft) / s3 : 1.0;
	float fw3 = fwidth(d3);
	if (quality == 0) {
		// низкое качество: границы по соседним текселям (как раньше, дёшево)
		vec2 f = fract(px);
		ivec2 dirs[4] = ivec2[](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
		float dist[4] = float[](1.0 - f.x, f.x, 1.0 - f.y, f.y);
		for (int i = 0; i < 4; i++) {
			if (dist[i] > 0.4) {
				continue;
			}
			int nid = pid(ip + dirs[i]);
			if (nid == id) {
				continue;
			}
			int nc = nation(pal(0, nid));
			if ((nc >= 0) != land) {
				if (dist[i] < 0.3) col = mix(col, vec3(0.10, 0.13, 0.17), 0.8);
			} else if (land && nc != ctrl) {
				col = mix(col, vec3(0.07, 0.06, 0.06), smoothstep(0.0, 0.35, 1.0 - dist[i] / 0.4) * 0.9);
			} else if (land && dist[i] < 0.16) {
				col = mix(col, col * 0.62, smoothstep(0.45, 1.3, zoom));
			}
		}
	} else if (cov > 0.01 && cov < 0.99) {
		// береговая линия по векторной доле суши
		float dp = d0 / max(fw0, 0.5 / texel_px) * 0.5;
		float w = max(lw_min(0.75), min(0.2 * map_px, 0.3 * texel_px + 0.5));
		col = mix(col, vec3(0.10, 0.13, 0.17), (1.0 - smoothstep(w - 0.8, w + 0.8, dp)) * 0.8);
	}
	land = land && !sea_px;
	// Три уровня обводки (как в жанре): провинции — тонкая, области — средняя,
	// страны — толстая чёрная поверх. Вблизи каждая — по расстоянию до СВОЕЙ
	// границы (border_tx по своей группировке весов), вдали — поле расстояний
	float near_b = has_sdf ? smoothstep(1.3, 2.2, texel_px) : 1.0;
	if (land && !wide_land && w_prov2 > 0.0) {
		float dp = mix(sdf_px, border_tx(d2, win_bl) * texel_px, near_b);
		float w = max(lw_min(0.6), 0.14 * map_px);
		float a2 = smoothstep(0.45, 1.3, zoom) * (1.0 - smoothstep(0.15, 0.6, river_m));
		col = mix(col, col * 0.6, (1.0 - smoothstep(w - 0.7, w + 0.7, dp)) * a2);
	}
	// область — только выбранной провинции (решение пользователя): контур по
	// границе весов «область выбранной» против остальной суши в окне
	if (has_states && selected_id >= 0 && land && !wide_land) {
		vec4 ss = pal(2, selected_id);
		int sel_st = int(ss.r * 255.0 + 0.5) + int(ss.g * 255.0 + 0.5) * 256;
		float w_in = 0.0;
		float w_out = 0.0;
		for (int j = 0; j < un; j++) {
			if (uid[j] >= 0 && nat_c[j] >= 0) {
				vec4 scj = pal(2, uid[j]);
				int stj = int(scj.r * 255.0 + 0.5) + int(scj.g * 255.0 + 0.5) * 256;
				if (stj == sel_st) {
					w_in += uw[j];
				} else {
					w_out += uw[j];
				}
			}
		}
		if (w_in > 0.0 && w_out > 0.0) {
			float ds = abs(w_in - w_out) / (w_in + w_out);
			float dp = border_tx(ds, win_bl) * texel_px;
			float w = max(lw_min(1.0), min(0.22 * map_px, 0.9 * texel_px));
			col = mix(col, vec3(0.96, 0.92, 0.78), (1.0 - smoothstep(w - 0.8, w + 0.8, dp)) * 0.85);
		}
	}
	// граница стран (как в жанре): мягкая тёмная полоса своего цвета изнутри
	// (кайма band_tex, выше) и тонкая полупрозрачная линия по самой границе;
	// вблизи под лентой реки линии нет — полоса доходит до берега
	if (land && !wide_land && w_other > 0.0) {
		float dp = mix(sdf_px, border_tx(d1, win_bl) * texel_px, near_b);
		float w = max(lw_min(1.0), min(0.18 * map_px, mix(1.2, win_bl ? 0.4 : 0.9, near_b) * texel_px));
		col = mix(col, cc.rgb * 0.28, (1.0 - smoothstep(w - 0.8, w + 0.8, dp)) * 0.78 * (1.0 - smoothstep(0.15, 0.6, river_m) * river_nk));
	}

	if (front_on && land && role_top != 0) {
		mediump vec3 fc = pal(3, id).rgb;
		if ((role_top & 4) != 0) {
			// выделено кистью: заливка цветом армии
			col = mix(col, fc, 0.32);
		}
		if ((role_top & 8) != 0) {
			// цель атаки: косая штриховка цветом армии (шаг 11 пикселей экрана,
			// привязана к карте — одна и та же в кадре и в кэше движения)
			float st = step(0.62, fract((wp.x - wp.y) * zoom / 11.0));
			col = mix(col, fc * 0.9, st * 0.42);
		}
	}
	if (front_on && land && w_fo > 0.0 && w_ft > 0.0 && fo_j >= 0) {
		// линия фронта: тёмная кайма и цвет армии — толще границы стран
		mediump vec3 fc = pal(3, uid[fo_j]).rgb;
		float dp = d3 / max(fw3, 0.5 / texel_px) * 0.5;
		float w = min(max(lw_min(2.3 * res_k), 0.55 * map_px), 7.0 * res_k);
		col = mix(col, vec3(0.05, 0.04, 0.03), (1.0 - smoothstep(w + 0.4, w + 1.6, dp)) * 0.85);
		col = mix(col, fc, 1.0 - smoothstep(w - 0.8, w + 0.4, dp));
	}

	if (id == selected_id && land) {
		col = mix(col, vec3(1.0, 0.96, 0.8), 0.3);
	}
	// дымка вдали при наклоне камеры (как воздушная перспектива)
	col = mix(col, vec3(0.80, 0.84, 0.86), haze);
	COLOR = outside ? vec4(0.302, 0.302, 0.302, 1.0) : vec4(col, 1.0);
#endif
}
