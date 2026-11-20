shader_type canvas_item;
// Тайл заготовки — в холст атласа (MapBake._put): тексель в тексель, без смешения.
render_mode blend_disabled, unshaded;

void fragment() {
	COLOR = texelFetch(TEXTURE, ivec2(UV * vec2(textureSize(TEXTURE, 0))), 0);
}
