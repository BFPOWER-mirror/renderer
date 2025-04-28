#version 450

layout (location = 0) in vec4 v_pos;
layout (location = 1) in vec4 v_normal;
layout (location = 2) in vec2 v_uv;

layout(location = 0) out vec4 color;
layout(location = 1) out vec4 roughness_metallic_uv;

struct Material {
    vec4 base_color;
    float roughness;
    float metallic;
};

layout(binding = 0) uniform UniformBlock {
    mat4 projection;
    float dpi_scale;
    Material material;
};

void main() {
    vec3 local_pos = v_pos.xyz;
    gl_Position = projection * vec4(local_pos, 1.0);

    color = material.base_color;
    roughness_metallic_uv = vec4(material.roughness, material.metallic, v_uv);
}