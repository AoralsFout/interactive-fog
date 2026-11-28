shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, specular_disabled, ambient_light_disabled, fog_disabled;
#include "res://fog/shaders/fog_extinction.gdshaderinc"

uniform int slice_count = 6;
uniform float anisotropy = 0.2;
uniform vec3 ambient_scatter;
varying vec3 sample_position;
varying flat float band_height;

void vertex() {
	// Quadratic spacing puts more samples near the dense bottom. From below
	// the layer the upper planes need to be drawn first for alpha blending.
	float count = float(slice_count);
	float eye_ground = world_origin.y;
	if (use_height_map) {
		vec2 center = MODEL_MATRIX[3].xz;
		vec2 half_tile = 0.5*vec2(length(MODEL_MATRIX[0].xz),length(MODEL_MATRIX[2].xz));
		eye_ground = ground_height(clamp(CAMERA_POSITION_WORLD.xz,center-half_tile,center+half_tile));
	}
	float eye_height = clamp((CAMERA_POSITION_WORLD.y-eye_ground)/thickness, 0.0, 1.0);
	float below = floor(sqrt(max(0.0,eye_height*count*count-0.25))+0.5);
	float id = float(INSTANCE_ID);
	float index = id < below ? id : count-1.0-(id-below);
	float low = index/count;
	float high = (index+1.0)/count;
	band_height = thickness*(high*high-low*low);
	VERTEX.y = thickness*(low*low+high*high)*0.5;
	if (use_height_map) {
		vec2 world_xz = (MODEL_MATRIX * vec4(VERTEX.x,0.0,VERTEX.z,1.0)).xz;
		VERTEX.y += ground_height(world_xz)-MODEL_MATRIX[3].y;
	} else {
		VERTEX.xz *= area_size;
	}
	sample_position = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
}

void fragment() {
	float sigma = fog_extinction(sample_position);
	vec3 ray = normalize(CAMERA_POSITION_WORLD-sample_position);
	float slope = abs(ray.y);
	if (use_height_map) {
		// Convert a vertical band thickness into distance along this ray.
		vec3 n = normalize(cross(dFdx(sample_position),dFdy(sample_position)));
		slope = abs(dot(ray,n))/max(0.001,abs(n.y));
	}
	ALPHA = 1.0-exp(-sigma*band_height/max(0.05,slope));
	if (ALPHA < 0.0005) discard;
	ALBEDO = fog_albedo.rgb;
	EMISSION = fog_emission.rgb + fog_albedo.rgb*ambient_scatter;
}

void light() {
	float g = clamp(anisotropy,-0.95,0.95);
	float phase = (1.0-g*g)/(4.0*PI*pow(1.0+g*g+2.0*g*dot(LIGHT,VIEW),1.5));
	DIFFUSE_LIGHT += LIGHT_COLOR * (ATTENUATION*phase);
}
