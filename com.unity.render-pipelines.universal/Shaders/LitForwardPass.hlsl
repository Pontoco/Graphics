#ifndef UNIVERSAL_FORWARD_LIT_PASS_INCLUDED
#define UNIVERSAL_FORWARD_LIT_PASS_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

struct Attributes
{
    float4 positionOS   : POSITION;
    float3 normalOS     : NORMAL;
    float4 tangentOS    : TANGENT;
    float2 texcoord     : TEXCOORD0;
    float2 lightmapUV   : TEXCOORD1;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct Varyings
{
    float2 uv                       : TEXCOORD0;
    DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 1);

#if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
    float3 positionWS               : TEXCOORD2;
#endif

#ifdef _NORMALMAP
    float4 normalWS                 : TEXCOORD3;    // xyz: normal, w: viewDir.x
    float4 tangentWS                : TEXCOORD4;    // xyz: tangent, w: viewDir.y
    float4 bitangentWS              : TEXCOORD5;    // xyz: bitangent, w: viewDir.z
#else
    float3 normalWS                 : TEXCOORD3;
    float3 viewDirWS                : TEXCOORD4;
#endif

    half4 fogFactorAndVertexLight   : TEXCOORD6; // x: fogFactor, yzw: vertex light

#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    float4 shadowCoord              : TEXCOORD7;
#endif

    float4 positionCS               : SV_POSITION;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

void InitializeInputData(Varyings input, half3 normalTS, out InputData inputData)
{
    inputData = (InputData)0;

#if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
    inputData.positionWS = input.positionWS;
#endif

#ifdef _NORMALMAP
    half3 viewDirWS = half3(input.normalWS.w, input.tangentWS.w, input.bitangentWS.w);
    inputData.normalWS = TransformTangentToWorld(normalTS,
        half3x3(input.tangentWS.xyz, input.bitangentWS.xyz, input.normalWS.xyz));
#else
    half3 viewDirWS = input.viewDirWS;
    inputData.normalWS = input.normalWS;
#endif

    inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
    viewDirWS = SafeNormalize(viewDirWS);
    inputData.viewDirectionWS = viewDirWS;

#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    inputData.shadowCoord = input.shadowCoord;
#elif defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

    inputData.fogCoord = input.fogFactorAndVertexLight.x;
    inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
    inputData.bakedGI = SAMPLE_GI(input.lightmapUV, input.vertexSH, inputData.normalWS);
}

///////////////////////////////////////////////////////////////////////////////
//                  Vertex and Fragment functions                            //
///////////////////////////////////////////////////////////////////////////////

// Used in Standard (Physically Based) shader
Varyings LitPassVertex(Attributes input)
{
    Varyings output = (Varyings)0;

    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

    VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
    VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
    half3 viewDirWS = GetCameraPositionWS() - vertexInput.positionWS;
    half3 vertexLight = VertexLighting(vertexInput.positionWS, normalInput.normalWS);
    half fogFactor = ComputeFogFactor(vertexInput.positionCS.z);

    output.uv = TRANSFORM_TEX(input.texcoord, _BaseMap);

#ifdef _NORMALMAP
    output.normalWS = half4(normalInput.normalWS, viewDirWS.x);
    output.tangentWS = half4(normalInput.tangentWS, viewDirWS.y);
    output.bitangentWS = half4(normalInput.bitangentWS, viewDirWS.z);
#else
    output.normalWS = NormalizeNormalPerVertex(normalInput.normalWS);
    output.viewDirWS = viewDirWS;
#endif

    OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
    OUTPUT_SH(output.normalWS.xyz, output.vertexSH);

    output.fogFactorAndVertexLight = half4(fogFactor, vertexLight);

#if defined(REQUIRES_WORLD_SPACE_POS_INTERPOLATOR)
    output.positionWS = vertexInput.positionWS;
#endif

#if defined(REQUIRES_VERTEX_SHADOW_COORD_INTERPOLATOR)
    output.shadowCoord = GetShadowCoord(vertexInput);
#endif

    output.positionCS = vertexInput.positionCS;

    return output;
}

// Calculates the subsurface light radiating out from the current fragment. This is a simple approximation using wrapped lighting.
// Note: This does not use distance attenuation, as it is intented to be used with a sun light.
// Note: This does not subtract out cast shadows (light.shadowAttenuation), as it is intended to be used on non-shadowed objects. (for now)
half3 LightingSubsurface(Light light, half3 normalWS, half3 subsurfaceColor, half subsurfaceRadius) {
    // Calculate normalized wrapped lighting. This spreads the light without adding energy.
    // This is a normal lambertian lighting calculation (using N dot L), but warping NdotL
    // to wrap the light further around an object.
    //
    // A normalization term is applied to make sure we do not add energy.
    // http://www.cim.mcgill.ca/~derek/files/jgt_wrap.pdf

    half NdotL = dot(normalWS, light.direction);
    half alpha = subsurfaceRadius;
    half theta_m = acos(-alpha); // boundary of the lighting function

    half theta = max(0, NdotL + alpha) - alpha;
    half normalization_jgt = (2 + alpha) / (2 * (1 + alpha));
    half wrapped_jgt = (pow(((theta + alpha) / (1 + alpha)), 1 + alpha)) * normalization_jgt;

    half wrapped_valve = 0.25 * (NdotL + 1) * (NdotL + 1);
    half wrapped_simple = (NdotL + alpha) / (1 + alpha);

    half3 subsurface_radiance = light.color * subsurfaceColor * wrapped_jgt;

    return subsurface_radiance;
}

half4 LitForwardFragmentPBR(InputData inputData, half3 albedo, half metallic, half3 specular,
    half smoothness, half occlusion, half3 emission, half alpha, half subsurface)
{
    BRDFData brdfData;
    InitializeBRDFData(albedo, metallic, specular, smoothness, alpha, brdfData);

    Light mainLight = GetMainLight(inputData.shadowCoord);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, half4(0, 0, 0, 0));

