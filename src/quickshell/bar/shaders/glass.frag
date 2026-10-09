#version 440
// Liquid-glass pill for the top bar: translucent tint, soft top sheen and a
// hairline rim that is bright at the top-left and fades towards the bottom-right
// (same feel as the kitty glass windows). Drawn in one pass from a rounded-rect SDF.
// Rebuild: /usr/lib/qt6/bin/qsb --glsl "100es,120,150" --hlsl 50 --msl 12 -o glass.frag.qsb glass.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size (logical px)
    float radius;     // corner radius (logical px)
    float rimWidth;   // rim thickness (logical px)
    vec4 tint;        // straight rgba
    vec4 rimTop;      // straight rgba, rim colour at the lit edge
    vec4 rimBottom;   // straight rgba, rim colour at the far edge
    float sheen;      // strength of the top highlight inside the pill
};

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
    // rim band: inside the shape, within rimWidth of the edge
    float rim = fill * clamp(0.5 + (d + rimWidth) / aa, 0.0, 1.0);

    // light comes from the top-left: mostly vertical, a little horizontal
    float t = clamp(uv.y * 0.85 + uv.x * 0.15, 0.0, 1.0);
    vec4 rc = mix(rimTop, rimBottom, smoothstep(0.0, 1.0, t));

    // glass body: tint plus a soft sheen on the upper half
    float sh = sheen * (1.0 - smoothstep(0.0, 0.6, uv.y));
    vec3 body = tint.rgb;
    float bodyA = tint.a;
    // add the sheen as light (premultiplied add)
    vec4 col = vec4(body * bodyA + vec3(sh), bodyA + sh) * fill;

    float ra = rc.a * rim;
    col = vec4(rc.rgb * ra, ra) + col * (1.0 - ra);

    fragColor = col * qt_Opacity;
}
