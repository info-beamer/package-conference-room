uniform sampler2D Texture;
varying vec2 TexCoord;
uniform float percent;

float interp(float x) {
    return 2.0 * x * x * x - 3.0 * x * x + 1.0;
}

void main() {
    vec2 pos = TexCoord;
    float angle = atan(pos.x - 0.5, pos.y - 0.5);
    float dist = clamp(distance(pos, vec2(0.5, 0.5)), 0.0, 0.5) * 2.0;
    float alpha = interp(pow(dist, 8.0));
    if (angle < percent) {
        gl_FragColor = vec4(1.0, 1.0, 1.0, alpha);
    } else {
        gl_FragColor = vec4(0.5, 0.5, 0.5, alpha);
    }
}
