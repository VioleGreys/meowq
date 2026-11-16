shader_type canvas_item;
// Слой фишек (UnitLayer) нарисован для «опорной» камеры r_*; пока он не
// перерисован, вершины переносятся под текущую камеру c_*: экран опорной →
// точка мира → экран текущей (та же проекция, что MapView.world_to_screen /
// screen_to_world). Без наклона и при том же масштабе — точный перенос.

uniform bool on = false;
uniform vec2 r_pos = vec2(0.0);
uniform float r_zoom = 1.0;
uniform float r_tilt = 0.0;
uniform vec2 c_pos = vec2(0.0);
uniform float c_zoom = 1.0;
uniform float c_tilt = 0.0;
uniform float cam_f = 1000.0;
uniform vec2 half_size = vec2(640.0, 360.0);

vec2 s2w(vec2 p, vec2 pos, float z, float th) {
	if (th <= 0.0) {
		return (p - half_size) / z + pos;
	}
	vec2 sc = p - half_size;
	float d = cam_f / z;
	float st = sin(th);
	float ct = cos(th);
	float den = max(ct + st * sc.y / cam_f, 1e-4);
	float tr = d * ct / den;
	return vec2(pos.x + tr * sc.x / cam_f, pos.y + d * st + tr * (-st + ct * sc.y / cam_f));
}

vec2 w2s(vec2 p, vec2 pos, float z, float th) {
	if (th <= 0.0) {
		return (p - pos) * z + half_size;
	}
	float d = cam_f / z;
	float st = sin(th);
	float ct = cos(th);
	float vx = p.x - pos.x;
	float vy = p.y - pos.y - d * st;
	float vz = -d * ct;
	float depth = max(-vy * st - vz * ct, d * 0.05);
	float up = -vy * ct + vz * st;
	return vec2(half_size.x + cam_f * vx / depth, half_size.y - cam_f * up / depth);
}

void vertex() {
	if (on) {
		VERTEX = w2s(s2w(VERTEX, r_pos, r_zoom, r_tilt), c_pos, c_zoom, c_tilt);
	}
}
