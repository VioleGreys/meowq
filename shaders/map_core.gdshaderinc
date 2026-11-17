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
				if (rl[i] > 0.15 && rl[j] > 0.15) {
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
			mediump float fo = smoothstep(0.30, 0.62, cv.r + edge_n * 0.25) * (1.0 - 0.5 * mnt) * (1.0 - des) * (1.0 - snow);
			mediump float ms = smoothstep(0.10, 0.42, cv.g + edge_n * 0.15) * free_k;
			mediump float ub = smoothstep(0.02, 0.45, cv.b) * (1.0 - snow);
			// рисовые чеки — муссонная Азия (Индия, Индокитай, Китай южнее Хуанхэ, Япония)
			float lon_c = degrees(px.x / (map_size.x / 6.2831853)) + lon_min;
			mediump float rc = smoothstep(68.0, 74.0, lon_c) * (1.0 - smoothstep(142.0, 146.0, lon_c))
				* (1.0 - smoothstep(34.0, 38.0, lat_at(px))) * smoothstep(-9.0, -5.0, lat_at(px)) * (1.0 - stp) * free_k * (1.0 - ub);
			fo *= 1.0 - ms * 0.6;
			// пашня: ровные обжитые места умеренного пояса (1936 г.: распахано почти
			// всё, что не лес, не болото, не степь и не пустыня)
			mediump float fl = (1.0 - smoothstep(0.3, 0.6, cv.a)) * free_k * (1.0 - fo) * (1.0 - ms) * (1.0 - ub)
				* (1.0 - stp * 0.6) * (1.0 - smoothstep(58.0, 64.0, lat_c));
			rc *= fl;
			fl *= 1.0 - rc;
			float dk_c = (quality == 2) ? smoothstep(1.6, 3.0, zoom) : 0.0;   // рисунок вблизи
			mediump float tex_c = 0.0;   // светотень рисунка (−…+)
			// холмы: оливково-бурый тон, вблизи — округлые бугры (свет с северо-запада)
			if (hill > 0.0) {
				terr = mix(terr, terr * vec3(1.02, 0.98, 0.86) + vec3(0.03, 0.02, 0.0), hill * 0.5 * free_k);
				if (dk_c > 0.0) {
					vec2 hq = qc * 1.3;
					float e = 0.35;
					float h0 = vnoise(hq) * 0.65 + vnoise(hq * 2.3 + vec2(5.0, 1.0)) * 0.35;
					float h1 = vnoise(hq + vec2(-e, -e)) * 0.65 + vnoise((hq + vec2(-e, -e)) * 2.3 + vec2(5.0, 1.0)) * 0.35;
					tex_c += (h1 - h0) * 1.1 * hill * free_k * (1.0 - fo * 0.5);
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
				float fsz = mix(0.6, 1.25, h21(rid + vec2(9.0, 1.0)));
				vec2 g = rq / (vec2(mix(1.0, 2.2, h21(rid + vec2(2.0, 7.0))), 1.0) * fsz * 0.75);
				g.x += h21(vec2(floor(g.y), rid.x * 7.0 + rid.y)) * 1.7;   // ряды со сдвигом — не сетка
				vec2 cid = floor(g);
				vec2 fq = fract(g);
				float hc = h21(cid);
				mediump vec3 fcol = hc < 0.3 ? vec3(0.76, 0.69, 0.45)
					: hc < 0.55 ? vec3(0.53, 0.60, 0.35)
					: hc < 0.75 ? vec3(0.61, 0.65, 0.42)
					: hc < 0.9 ? vec3(0.58, 0.50, 0.37) : vec3(0.69, 0.65, 0.48);
				fcol *= 0.94 + 0.12 * h21(cid + vec2(3.0, 3.0));
				float wnt = (lat_at(px) >= 0.0 ? winter : 1.0 - winter) * smoothstep(30.0, 45.0, lat_c);
				fcol = mix(fcol, vec3(0.56, 0.50, 0.38) + (hc - 0.5) * 0.08, wnt * 0.7);   // зимой — пашня и стерня
				float hedge = 1.0 - min(min(fq.x, 1.0 - fq.x) * 0.95, min(fq.y, 1.0 - fq.y) * 0.7) / 0.06;
				terr = mix(terr, mix(terr, fcol, 0.42), fl * dk_c);
				// борозды вдоль поля (у половины полей), межи — тонкие и не у всех полей
				float furrow = step(0.5, h21(cid + vec2(8.0, 2.0))) * (sin(fq.y * 6.2831853 * (4.0 + 3.0 * hc)) * 0.5 + 0.5);
				tex_c += (furrow - 0.5) * 0.05 * fl * smoothstep(3.0, 4.5, zoom);
				tex_c -= clamp(hedge, 0.0, 1.0) * 0.07 * step(0.35, h21(cid + vec2(1.0, 6.0))) * fl * smoothstep(2.2, 3.4, zoom);
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
				ub_n = ub * mix(1.0, max(built, 0.35), dk_c);
				terr = mix(terr, mix(uc_far, uc_near, dk_c), ub_n);
				tex_c += (built * (1.0 - street) - 0.5) * 0.1 * ub_n * dk_c;
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
					* (1.0 - 0.45 * fo) * (1.0 - 0.6 * ub_n) * (1.0 - 0.4 * ms));
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
				float dk = smoothstep(1.2, 3.0, zoom);
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
			float hw_px = max(1.2 * exp(0.58 * (zoom - 1.0)), 1.3) * res_k;
			float hw = clamp(hw_px / mp, 1.3 * rv_fw, RIVER_MAX - 0.8);
			float aa = 0.6 * rv_fw;
			// вблизи — со слиянием соседних русел: полоска суши уже ~3/4 ширины
			// ленты и острый клин у развилки заливаются плавной перемычкой
			// (рассчитано на полуширину крупного плана, поэтому — только у него)
			rv_d = min(rv_d, mix(rv_d, rv_ds, smoothstep(0.35, 0.7, hw)));
			float has = step(0.01, rv.g) * (rv.g > 0.5 ? 1.0 : smoothstep(0.4, 0.9, zoom));   // малые — тоньше, с масштаба ~0,5
			river = (1.0 - smoothstep(hw - aa, hw + aa, rv_d)) * has;
			float bw = 0.11 * nk + 0.35 * rv_fw * nk + 0.9 * rv_fw * (1.0 - nk);          // берег: узкая мягкая кромка (как в жанре)
			float bank = (1.0 - smoothstep(hw + bw - aa, hw + bw + aa, rv_d)) * has - river;
			river_m = river + max(bank, 0.0);   // лента вместе с берегами
			river_out = (hw + bw) * step(0.5, has);
			river_nk = nk;
			// вода: темнее у берега, светлее к середине; рябь — нормали волн
			float mid = clamp(1.0 - rv_d / max(hw, 1e-3), 0.0, 1.0);
			vec3 rw = mix(vec3(0.20, 0.30, 0.38), vec3(0.42, 0.52, 0.60), mid * mid * nk);
			if (has_water && nk > 0.0) {
				vec2 wn = textureGrad(tile_tex, vec3(wv_uv * 3.0, 0.0), wv_gx * 3.0, wv_gy * 3.0).rg - 0.5;
				rw *= 1.0 + (wn.x - wn.y) * 0.35 * nk;
			}
			rw = mix(vec3(0.27, 0.43, 0.60), rw, nk);   // вдали — спокойная синяя линия
#ifdef BAKED
			mediump float light = bank > 0.0 && nk > 0.0 ? light_at(muv) : 0.0;
#endif
			col = mix(col, mix(col * 0.62, vec3(0.56, 0.49, 0.36) * (0.85 + 0.25 * light), nk), bank * mix(0.18, 0.5, nk));   // вдали — едва заметная кромка, вблизи — берег
			col = mix(col, rw, river * smoothstep(0.3, 0.7, zoom));
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
