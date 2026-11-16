shader_type canvas_item;
// Заготовка неподвижной части карты (MapBake): выход (V/BK_V, 1 − S/BK_S).
render_mode blend_disabled;
#define BAKE_OUT
#include "res://shaders/map_core.gdshaderinc"
