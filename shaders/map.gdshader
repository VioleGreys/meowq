shader_type canvas_item;
// Карта провинций: id провинции закодирован в RG текстуры id_tex, цвет
// берётся из палитры (64 x N) — смена владельца = обновление одного пикселя
// палитры, без перерисовки всей карты.

uniform sampler2D id_tex : filter_nearest;
uniform sampler2D ctrl_tex : filter_nearest;   // rgb — цвет контролёра/режима, a — (нация+1)/255, 0 = море
uniform sampler2D owner_tex : filter_nearest;  // rgb — цвет владельца, a — (нация+1)/255
uniform sampler2D height_tex : filter_linear;  // r — высота (0.5 = уровень моря), g — реки
uniform vec2 map_size = vec2(800.0, 500.0);
uniform int selected_id = -1;
uniform int highlight_nation = -1;
uniform bool show_occupation = true;
uniform float zoom = 1.0;
uniform sampler2D terrain_tex : filter_linear;  // спутниковая подложка (NASA Blue Marble), только суша
uniform bool has_terrain = false;
uniform bool terrain_mode = false;              // режим «Местность»: подложка без цветов стран
// проекция Миллера для сетки широт и долгот (как tools/build_map.py)
uniform float lon_min = -169.0;
uniform float lat_top = 80.0;

int pid(ivec2 p) {
	p = clamp(p, ivec2(0), ivec2(map_size) - 1);
	vec4 c = texelFetch(id_tex, p, 0);
	return int(c.r * 255.0 + 0.5) + int(c.g * 255.0 + 0.5) * 256;
}

vec4 pal(sampler2D t, int id) {
	return texelFetch(t, ivec2(id % 64, id / 64), 0);
}

int nation(vec4 c) {
	return int(c.a * 255.0 + 0.5) - 1;
}

