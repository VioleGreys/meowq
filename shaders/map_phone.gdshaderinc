// Лёгкая карта для телефона (MapView.phone_map, map_phone.gdshader): тот же вид из
// заготовок, но без окна сглаживания 4×4, живых рек с берегами и прочей тяжёлой
// части полного шейдера — на Adreno 619 полный кадр стоил 300–500 мс (ноябрь 2026).
// Провинция и веса линий — окном 2×2 с билинейными весами (как среднее
// качество полного шейдера, но без массивов и циклов: только скаляры); вдали
// линии — по полю расстояний sdf_tex. Реки — линия и простая лента без берегов.
// Подключается из map_core.gdshaderinc вместо его fragment() при PHONE.

void fragment() {
	vec2 bp = floor(v_bp) + 0.5;
	bp = torus_n + mod(bp - torus_n, buf_size);
	vec2 sc = bp / buf_size * scr_size - scr_size * 0.5;
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
	float zoom = cam_zoom * dist / tr;
	bool outside = den <= 1e-4 || muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0;
	muv = clamp(muv, vec2(0.0), vec2(1.0));
	float haze = clamp((tr / dist - 1.0) * 0.35, 0.0, 0.22) * smoothstep(0.05, 0.5, cam_tilt);
	vec2 px = muv * map_size;
	ivec2 ip = ivec2(floor(px));
	float texel_px = zoom * 2.0 * res_k / id_k;   // тексель сетки провинций на экране
	float map_px = texel_px * id_k;                // пиксель карты на экране

	// всё с производными — до ветвлений
	vec4 b0 = textureLod(base_tex, vec3(muv, 0.0), 0.0);   // g — сила реки, b — доля суши
	float cov = b0.b;
	float d0 = abs(cov - 0.5) * 2.0;
	float fw0 = fwidth(d0);
	float rv_d = 1e4;
	float rv_fw = 1.0;
	if (has_rivers) {
		vec4 rv4 = texture(base_tex, vec3(muv, 1.0));
		rv_d = max(length((rv4.rg * 255.0 - 128.0) / 127.0) * RIVER_MAX, rv4.a * RIVER_MAX - 0.75);
	}
	rv_fw = max(fwidth(rv_d), 1e-4);
	float sdf_px = 1e4;   // до границы провинций, пикселей экрана
	if (has_sdf) {
		bool s_east = px.x >= float(ids_half);
		vec2 suv = vec2((s_east ? px.x - float(ids_off) : px.x) / sdf_wd, muv.y);
		vec2 sgx = vec2(dFdx(px.x) / sdf_wd, dFdx(muv.y));
		vec2 sgy = vec2(dFdy(px.x) / sdf_wd, dFdy(muv.y));
		sdf_px = textureGrad(sdf_tex, vec3(suv, s_east ? 1.0 : 0.0), sgx, sgy).r * 2.0 * texel_px;
	}

	// окно 2×2 (как среднее качество полного шейдера): четыре ближайших текселя,
	// билинейные веса; провинция — с наибольшей суммой весов своих текселей
	vec2 q = px - 0.5;
	ivec2 i0 = ivec2(floor(q));
	vec2 f = q - floor(q);
	float w0 = (1.0 - f.x) * (1.0 - f.y);
	float w1 = f.x * (1.0 - f.y);
	float w2 = (1.0 - f.x) * f.y;
	float w3 = f.x * f.y;
	int p0 = pid(i0);
	int p1 = pid(i0 + ivec2(1, 0));
	int p2 = pid(i0 + ivec2(0, 1));
	int p3 = pid(i0 + ivec2(1, 1));
	int c0 = nation(pal(0, p0));
	int c1 = nation(pal(0, p1));
	int c2 = nation(pal(0, p2));
	int c3 = nation(pal(0, p3));
	// сумма весов провинции каждого текселя
	float W0 = w0 + (p1 == p0 ? w1 : 0.0) + (p2 == p0 ? w2 : 0.0) + (p3 == p0 ? w3 : 0.0);
	float W1 = w1 + (p0 == p1 ? w0 : 0.0) + (p2 == p1 ? w2 : 0.0) + (p3 == p1 ? w3 : 0.0);
	float W2 = w2 + (p0 == p2 ? w0 : 0.0) + (p1 == p2 ? w1 : 0.0) + (p3 == p2 ? w3 : 0.0);
	float W3 = w3 + (p0 == p3 ? w0 : 0.0) + (p1 == p3 ? w1 : 0.0) + (p2 == p3 ? w2 : 0.0);
	bool cov_land = cov >= 0.5;
	// победитель; по контуру суша — только среди суши (если есть), море — любой
	bool want_land = cov_land && (c0 >= 0 || c1 >= 0 || c2 >= 0 || c3 >= 0);
	int id = p0;
	int ctrl = c0;
	float top_w = -1.0;
	if ((!want_land || c0 >= 0) && W0 > top_w) { top_w = W0; id = p0; ctrl = c0; }
	if ((!want_land || c1 >= 0) && W1 > top_w) { top_w = W1; id = p1; ctrl = c1; }
	if ((!want_land || c2 >= 0) && W2 > top_w) { top_w = W2; id = p2; ctrl = c2; }
	if ((!want_land || c3 >= 0) && W3 > top_w) { top_w = W3; id = p3; ctrl = c3; }
	vec4 cc = pal(0, id);
	bool land = ctrl >= 0;
	bool sea_px = land && !cov_land;   // суша по провинции, но по контуру — вода
	// веса для линий: своя страна / лучшая чужая / лучшая другая провинция своей
	float w_mine = (c0 == ctrl ? w0 : 0.0) + (c1 == ctrl ? w1 : 0.0) + (c2 == ctrl ? w2 : 0.0) + (c3 == ctrl ? w3 : 0.0);
	float o0 = c0 >= 0 && c0 != ctrl ? w0 + (c1 == c0 ? w1 : 0.0) + (c2 == c0 ? w2 : 0.0) + (c3 == c0 ? w3 : 0.0) : 0.0;
	float o1 = c1 >= 0 && c1 != ctrl ? w1 + (c0 == c1 ? w0 : 0.0) + (c2 == c1 ? w2 : 0.0) + (c3 == c1 ? w3 : 0.0) : 0.0;
	float o2 = c2 >= 0 && c2 != ctrl ? w2 + (c0 == c2 ? w0 : 0.0) + (c1 == c2 ? w1 : 0.0) + (c3 == c2 ? w3 : 0.0) : 0.0;
	float o3 = c3 >= 0 && c3 != ctrl ? w3 + (c0 == c3 ? w0 : 0.0) + (c1 == c3 ? w1 : 0.0) + (c2 == c3 ? w2 : 0.0) : 0.0;
	float w_other = max(max(o0, o1), max(o2, o3));
	float w_prov2 = max(max(p0 != id && c0 == ctrl ? W0 : 0.0, p1 != id && c1 == ctrl ? W1 : 0.0),
		max(p2 != id && c2 == ctrl ? W2 : 0.0, p3 != id && c3 == ctrl ? W3 : 0.0));
	// фронт: наш участок (роль 1) против цели (2)
	float w_fo = 0.0;
	float w_ft = 0.0;
	int fo_id = -1;
	int role_top = 0;
	if (front_on) {
		int r0 = int(pal(3, p0).a * 255.0 + 0.5);
		int r1 = int(pal(3, p1).a * 255.0 + 0.5);
		int r2 = int(pal(3, p2).a * 255.0 + 0.5);
		int r3 = int(pal(3, p3).a * 255.0 + 0.5);
		float fb = -1.0;
		if ((r0 & 1) != 0) { w_fo += w0; if (w0 > fb) { fb = w0; fo_id = p0; } }
		if ((r1 & 1) != 0) { w_fo += w1; if (w1 > fb) { fb = w1; fo_id = p1; } }
		if ((r2 & 1) != 0) { w_fo += w2; if (w2 > fb) { fb = w2; fo_id = p2; } }
		if ((r3 & 1) != 0) { w_fo += w3; if (w3 > fb) { fb = w3; fo_id = p3; } }
		w_ft = ((r0 & 2) != 0 ? w0 : 0.0) + ((r1 & 2) != 0 ? w1 : 0.0) + ((r2 & 2) != 0 ? w2 : 0.0) + ((r3 & 2) != 0 ? w3 : 0.0);
		role_top = int(pal(3, id).a * 255.0 + 0.5);
	}
	float s1 = w_mine + w_other;
	float d1 = s1 > 0.0 ? abs(w_mine - w_other) / s1 : 1.0;
	float s2 = top_w + w_prov2;
	float d2 = s2 > 0.0 ? (top_w - w_prov2) / s2 : 1.0;
	float s3 = w_fo + w_ft;
	float d3 = s3 > 0.0 ? abs(w_fo - w_ft) / s3 : 1.0;
	float fw3 = fwidth(d3);
	// вблизи — по весам окна (доля линейна до полутекселя), вдали — поле расстояний
	float near_b = has_sdf ? smoothstep(1.3, 2.2, texel_px) : 1.0;

	bool land_c = land && !sea_px;
	vec4 bk = bake_at(wp, zoom, land_c);
	mediump vec3 col;
	if (!land_c) {
		col = bk.rgb * BK_V;
	} else {
		mediump vec3 base = cc.rgb;
		if (terrain_mode) {
			base = vec3(0.56, 0.54, 0.45);
		} else if (show_occupation && nation(pal(1, id)) != ctrl) {
			float s = step(0.5, fract((px.x + px.y) / id_k * 0.28));
			base = mix(base, pal(1, id).rgb, s * 0.75);
		}
		col = base * ((1.0 - bk.a) * BK_S) + bk.rgb * BK_V;
	}

	// реки: вдали — тонкая синяя линия, вблизи — лента воды с тёмной кромкой
	float river_m = 0.0;
	if (has_rivers && land_c && b0.g > 0.01) {
		float nk = smoothstep(2.8, 4.6, zoom);
		float mp = zoom * 2.0 * res_k;
		float hw_px = max(1.2 * exp(0.58 * (min(zoom, 5.0) - 1.0)), 1.3) * res_k * max(zoom / 5.0, 1.0);
		float hw = clamp(hw_px / mp, 1.3 * rv_fw, RIVER_MAX - 0.8);
		float aa = 0.6 * rv_fw;
		float has = b0.g > 0.5 ? 1.0 : smoothstep(0.4, 0.9, zoom);
		float river = (1.0 - smoothstep(hw - aa, hw + aa, rv_d)) * has;
		float bw = 0.4 * nk + 0.35 * rv_fw * nk + 0.9 * rv_fw * (1.0 - nk);
		float bank = max((1.0 - smoothstep(hw + bw - aa, hw + bw + aa, rv_d)) * has - river, 0.0);
		river_m = river + bank;
		float mid = clamp(1.0 - rv_d / max(hw, 1e-3), 0.0, 1.0);
		mediump vec3 rw = mix(vec3(0.34, 0.41, 0.36), vec3(0.15, 0.27, 0.35), smoothstep(0.05, 0.8, mid));
		rw = mix(vec3(0.27, 0.43, 0.60), rw, nk);
		col = mix(col, mix(col * 0.62, vec3(0.50, 0.46, 0.34), nk), bank * mix(0.18, 0.6, nk));
		col = mix(col, rw, river * smoothstep(0.3, 0.7, zoom));
	}
	if (land_c && has_band && !terrain_mode) {
		mediump float bd = texture(band_tex, muv).r;
		col = mix(col, cc.rgb * 0.5, bd * bd * 0.62 * (1.0 - river_m));
	}
	if (land_c && highlight_nation >= 0 && ctrl != highlight_nation) {
		col = mix(col, vec3(dot(col, vec3(0.33))), 0.55) * 0.8;
	}

	// берег — по векторной доле суши
	if (cov > 0.01 && cov < 0.99) {
		float dp = d0 / max(fw0, 0.5 / texel_px) * 0.5;
		float w = max(lw_min(0.75), min(0.2 * map_px, 0.3 * texel_px + 0.5));
		col = mix(col, vec3(0.10, 0.13, 0.17), (1.0 - smoothstep(w - 0.8, w + 0.8, dp)) * 0.8);
	}
	if (land_c && w_prov2 > 0.0) {
		float dp = mix(sdf_px, border_tx(d2, true) * texel_px, near_b);
		float w = max(lw_min(0.6), 0.14 * map_px);
		float a2 = smoothstep(0.45, 1.3, zoom) * (1.0 - smoothstep(0.15, 0.6, river_m));
		col = mix(col, col * 0.6, (1.0 - smoothstep(w - 0.7, w + 0.7, dp)) * a2);
	}
	// область — только выбранной провинции: её область против остальной суши окна
	if (has_states && selected_id >= 0 && land_c) {
		vec4 ss = pal(2, selected_id);
		int sel_st = int(ss.r * 255.0 + 0.5) + int(ss.g * 255.0 + 0.5) * 256;
		vec4 t0 = pal(2, p0);
		vec4 t1 = pal(2, p1);
		vec4 t2 = pal(2, p2);
		vec4 t3 = pal(2, p3);
		bool e0 = int(t0.r * 255.0 + 0.5) + int(t0.g * 255.0 + 0.5) * 256 == sel_st;
		bool e1 = int(t1.r * 255.0 + 0.5) + int(t1.g * 255.0 + 0.5) * 256 == sel_st;
		bool e2 = int(t2.r * 255.0 + 0.5) + int(t2.g * 255.0 + 0.5) * 256 == sel_st;
		bool e3 = int(t3.r * 255.0 + 0.5) + int(t3.g * 255.0 + 0.5) * 256 == sel_st;
		float w_in = (c0 >= 0 && e0 ? w0 : 0.0) + (c1 >= 0 && e1 ? w1 : 0.0) + (c2 >= 0 && e2 ? w2 : 0.0) + (c3 >= 0 && e3 ? w3 : 0.0);
		float w_out = (c0 >= 0 && !e0 ? w0 : 0.0) + (c1 >= 0 && !e1 ? w1 : 0.0) + (c2 >= 0 && !e2 ? w2 : 0.0) + (c3 >= 0 && !e3 ? w3 : 0.0);
		if (w_in > 0.0 && w_out > 0.0) {
			float dp = border_tx(abs(w_in - w_out) / (w_in + w_out), true) * texel_px;
			float w = max(lw_min(1.0), min(0.22 * map_px, 0.9 * texel_px));
			col = mix(col, vec3(0.96, 0.92, 0.78), (1.0 - smoothstep(w - 0.8, w + 0.8, dp)) * 0.85);
		}
	}
	if (land_c && w_other > 0.0) {
		float dp = mix(sdf_px, border_tx(d1, true) * texel_px, near_b);
		float w = max(lw_min(1.0), min(0.18 * map_px, mix(1.2, 0.4, near_b) * texel_px));
		col = mix(col, cc.rgb * 0.28, (1.0 - smoothstep(w - 0.8, w + 0.8, dp)) * 0.78 * (1.0 - smoothstep(0.15, 0.6, river_m)));
	}
	if (front_on && land_c && role_top != 0) {
		mediump vec3 fc = pal(3, id).rgb;
		if ((role_top & 4) != 0) {
			col = mix(col, fc, 0.32);
		}
		if ((role_top & 8) != 0) {
			float sh = step(0.62, fract((wp.x - wp.y) * zoom / 11.0));
			col = mix(col, fc * 0.9, sh * 0.42);
		}
	}
	if (front_on && land_c && w_fo > 0.0 && w_ft > 0.0 && fo_id >= 0) {
		mediump vec3 fc = pal(3, fo_id).rgb;
		float dp = d3 / max(fw3, 0.5 / texel_px) * 0.5;
		float w = min(max(lw_min(2.3 * res_k), 0.55 * map_px), 7.0 * res_k);
		col = mix(col, vec3(0.05, 0.04, 0.03), (1.0 - smoothstep(w + 0.4, w + 1.6, dp)) * 0.85);
		col = mix(col, fc, 1.0 - smoothstep(w - 0.8, w + 0.4, dp));
	}
	if (id == selected_id && land) {
		col = mix(col, vec3(1.0, 0.96, 0.8), 0.3);
	}
	col = mix(col, vec3(0.80, 0.84, 0.86), haze);
	COLOR = outside ? vec4(0.302, 0.302, 0.302, 1.0) : vec4(col, 1.0);
}
