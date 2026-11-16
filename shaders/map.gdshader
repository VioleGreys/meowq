shader_type canvas_item;
// Карта провинций: id провинции закодирован в RG текстуры id_tex, цвет
// берётся из палитры (64 x N) — смена владельца = обновление одного пикселя
// палитры, без перерисовки всей карты.

uniform sampler2D id_tex : filter_nearest;
uniform sampler2D ctrl_tex : filter_nearest;   // rgb — цвет контролёра/режима, a — (нация+1)/255, 0 = море
uniform sampler2D owner_tex : filter_nearest;  // rgb — цвет владельца, a — (нация+1)/255
uniform sampler2D state_tex : filter_nearest;  // r + g·256 — область провинции + 1 (обводка областей)
uniform bool has_states = false;
uniform sampler2D height_tex : filter_linear;  // r — высота (0.5 = уровень моря), g — реки
uniform vec2 map_size = vec2(800.0, 500.0);   // сетка карты провинций (с ids2 — вдвое подробнее)
// карта провинций для отрисовки вдвое подробнее (tools/build_ids2x.py), половинами
// запад/восток: восточная — со сдвигом ids_off; id_k — во сколько раз сетка
// подробнее пикселя карты (узоры и толщины линий — в пикселях карты)
uniform sampler2D id_w : filter_nearest;
uniform sampler2D id_e : filter_nearest;
uniform bool has_ids2 = false;
uniform int ids_half = 5632;
uniform int ids_off = 5600;
uniform float id_k = 1.0;
// поле расстояний до границ провинций (tools/build_sdf.py): L8, сетка 2×,
// половинами как ids2; 0…1 → 0…2 текселя сетки. Линии стран и провинций —
// по нему (билинейно — гладкие на любом приближении)
uniform sampler2D sdf_w : filter_linear_mipmap;
uniform sampler2D sdf_e : filter_linear_mipmap;
uniform bool has_sdf = false;
// кайма границ стран (MapView._update_band): 1 у границы, 0 — внутри (L8, четверть карты)
uniform sampler2D band_tex : filter_linear;
uniform bool has_band = false;
// нормали волн (tools/build_water.py, свои): бесшовный тайл, блики и рябь вблизи
uniform sampler2D water_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_water = false;
// поле рек (tools/build_rivers.py): rg — вектор до ближайшей точки реки
// (пикселей карты, ±RIVER_MAX), b — сила реки. Билинейный вектор → точное
// расстояние и между текселями: река гладкая на любом приближении
uniform sampler2D river_tex : filter_linear_mipmap;
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
uniform vec2 world_size = vec2(11264.0, 5250.0);
const float RELIEF_H = 6.0;   // высота самых высоких гор при наклоне, единиц мира
uniform float res_k = 1.0;   // пикселей буфера карты на логический пиксель экрана
uniform sampler2D terrain_tex : filter_linear;  // спутниковая подложка (NASA Blue Marble), только суша
uniform bool has_terrain = false;
uniform bool terrain_mode = false;              // режим «Местность»: подложка без цветов стран
// графика карты в полном разрешении (tools/build_map_art.py): цвет природных
// зон (Natural Earth NE1_HR_LC) и нормали рельефа суши и дна (ETOPO1)
// вдвое подробнее карты, половинами запад/восток с перекрытием (шире 8192
// текстуры есть не на всех телефонах); art_geom — ширина подложки, сдвиг
// восточной половины, ширина половины, высота
uniform sampler2D color_w : filter_linear_mipmap;
uniform sampler2D color_e : filter_linear_mipmap;
uniform sampler2D normal_w : hint_normal, filter_linear_mipmap;
uniform sampler2D normal_e : hint_normal, filter_linear_mipmap;
uniform vec4 art_geom = vec4(11264.0, 5600.0, 5664.0, 5250.0);
uniform bool has_art = false;
// детальные текстуры местности вблизи (ambientCG, tools/build_detail.py):
// r — трава, g — скалы, b — песок, a — снег; среднее 0.5
uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_detail = false;
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
uniform sampler2D front_tex : filter_nearest;
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
	if (has_ids2) {
		c = p.x < ids_half ? texelFetch(id_w, p, 0) : texelFetch(id_e, p - ivec2(ids_off, 0), 0);
	} else {
		c = texelFetch(id_tex, p, 0);
	}
	return int(c.r * 255.0 + 0.5) + int(c.g * 255.0 + 0.5) * 256;
}

