shader_type canvas_item;
// Карта во время движения (MapView, кэш движения): готовый плоский кадр вида сверху
// (закольцованный буфер cache_tex, нарисован шейдером карты без наклона) выводится
// с текущей камерой — перспектива, подъём гор (параллакс) и дымка как в map.gdshader.
// Без наклона и при том же масштабе — пиксель в пиксель с полным кадром.

uniform sampler2D cache_tex : filter_linear, repeat_enable;
uniform sampler2DArray base_tex : filter_linear_mipmap;   // слой 0, канал r — высота суши
uniform vec2 world_size = vec2(1.0);
uniform vec2 cam_pos = vec2(0.0);
uniform float cam_zoom = 1.0;
uniform float cam_tilt = 0.0;
uniform float cam_f = 1000.0;
uniform vec2 scr_size = vec2(1280.0, 720.0);
// кэш: камера-якорь, масштаб (логический), пикселей буфера на логический, окно, размер
uniform vec2 c_cam = vec2(0.0);
uniform float c_zoom = 1.0;
uniform float c_rk = 1.0;
uniform vec2 c_n = vec2(0.0);
uniform vec2 c_size = vec2(1.0);
uniform bool c_exact = false;   // без наклона и тот же масштаб — брать ближайший пиксель
uniform bool c_clip = false;    // вне окна буфера — прозрачно (под кэшем упрощённый кадр)

const float RELIEF_H = 6.0;   // как в map.gdshader

void fragment() {
	vec2 sc = UV * scr_size - scr_size * 0.5;
	float st = sin(cam_tilt);
	float ct = cos(cam_tilt);
	float dist = cam_f / cam_zoom;
	float den = ct + st * sc.y / cam_f;
	float tr = dist * ct / max(den, 1e-4);
	vec2 wp = vec2(cam_pos.x + tr * sc.x / cam_f,
		cam_pos.y + dist * st + tr * (-st + ct * sc.y / cam_f));
	if (cam_tilt > 0.001) {
		float hh = max(textureLod(base_tex, vec3(wp / world_size, 0.0), 0.0).r - 0.5, 0.0) * 2.0;
		vec2 ray = vec2(sc.x / cam_f, -st + ct * sc.y / cam_f) / max(den, 1e-4);
		wp -= ray * hh * RELIEF_H;
	}
	vec2 muv = wp / world_size;
	bool outside = den <= 1e-4 || muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0;
	float haze = clamp((tr / dist - 1.0) * 0.35, 0.0, 0.22) * smoothstep(0.05, 0.5, cam_tilt);
	// пиксель кадра якоря → пиксель закольцованного буфера
	vec2 a = (wp - c_cam) * (c_zoom * c_rk) + c_size * 0.5;
	vec2 ac = clamp(a, c_n + 0.5, c_n + c_size - 0.5);
	// вне окна: мягкий край в 2 пикселя буфера к упрощённому кадру под кэшем
	float edge = c_clip ? 1.0 - smoothstep(0.0, 2.0, length(a - ac)) : 1.0;
	a = ac;
	vec2 b = mod(a, c_size);
	if (c_exact) {
		b = floor(b) + 0.5;
	}
	vec3 col = textureLod(cache_tex, b / c_size, 0.0).rgb;
	col = mix(col, vec3(0.80, 0.84, 0.86), haze);
	COLOR = outside ? vec4(0.302, 0.302, 0.302, 1.0) : vec4(col, edge);
}