    half3 color = half3(0,0,0);//GlobalIllumination(brdfData, inputData.bakedGI, occlusion, inputData.normalWS, inputData.viewDirectionWS);
    half3 mainLightContribution = LightingPhysicallyBased(brdfData, mainLight, inputData.normalWS, inputData.viewDirectionWS);
    half3 subsurfaceContribution = LightingSubsurface(mainLight, inputData.normalWS, _SubsurfaceColor, _SubsurfaceRadius);

    // '_SubsurfaceScattering' controls the portion of the direct light that scatters within the object.
    // When 1, all light is scattered within the object, so the full contribution of color comes from the subsurface.
    // When .5, some light is scattered within, picking up the subsurface color, and is added to the normal reflectance of the surface.
    color += mainLightContribution * (1-_SubsurfaceScattering);
    color += subsurfaceContribution * (_SubsurfaceScattering);

#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS);
        color += LightingPhysicallyBased(brdfData, light, inputData.normalWS, inputData.viewDirectionWS);
    }
#endif

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    color += inputData.vertexLighting * brdfData.diffuse;
#endif

    color += emission;


    // Implements the Frostbite backface scattering. See links:
    // https://www.alanzucconi.com/2017/08/30/fast-subsurface-scattering-2/
    // https://colinbarrebrisebois.com/2011/03/07/gdc-2011-approximating-translucency-for-a-fast-cheap-and-convincing-subsurface-scattering-look/
    // This effect looks good on paper, but likely will need a thickness map
    // to make it effective, and generally it doesn't look good without it.
    // Additionally, it is built for scattering point lights. Scattering with the sun
    // light comes out a bit too even.

    // Distortion towards the view direction.
    //half _Distortion = 0.0;
    // Scale of the effect
    //half _Scale = .1;
    // Harshness of the effect
    //half _Power = 3;

    //half3 H = normalize(mainLight.direction + inputData.normalWS * _Distortion);
    //half I = pow(saturate(dot(inputData.viewDirectionWS, -H)), _Power) * _Scale;
    //color += I * _SubsurfaceColor * mainLight.color;

    return half4(color, alpha);
}


// Calculates the Luminance portion of a Linear RGB Color
// Luminance is the L component in the L*a*b color space.
float Luminance(half3 color)
{
    return dot(color, half3(0.2126f, 0.7152f, 0.0722f));
}

// Used in Standard (Physically Based) shader
half4 LitPassFragment(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

    SurfaceData surfaceData;
    InitializeStandardLitSurfaceData(input.uv, surfaceData);

    InputData inputData;
    InitializeInputData(input, surfaceData.normalTS, inputData);

    half4 color = LitForwardFragmentPBR(inputData, surfaceData.albedo, surfaceData.metallic, surfaceData.specular, surfaceData.smoothness, surfaceData.occlusion, surfaceData.emission, surfaceData.alpha, _SubsurfaceScattering);

    color.rgb = MixFog(color.rgb, inputData.fogCoord);

    // Displays the luminance of the HDR color with a 'false color' set of colored bands.
    // This is like a heatmap to better visualize the wide range of HDR values.
    #ifdef DEBUG_FALSE_COLOR
        half luminance = Luminance(color);
        return half4(.6 + .6 * cos( 6.3*(2.*luminance) + half3(0,23,21)), 0);
    #endif

    return color;
}

#endif