void fragment() {
	vec2 px = UV * map_size;
	ivec2 ip = ivec2(floor(px));
	// Сглаженные границы: берём 4 ближайших текселя карты и выбираем провинцию с
	// наибольшим весом билинейной интерполяции — граница идёт плавной кривой, а не
	// «лесенкой» пикселей. diff — запас победителя над вторым: 0 на самой границе.
	// окно 3×3 текселя с гауссовыми весами: ступеньки сглаживаются в наклонные линии
	int uid[9] = int[](-1, -1, -1, -1, -1, -1, -1, -1, -1);
	float uw[9] = float[](0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
	int un = 0;
	// при сильном отдалении (тексель меньше пикселя экрана) сглаживать нечего —
	// бережём видеокарту телефона
	// (окно 2×2 вокруг точки: границы остаются, выборок вдвое меньше)
	bool far = zoom * 2.0 < 1.2;
	ivec2 base_t = far ? ivec2(floor(px - 0.5)) : ip - ivec2(1);
	int span = far ? 1 : 2;
	for (int oy = 0; oy <= span; oy++) {
		for (int ox = 0; ox <= span; ox++) {
			ivec2 tp = base_t + ivec2(ox, oy);
			vec2 d = vec2(tp) + 0.5 - px;
			float w = exp(-dot(d, d) * 1.4);
			int cidv = pid(tp);
			int k = -1;
			for (int j = 0; j < 9; j++) {
				if (j < un && uid[j] == cidv) {
					k = j;
				}
			}
			if (k < 0) {
				k = un;
				uid[k] = cidv;
				un++;
			}
			uw[k] += w;
		}
	}
	int top = 0;
	for (int j = 1; j < 9; j++) {
		if (j < un && uw[j] > uw[top]) {
			top = j;
		}
	}
	int sec = -1;
	for (int j = 0; j < 9; j++) {
		if (j < un && j != top && (sec < 0 || uw[j] > uw[sec])) {
			sec = j;
		}
	}
	int id = uid[top];
	float diff = sec >= 0 ? (uw[top] - uw[sec]) / (uw[top] + uw[sec]) : 1.0;
	int id2 = sec >= 0 ? uid[sec] : id;
	vec4 cc = pal(ctrl_tex, id);
	vec4 oc = pal(owner_tex, id);
	int ctrl = nation(cc);
	bool land = ctrl >= 0;

	vec2 t = 1.0 / map_size;
	float h = texture(height_tex, UV).r;
	float hx = texture(height_tex, UV + vec2(t.x, 0.0)).r - texture(height_tex, UV - vec2(t.x, 0.0)).r;
	float hy = texture(height_tex, UV + vec2(0.0, t.y)).r - texture(height_tex, UV - vec2(0.0, t.y)).r;
	vec3 n = normalize(vec3(-hx * 7.0, -hy * 7.0, 1.0));
	float light = clamp(dot(n, normalize(vec3(-0.55, -0.65, 0.75))), 0.0, 1.0);

	vec3 col;
	// мелкие озёра входят в провинции суши, но по высоте ниже уровня моря — вода
	bool lake = land && texture(height_tex, (vec2(ip) + 0.5) / map_size).r < 0.49;
	if (!land || lake) {
		// вода: мелководье у берегов светлее, глубина темнее, лёгкая рябь
		float depth = clamp((0.5 - h) * 2.4, 0.0, 1.0);
		col = mix(vec3(0.22, 0.42, 0.50), vec3(0.07, 0.15, 0.25), pow(depth, 0.45));
		float wave = sin(TIME * 0.7 + px.x * 0.21 + sin(px.y * 0.13 + TIME * 0.3) * 2.0);
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
		vec3 base = cc.rgb;
		int own = nation(oc);
		if (show_occupation && own != ctrl) {
			float s = step(0.5, fract((px.x + px.y) * 0.28));
			base = mix(base, oc.rgb, s * 0.75);
		}
		if (has_terrain) {
			vec3 terr = texture(terrain_tex, UV).rgb;
			float tl = dot(terr, vec3(0.299, 0.587, 0.114));
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
		float river = texture(height_tex, UV).g;
		col = mix(col, vec3(0.22, 0.42, 0.58), smoothstep(0.25, 0.8, river) * 0.75 * smoothstep(0.35, 0.9, zoom));
		// лёгкая «бумажная» зернистость
		col *= 0.97 + 0.03 * fract(sin(dot(vec2(ip), vec2(12.9898, 78.233))) * 43758.5453);
		if (highlight_nation >= 0 && ctrl != highlight_nation) {
			col = mix(col, vec3(dot(col, vec3(0.33))), 0.55) * 0.8;
		}
	}

	// Границы — сглаженные линии постоянной толщины на экране (в пикселях экрана).
	float dpx = diff / max(fwidth(diff), 1e-4) * 0.5;   // расстояние до границы, пикс. экрана
	float texel_px = zoom * 2.0;                         // тексель карты на экране (масштаб спрайта 2)
	if (id2 != id) {
		int nc = nation(pal(ctrl_tex, id2));
		bool nland = nc >= 0;
		if (land != nland) {
			float w = max(0.9, 0.35 * texel_px);
			col = mix(col, vec3(0.10, 0.13, 0.17), (1.0 - smoothstep(w - 0.8, w + 0.8, dpx)) * 0.8);
		} else if (land && nc != ctrl) {
			float w = max(1.1, 0.45 * texel_px);
			col = mix(col, vec3(0.07, 0.06, 0.06), (1.0 - smoothstep(w - 0.9, w + 0.9, dpx)) * 0.9);
			// мягкий тон своей страны вдоль границы — как цветная кайма на картах
			col = mix(col, cc.rgb * 0.9, (1.0 - smoothstep(w, w + 3.0 + texel_px, dpx)) * 0.18);
		} else if (land) {
			float w = max(0.6, 0.14 * texel_px);
			float a2 = smoothstep(0.45, 1.3, zoom);
			col = mix(col, col * 0.6, (1.0 - smoothstep(w - 0.7, w + 0.7, dpx)) * a2);
		}
	}

	if (id == selected_id && land) {
		col = mix(col, vec3(1.0, 0.96, 0.8), 0.28 + 0.08 * sin(TIME * 5.0));
	}
	COLOR = vec4(col, 1.0);
}
