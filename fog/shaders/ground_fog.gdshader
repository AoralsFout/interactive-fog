shader_type fog;
#include "res://fog/shaders/fog_extinction.gdshaderinc"

void fog() {
	DENSITY = fog_extinction(WORLD_POSITION);
	ALBEDO = fog_albedo.rgb;
	EMISSION = fog_emission.rgb;
}
