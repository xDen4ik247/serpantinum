#version 440
// Apple-style Liquid Glass card for notification popups (LiquidCard.qml). niri blurs and
// saturates what is behind the card (ext-background-effect); this pass paints the glass
// itself from a rounded-rect SDF:
//   - a thin dark tint with a soft top-to-bottom light falloff,
//   - a thick-glass "lens" band along the edge that catches light (refraction look),
//   - a specular rim lit from the top-left with a weaker bounce at the bottom-right,
//   - a faint inner shadow at the bottom edge.
// Rebuild: /usr/lib/qt6/bin/qsb --glsl "100es,120,150" --hlsl 50 --msl 12 -o liquidglass.frag.qsb liquidglass.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // item size (logical px)
    float radius;     // corner radius (logical px)
    vec4 tint;        // straight rgba body tint
    float lensWidth;  // width of the bright edge band (logical px)
    float lens;       // strength of the edge band
    float rim;        // strength of the specular rim
    float glow;       // extra light (hover)
};

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec2 roundBoxNormal(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    vec2 n;
    if (q.x > 0.0 && q.y > 0.0) n = normalize(q);
    else if (q.x > q.y) n = vec2(1.0, 0.0);
    else n = vec2(0.0, 1.0);
    return n * sign(p + 1e-6);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p = (uv - 0.5) * size;
    vec2 b = size * 0.5;
    float r = min(radius, min(b.x, b.y));
    float d = sdRoundBox(p, b, r);
    float aa = max(fwidth(d), 0.0001);
    float fill = clamp(0.5 - d / aa, 0.0, 1.0);
    if (fill <= 0.0) { fragColor = vec4(0.0); return; }

    float inside = -d;                         // distance to the edge, >= 0 inside
    vec2 n = roundBoxNormal(p, b, r);
    vec2 L = normalize(vec2(-0.55, -0.85));    // light from the top-left (y grows downwards)
    float facing = dot(n, L);

    // body: tint + light falling off from the top
    vec3 col = tint.rgb;
    float a = tint.a;
    float topLight = (0.07 + glow) * (1.0 - smoothstep(0.0, 0.75, uv.y));
    col = mix(col, vec3(1.0), topLight);
    a = a + topLight * (1.0 - a);

    // lens band: the thick edge of the glass bends more light, brightest on the lit side
    float band = 1.0 - smoothstep(0.0, lensWidth, inside);
    band = band * band;
    float bandLight = lens * band * (0.55 + 0.45 * max(facing, 0.0) + 0.25 * max(-facing, 0.0));
    col = mix(col, vec3(1.0), bandLight);
    a = a + bandLight * (1.0 - a);

    // inner shadow along the bottom edge (depth)
    float bottom = (1.0 - smoothstep(0.0, lensWidth * 0.8, inside)) * smoothstep(0.2, 1.0, n.y);
    col = mix(col, vec3(0.0), 0.10 * bottom);

    // specular rim: hairline, strong where the edge faces the light, a weaker bounce opposite
    float rimBand = clamp(1.0 - (inside - 0.15) / 1.35, 0.0, 1.0);
    float spec = 0.16 + 0.84 * pow(max(facing, 0.0), 2.5) + 0.45 * pow(max(-facing, 0.0), 3.0);
    float ra = clamp(rim * spec * rimBand + glow * rimBand, 0.0, 1.0);
    col = mix(col, vec3(1.0), ra);
    a = a + ra * (1.0 - a);

    fragColor = vec4(col * a, a) * fill * qt_Opacity;
}