vec4 pal(sampler2D t, int id) {
	return texelFetch(t, ivec2(id % 64, id / 64), 0);
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

int nation(vec4 c) {
	return int(c.a * 255.0 + 0.5) - 1;
}

// бикубическая (B-сплайн) выборка 4 билинейными: вблизи — без ромбиков сетки
// (с явными производными: выборка — в ветвлении по половине подложки)
vec4 tex_bicubic(sampler2D t, vec2 uv, vec2 ts, vec2 gx, vec2 gy) {
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
	return g0.y * (g0.x * textureGrad(t, vec2(p0.x, p0.y), gx, gy) + g1.x * textureGrad(t, vec2(p1.x, p0.y), gx, gy))
		+ g1.y * (g0.x * textureGrad(t, vec2(p0.x, p1.y), gx, gy) + g1.x * textureGrad(t, vec2(p1.x, p1.y), gx, gy));
}

void fragment() {
	// луч из пикселя экрана до плоскости карты (см. cam_*)
	vec2 sc = UV * scr_size - scr_size * 0.5;
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
		float hh = max(texture(height_tex, wp / world_size).r - 0.5, 0.0) * 2.0;
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
	vec4 rv4 = has_rivers ? texture(river_tex, muv) : vec4(1.0, 1.0, 0.0, 1.0);
	vec3 rv3 = rv4.rgb;
	vec2 rv = vec2(0.0, rv3.b);
	// длина билинейного вектора — точна у одной реки; между двумя реками векторы
	// гасятся — тогда берём билинейное расстояние (a) за вычетом его недобора у
	// осевой линии (≤ ~0,7 текселя)
	float rv_d = max(length((rv3.rg * 255.0 - 128.0) / 127.0) * RIVER_MAX, rv4.a * RIVER_MAX - 0.75);
	float rv_fw = max(fwidth(rv_d), 1e-4);
	float river_m = 0.0;   // доля ленты реки в пикселе (под ней линию провинций не рисуем)
	float river_out = 0.0;   // край ленты с берегами от осевой линии, пикс. карты (0 — реки нет)
	float river_nk = 0.0;    // вблизи — лента (0…1)
	vec2 rv_v = (rv3.rg * 255.0 - 128.0) / 127.0 * RIVER_MAX;   // к ближайшей точке реки, пикс. карты
	// поле расстояний до границ провинций (текселей сетки; без поля — далеко)
	float sdf_tx = 1e4;
	if (has_sdf) {
		bool s_east = px.x >= float(ids_half);
		vec2 suv = vec2((s_east ? px.x - float(ids_off) : px.x) / sdf_wd, muv.y);
		vec2 sgx = vec2(dFdx(px.x) / sdf_wd, dFdx(muv.y));
		vec2 sgy = vec2(dFdy(px.x) / sdf_wd, dFdy(muv.y));
		float sd = s_east ? textureGrad(sdf_e, suv, sgx, sgy).r : textureGrad(sdf_w, suv, sgx, sgy).r;
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
	if (quality == 0) {
		// низкое качество: провинция ближайшего текселя, без сглаживания (1 выборка)
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
	int un = 0;
	for (int oy = o0; oy < o1; oy++) {
		for (int ox = o0; ox < o1; ox++) {
			int cidv = pid(i0 + ivec2(ox - 1, oy - 1));
			float w = wx[ox] * wy[oy];
			int k = -1;
			for (int j = 0; j < NS; j++) {
				if (j < un && uid[j] == cidv) {
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
	for (int j = 1; j < NS; j++) {
		if (uw[j] > uw[top]) {
			top = j;
		}
	}
	int sec = -1;
	for (int j = 0; j < NS; j++) {
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
	float cov = quality > 0 ? texture(height_tex, muv).b : 0.5;
	int nat_c[NS];
	for (int j = 0; j < NS; j++) {
		nat_c[j] = uid[j] >= 0 ? nation(pal(ctrl_tex, uid[j])) : -2;
	}
	bool wide_land = false;   // суша найдена вне окна — границ стран/провинций тут не рисуем
	bool cov_land = quality > 0 ? cov >= 0.5 : nation(pal(ctrl_tex, uid[top])) >= 0;
	if (cov_land && nat_c[top] < 0) {
		int bl = -1;
		for (int j = 0; j < NS; j++) {
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
					if (nation(pal(ctrl_tex, cid)) < 0) {
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
	vec4 cc = pal(ctrl_tex, id);
	vec4 oc = pal(owner_tex, id);
	int ctrl = nation(cc);
	bool land = ctrl >= 0;
	bool sea_px = !cov_land && land;   // суша по провинции, но по контуру — уже вода

	vec2 t = 1.0 / map_size;
	float h = texture(height_tex, muv).r;
	float h_r = texture(height_tex, muv + vec2(t.x, 0.0)).r;
	float h_l = texture(height_tex, muv - vec2(t.x, 0.0)).r;
	float h_d = texture(height_tex, muv + vec2(0.0, t.y)).r;
	float h_u = texture(height_tex, muv - vec2(0.0, t.y)).r;
	if (quality > 0) {
		// у берега растровая высота резко падает к морю — светотень рисовала бы
		// ступенчатый силуэт пикселей; берег уже дан векторным контуром
		h_r = max(h_r, 0.5); h_l = max(h_l, 0.5); h_d = max(h_d, 0.5); h_u = max(h_u, 0.5);
	}
	float hx = h_r - h_l;
	float hy = h_d - h_u;
	mediump vec3 n = normalize(vec3(-hx * 7.0, -hy * 7.0, 1.0));
	mediump float light = clamp(dot(n, normalize(vec3(-0.55, -0.65, 0.75))), 0.0, 1.0);

	// свет по нормалям рельефа (has_art): ближе — рельеф сильнее (как на картах
	// жанра: горы объёмны вблизи); вблизи на высоком качестве — бикубически
	float near_k = smoothstep(0.35, 1.6, zoom);
	mediump float rf = 1.0;
	mediump float slope = 0.0;
	// половина подложки и производные координат (до ветвлений по пикселю)
	float ax = muv.x * art_geom.x;
	bool a_east = ax >= art_geom.x * 0.5;
	vec2 auv = vec2((a_east ? ax - art_geom.y : ax) / art_geom.z, muv.y);
	vec2 agx = vec2(dFdx(muv.x) * art_geom.x / art_geom.z, dFdx(muv.y));
	vec2 agy = vec2(dFdy(muv.x) * art_geom.x / art_geom.z, dFdy(muv.y));
	vec2 ats = art_geom.zw;
	if (has_art) {
		vec2 g;
		if (quality == 2 && zoom > 0.9) {
			g = a_east ? tex_bicubic(normal_e, auv, ats, agx, agy).rg : tex_bicubic(normal_w, auv, ats, agx, agy).rg;
		} else {
			g = a_east ? textureGrad(normal_e, auv, agx, agy).rg : textureGrad(normal_w, auv, agx, agy).rg;
		}
		vec2 nxy = g * 2.0 - 1.0;
		slope = length(nxy);
		vec3 nn = normalize(vec3(nxy * mix(0.7, 1.3, near_k), sqrt(max(0.0, 1.0 - dot(nxy, nxy)))));
		vec3 ld = normalize(vec3(-0.55, -0.65, 0.75));
		rf = clamp(mix(1.0, dot(nn, ld) / ld.z, mix(0.55, 0.8, near_k)), 0.42, 1.35);
	}
	mediump vec3 col;   // цвет — в половинной точности (дешевле на мобильных ГП)
	// мелкие озёра входят в провинции суши, но по высоте ниже уровня моря — вода
	// (только на низком качестве: на среднем и высоком озёра — в векторном контуре)
	bool lake = quality == 0 && land && texture(height_tex, (vec2(ip) + 0.5) / map_size).r < 0.49;
	if (!land || lake || sea_px) {
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
				vec2 w1 = textureGrad(water_tex, wv_uv, wv_gx, wv_gy).rg * 2.0 - 1.0;
				vec2 w2 = textureGrad(water_tex, wv_uv * 2.7 + vec2(0.37, 0.61), wv_gx * 2.7, wv_gy * 2.7).rg * 2.0 - 1.0;
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
		float y_top = 1.25 * log(tan(0.78539816 + 0.4 * radians(lat_top)));
		float yy = y_top - px.y / s_px;
		float lat = degrees(2.5 * atan(exp(0.8 * yy)) - 1.9634954);
		float gl = abs(fract(lon / 15.0 + 0.5) - 0.5) * 15.0;
		float ga = abs(fract(lat / 15.0 + 0.5) - 0.5) * 15.0;
		float pxdeg = 360.0 / map_size.x;   // градусов долготы в пикселе карты
		float line = max(1.0 - smoothstep(0.0, pxdeg * 1.2, gl), 1.0 - smoothstep(0.0, pxdeg * 1.2, ga));
		col = mix(col, vec3(0.55, 0.68, 0.74), line * 0.18 * smoothstep(0.15, 0.5, zoom));
	} else {
		mediump vec3 base = cc.rgb;
		int own = nation(oc);
		if (show_occupation && own != ctrl) {
			float s = step(0.5, fract((px.x + px.y) / id_k * 0.28));
			base = mix(base, oc.rgb, s * 0.75);
		}
		if (has_art) {
			// как на картах жанра: издали — «бумажная» политическая карта (цвет
			// страны, рельеф едва заметен), вблизи — природные зоны (Natural Earth)
			// сквозь полупрозрачный цвет страны и объёмный свет рельефа (ETOPO1)
			mediump vec3 terr = a_east ? textureGrad(color_e, auv, agx, agy).rgb : textureGrad(color_w, auv, agx, agy).rgb;
			mediump float tl = dot(terr, vec3(0.299, 0.587, 0.114));
			terr = clamp(vec3(tl) + (terr - vec3(tl)) * 1.35, 0.0, 1.0) * 0.96;
			if (terrain_mode) {
				col = terr * 0.95 * rf;
			} else {
				mediump vec3 far_c = base * (0.9 + 0.14 * (tl - 0.75));
				mediump vec3 near_c = mix(terr * 0.92, base, 0.45);
				col = mix(far_c, near_c, near_k) * rf;
			}
			if (has_detail && quality == 2) {
				// вблизи — фактура местности: веса по цвету природной зоны и крутизне
				float dk = smoothstep(1.2, 3.0, zoom);
				if (dk > 0.0) {
					mediump vec4 dt = texture(detail_tex, px / (DETAIL_TILE * id_k));
					mediump float sat = max(terr.r, max(terr.g, terr.b)) - min(terr.r, min(terr.g, terr.b));
					mediump float w_snow = smoothstep(0.80, 0.90, tl) * (1.0 - smoothstep(0.06, 0.14, sat));
					mediump float w_rock = smoothstep(0.15, 0.45, slope) * (1.0 - w_snow);
					mediump float w_sand = smoothstep(0.0, 0.06, terr.r - terr.g) * (1.0 - w_snow - w_rock);
					mediump float w_grass = max(0.0, 1.0 - w_snow - w_rock - w_sand);
					mediump float d = dt.r * w_grass + dt.g * w_rock + dt.b * w_sand + dt.a * w_snow;
					col *= 1.0 + (d - 0.5) * 0.22 * dk;
				}
			}
		} else if (has_terrain) {
			mediump vec3 terr = texture(terrain_tex, muv).rgb;
			mediump float tl = dot(terr, vec3(0.299, 0.587, 0.114));
			if (terrain_mode) {
				col = terr * (0.85 + 0.35 * light);
			} else {
				// цвет страны поверх рельефа: яркость и фактура — от снимка, оттенок — от
				// страны; вблизи местность проступает сильнее (как на картах жанра)
				float k = smoothstep(0.6, 2.5, zoom);
				col = base * (0.55 + 0.85 * tl);
				col = mix(col, terr * (0.55 + 0.6 * base), 0.18 + 0.27 * k);
				col *= 0.82 + 0.32 * light;
			}
		} else {
			col = base * (0.70 + 0.48 * light);
		}
		float river;
		if (has_rivers) {
			// Как в жанре: вдали — тонкая линия, вблизи — лента воды с берегами
			// (шире к приближению, в пикселях карты); река сама — граница
			// провинций: линию провинций под ней не рисуем (river_m)
			float base = rv.g > 0.9 ? 0.42 : (rv.g > 0.5 ? 0.32 : 0.24);
			float nk = smoothstep(1.4, 4.0, zoom);
			float hw = max(base * mix(1.0, 3.2, nk), 0.8 * rv_fw);
			float aa = 0.6 * rv_fw;
			float has = step(0.01, rv.g) * (rv.g > 0.5 ? 1.0 : smoothstep(0.7, 1.4, zoom));   // малые — только вблизи
			river = (1.0 - smoothstep(hw - aa, hw + aa, rv_d)) * has;
			float bw = (0.08 * base / 0.42 + 0.03) * nk + 0.35 * rv_fw * nk;          // берег: узкая мягкая кромка (как в жанре)
			float bank = (1.0 - smoothstep(hw + bw - aa, hw + bw + aa, rv_d)) * has - river;
			river_m = river + max(bank, 0.0);   // лента вместе с берегами
			river_out = (hw + bw) * step(0.5, has);
			river_nk = nk;
			// вода: темнее у берега, светлее к середине; рябь — нормали волн
			float mid = clamp(1.0 - rv_d / max(hw, 1e-3), 0.0, 1.0);
			vec3 rw = mix(vec3(0.20, 0.30, 0.38), vec3(0.42, 0.52, 0.60), mid * mid * nk);
			if (has_water && nk > 0.0) {
				vec2 wn = textureGrad(water_tex, wv_uv * 3.0, wv_gx * 3.0, wv_gy * 3.0).rg - 0.5;
				rw *= 1.0 + (wn.x - wn.y) * 0.35 * nk;
			}
			rw = mix(vec3(0.50, 0.58, 0.64), rw, nk);   // вдали — бледная серо-голубая линия, как в жанре
			col = mix(col, vec3(0.56, 0.49, 0.36) * (0.85 + 0.25 * light), bank * 0.5 * nk);
			col = mix(col, rw, river * mix(0.75, 1.0, nk) * smoothstep(0.35, 0.9, zoom));
			river = 0.0;
		} else {
			river = smoothstep(0.25, 0.8, texture(height_tex, muv).g);
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
	}

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
	for (int j = 0; j < NS; j++) {
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
	for (int j = 0; j < NS; j++) {
		if (uid[j] >= 0 && nat_c[j] >= 0 && nat_c[j] != ctrl) {
			float s2 = 0.0;
			for (int k = 0; k < NS; k++) {
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
		vec4 sc0 = pal(state_tex, uid[top]);
		int st_top = int(sc0.r * 255.0 + 0.5) + int(sc0.g * 255.0 + 0.5) * 256;
		for (int j = 0; j < NS; j++) {
			if (uid[j] >= 0 && nat_c[j] == ctrl) {
				vec4 scj = pal(state_tex, uid[j]);
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
		for (int j = 0; j < NS; j++) {
			if (uid[j] < 0) {
				continue;
			}
			int r = int(pal(front_tex, uid[j]).a * 255.0 + 0.5);
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
		role_top = int(pal(front_tex, id).a * 255.0 + 0.5);
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
			int nc = nation(pal(ctrl_tex, nid));
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
		vec4 ss = pal(state_tex, selected_id);
		int sel_st = int(ss.r * 255.0 + 0.5) + int(ss.g * 255.0 + 0.5) * 256;
		float w_in = 0.0;
		float w_out = 0.0;
		for (int j = 0; j < NS; j++) {
			if (uid[j] >= 0 && nat_c[j] >= 0) {
				vec4 scj = pal(state_tex, uid[j]);
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
		mediump vec3 fc = pal(front_tex, id).rgb;
		if ((role_top & 4) != 0) {
			// выделено кистью: заливка цветом армии
			col = mix(col, fc, 0.32);
		}
		if ((role_top & 8) != 0) {
			// цель атаки: косая штриховка цветом армии (постоянного шага на экране)
			float st = step(0.62, fract((FRAGCOORD.x - FRAGCOORD.y) / (11.0 * res_k)));
			col = mix(col, fc * 0.9, st * 0.42);
		}
	}
	if (front_on && land && w_fo > 0.0 && w_ft > 0.0 && fo_j >= 0) {
		// линия фронта: тёмная кайма и цвет армии — толще границы стран
		mediump vec3 fc = pal(front_tex, uid[fo_j]).rgb;
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
}
