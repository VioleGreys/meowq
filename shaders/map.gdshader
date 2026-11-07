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
	vec2 f = fract(px);
	int id = pid(ip);
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
	if (!land) {
		float depth = clamp((0.5 - h) * 2.4, 0.0, 1.0);
		col = mix(vec3(0.26, 0.43, 0.52), vec3(0.09, 0.18, 0.29), sqrt(depth));
		float wave = sin(TIME * 0.7 + px.x * 0.21 + sin(px.y * 0.13 + TIME * 0.3) * 2.0);
		col += vec3(0.018) * wave * (1.0 - depth * 0.5);
	} else {
		vec3 base = cc.rgb;
		int own = nation(oc);
		if (show_occupation && own != ctrl) {
			float s = step(0.5, fract((px.x + px.y) * 0.28));
			base = mix(base, oc.rgb, s * 0.75);
		}
		col = base * (0.70 + 0.48 * light);
		float river = texture(height_tex, UV).g;
		col = mix(col, vec3(0.22, 0.42, 0.58), smoothstep(0.25, 0.8, river) * 0.75 * smoothstep(0.35, 0.9, zoom));
		// лёгкая «бумажная» зернистость
		col *= 0.97 + 0.03 * fract(sin(dot(vec2(ip), vec2(12.9898, 78.233))) * 43758.5453);
		if (highlight_nation >= 0 && ctrl != highlight_nation) {
			col = mix(col, vec3(dot(col, vec3(0.33))), 0.55) * 0.8;
		}
	}

	// Границы: проверяем соседний тексель, только если мы у его края.
	float prov_w = 0.16;
	float nat_w = 0.40;
	float prov_alpha = smoothstep(0.45, 1.3, zoom);
	float border = 0.0;
	float coast = 0.0;
	float provb = 0.0;
	ivec2 dirs[4] = ivec2[](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
	float dist[4] = float[](1.0 - f.x, f.x, 1.0 - f.y, f.y);
	for (int i = 0; i < 4; i++) {
		if (dist[i] > nat_w) {
			continue;
		}
		int nid = pid(ip + dirs[i]);
		if (nid == id) {
			continue;
		}
		int nc = nation(pal(ctrl_tex, nid));
		bool nland = nc >= 0;
		if (land != nland) {
			if (dist[i] < 0.30) coast = 1.0;
		} else if (land && nc != ctrl) {
			border = max(border, 1.0 - dist[i] / nat_w);
		} else if (land && dist[i] < prov_w) {
			provb = 1.0;
		}
	}
	col = mix(col, col * 0.62, provb * prov_alpha);
	col = mix(col, vec3(0.08, 0.07, 0.07), smoothstep(0.0, 0.35, border) * 0.9);
	col = mix(col, vec3(0.12, 0.16, 0.2), coast * 0.8);

	if (id == selected_id && land) {
		col = mix(col, vec3(1.0, 0.96, 0.8), 0.28 + 0.08 * sin(TIME * 5.0));
	}
	COLOR = vec4(col, 1.0);
}
