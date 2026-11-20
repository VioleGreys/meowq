shader_type canvas_item;
// Стенд нагрузки, «Цена видеокарты»: на весь буфер карты — 8 выборок одной текстуры
// (mode 1–5) или арифметика (6); 0 — пусто. Какая часть дорога на телефоне.
render_mode unshaded;
uniform int mode = 0;
uniform sampler2DArray base_tex : filter_linear_mipmap;
uniform sampler2DArray ids_tex : filter_nearest;
uniform sampler2DArray sdf_tex : filter_linear_mipmap;
uniform sampler2DArray color_tex : filter_linear_mipmap;
uniform sampler2D atlas_tex : filter_linear;

void fragment() {
	vec2 uv = UV * 0.25 + vec2(0.45, 0.2);
	vec4 a = vec4(0.0);
	if (mode == 1) {
		for (int i = 0; i < 8; i++) a += texture(base_tex, vec3(uv + float(i) * 0.0003, float(i % 3)));
	} else if (mode == 2) {
		ivec3 sz = textureSize(ids_tex, 0);
		for (int i = 0; i < 8; i++) a += texelFetch(ids_tex, ivec3(ivec2(uv * vec2(sz.xy)) + ivec2(i, 0), i % 2), 0);
	} else if (mode == 3) {
		for (int i = 0; i < 8; i++) a += texture(sdf_tex, vec3(uv + float(i) * 0.0003, float(i % 2)));
	} else if (mode == 4) {
		for (int i = 0; i < 8; i++) a += texture(color_tex, vec3(uv + float(i) * 0.0003, 0.0));
	} else if (mode == 5) {
		for (int i = 0; i < 8; i++) a += textureLod(atlas_tex, UV * 0.06 + float(i) * 0.001, 0.0);
	} else if (mode == 6) {
		vec2 p = uv;
		for (int i = 0; i < 64; i++) p = fract(p * 1.37 + sin(p.yx * 3.1 + float(i)));
		a = vec4(p, 0.0, 1.0);
	}
	COLOR = vec4(fract(a.rgb * 0.37 + UV.xyx * 0.1), 1.0);
}
