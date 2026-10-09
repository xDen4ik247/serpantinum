#version 440
// Rounded, aspect-cropped image in one pass (no extra layer/FBO per cover):
// samples `source` through `crop` (uv offset.xy, uv scale.zw) and masks it with
// an anti-aliased rounded-rect SDF.
// Rebuild: /usr/lib/qt6/bin/qsb --glsl "100es,120,150" --hlsl 50 --msl 12 -o round.frag.qsb round.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    float radius;
    vec4 crop;
    float dim;
};

layout(binding = 1) uniform sampler2D source;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p = (uv - 0.5) * size;
    float r = min(radius, min(size.x, size.y) * 0.5);
    float d = sdRoundBox(p, size * 0.5, r);
    float aa = max(fwidth(d), 0.0001);
    float fill = clamp(0.5 - d / aa, 0.0, 1.0);
    vec4 c = texture(source, crop.xy + uv * crop.zw);
    c.rgb *= (1.0 - dim);
    fragColor = c * fill * qt_Opacity;
}
