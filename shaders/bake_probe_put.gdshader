shader_type canvas_item;
// Проба стенда (MapBake.probe_put): тайл читается, холст не меняется (сложение нуля).
render_mode blend_add, unshaded;

void fragment() {
	COLOR = vec4(texture(TEXTURE, UV).rgb * 1e-6, 0.0);
}
