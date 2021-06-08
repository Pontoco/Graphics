#ifndef UNIVERSAL_ASG_COLOR_PAINTING_INCLUDE
#define UNIVERSAL_ASG_COLOR_PAINTING_INCLUDE

// (ASG): This file contains a number of different color blending functions which take a fragment's final color
// and blends it with the vertex color. This allows us to use the vertex color to paint overlays and light on meshes
// in the scene.

// Note: Most of the blend effects reverse the vertex color alpha channel, because white is the default color applied
// to objects in Unity that do not have vertex colors assigned. So a value of white results in a no blend effect.

// The "Multiply" blend mode, with strength controlled by the vertex alpha channel.
half3 VertexBlend_Multiply(half3 sdrOutputColor, half4 linearVertexColor) {
    return lerp(sdrOutputColor, sdrOutputColor * linearVertexColor.rgb, 1 - linearVertexColor.a);
}

// Linearly interpolates between the vertex color and the output color, controlled by the vertex alpha channel.
half3 VertexBlend_ColorBlend(half3 sdrOutputColor, half4 linearVertexColor) {
    return lerp(sdrOutputColor, linearVertexColor.rgb, 1 - linearVertexColor.a);
}

// The top level color blending function.
// Called by PBRForwardPass.hlsl (ShaderGraph) and LitForwardPass.hlsl (URP Lit Shader)
half3 ApplyVertexColorBlend(half3 linearSdrOutputColor, half4 linearVertexColor) {
    return VertexBlend_ColorBlend(linearSdrOutputColor, linearVertexColor);
}

#endif
