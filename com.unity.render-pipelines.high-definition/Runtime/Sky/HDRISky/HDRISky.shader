Shader "Hidden/HDRP/Sky/HDRISky"
{
    HLSLINCLUDE

    #pragma vertex Vert

    #pragma editor_sync_compilation
    #pragma target 4.5
    #pragma only_renderers d3d11 playstation xboxone vulkan metal switch

    #define LIGHTLOOP_DISABLE_TILE_AND_CLUSTER

    #pragma multi_compile_local _ CLOUDMAP PROCEDURAL_CLOUDS
    #pragma multi_compile_local _ FLOWMAP_WIND PROCEDURAL_WIND

    #pragma multi_compile _ DEBUG_DISPLAY
    #pragma multi_compile SHADOW_LOW SHADOW_MEDIUM SHADOW_HIGH

    #pragma multi_compile USE_FPTL_LIGHTLIST USE_CLUSTERED_LIGHTLIST

    #define ATTRIBUTES_NEED_NORMAL
    #define ATTRIBUTES_NEED_TANGENT
    #define VARYINGS_NEED_POSITION_WS
    #define VARYINGS_NEED_TANGENT_TO_WORLD

    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/ShaderPass/ShaderPass.cs.hlsl"

    #define SHADERPASS SHADERPASS_FORWARD_UNLIT

    #define HAS_LIGHTLOOP

    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonLighting.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Sky/SkyUtils.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SDF2D.hlsl"

    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariablesFunctions.hlsl"

    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightLoop/HDShadow.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightLoop/LightLoopDef.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/PunctualLightCommon.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightLoop/HDShadowLoop.hlsl"

    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Material/NormalBuffer.hlsl"

    TEXTURECUBE(_Cubemap);
    SAMPLER(sampler_Cubemap);
    
    TEXTURE2D(_Cloudmap);
    SAMPLER(sampler_Cloudmap);
    
    TEXTURE2D(_Flowmap);
    SAMPLER(sampler_Flowmap);

    float4 _SkyParam; // x exposure, y multiplier, zw rotation (cosPhi and sinPhi)
    float4 _BackplateParameters0; // xy: scale, z: groundLevel, w: projectionDistance
    float4 _BackplateParameters1; // x: BackplateType, y: BlendAmount, zw: backplate rotation (cosPhi_plate, sinPhi_plate)
    float4 _BackplateParameters2; // xy: BackplateTextureRotation (cos/sin), zw: Backplate Texture Offset
    float3 _BackplateShadowTint;  // xyz: ShadowTint
    uint   _BackplateShadowFilter;

    float _Coverage;
    float _Opacity;
    float _WindForce;
    float _WindCos;
    float _WindSin;
    
    #define _Intensity          _SkyParam.x
    #define _CosPhi             _SkyParam.z
    #define _SinPhi             _SkyParam.w
    #define _CosSinPhi          _SkyParam.zw
    #define _Scales             _BackplateParameters0.xy
    #define _ScaleX             _BackplateParameters0.x
    #define _ScaleY             _BackplateParameters0.y
    #define _GroundLevel        _BackplateParameters0.z
    #define _ProjectionDistance _BackplateParameters0.w
    #define _BackplateType      _BackplateParameters1.x
    #define _BlendAmount        _BackplateParameters1.y
    #define _CosPhiPlate        _BackplateParameters1.z
    #define _SinPhiPlate        _BackplateParameters1.w
    #define _CosSinPhiPlate     _BackplateParameters1.zw
    #define _CosPhiPlateTex     _BackplateParameters2.x
    #define _SinPhiPlateTex     _BackplateParameters2.y
    #define _CosSinPhiPlateTex  _BackplateParameters2.xy
    #define _OffsetTexX         _BackplateParameters2.z
    #define _OffsetTexY         _BackplateParameters2.w
    #define _OffsetTex          _BackplateParameters2.zw
    #define _ShadowTint         _BackplateShadowTint.rgb
    #define _ShadowFilter       _BackplateShadowFilter

    #define WIND                defined(FLOWMAP_WIND) || defined(PROCEDURAL_WIND)

    struct Attributes
    {
        uint vertexID : SV_VertexID;
        UNITY_VERTEX_INPUT_INSTANCE_ID
    };

    struct Varyings
    {
        float4 positionCS : SV_POSITION;
        UNITY_VERTEX_OUTPUT_STEREO
    };

    Varyings Vert(Attributes input)
    {
        Varyings output;
        UNITY_SETUP_INSTANCE_ID(input);
        UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
        output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID, UNITY_RAW_FAR_CLIP_VALUE);
        return output;
    }

    float3 RotationUp(float3 p, float2 cos_sin)
    {
        float3 rotDirX = float3(cos_sin.x, 0, -cos_sin.y);
        float3 rotDirY = float3(cos_sin.y, 0,  cos_sin.x);

        return float3(dot(rotDirX, p), p.y, dot(rotDirY, p));
    }

    // TODO: cf. dir.y == 0
    float3 GetPositionOnInfinitePlane(float3 dir)
    {
        const float alpha = (_GroundLevel - _WorldSpaceCameraPos.y)/dir.y;

        return _WorldSpaceCameraPos + alpha*dir;
    }

    float GetSDF(out float scale, float2 position)
    {
        position = RotationUp(float3(position.x, 0.0f, position.y), _CosSinPhiPlate).xz;
        if (_BackplateType == 0) // Circle
        {
            scale = _ScaleX;
            return CircleSDF(position, _ScaleX);
        }
        else if (_BackplateType == 1) // Rectangle
        {
            scale = min(_ScaleX, _ScaleY);
            return RectangleSDF(position, _Scales);
        }
        else if (_BackplateType == 2) // Ellipse
        {
            scale = min(_ScaleX, _ScaleY);
            return EllipseSDF(position, _Scales);
        }
        else //if (_BackplateType == 3) // Infinite backplate
        {
            scale = FLT_MAX;
            return CircleSDF(position, scale);
        }
    }

    void IsBackplateCommon(out float sdf, out float localScale, out float3 positionOnBackplatePlane, float3 dir)
    {
        positionOnBackplatePlane = GetPositionOnInfinitePlane(dir);

        sdf = GetSDF(localScale, positionOnBackplatePlane.xz);
    }

    bool IsHit(float sdf, float dirY)
    {
        return sdf < 0.0f && dirY < 0.0f && _WorldSpaceCameraPos.y > _GroundLevel;
    }

    bool IsBackplateHit(out float3 positionOnBackplatePlane, float3 dir)
    {
        float sdf;
        float localScale;
        IsBackplateCommon(sdf, localScale, positionOnBackplatePlane, dir);

        return IsHit(sdf, dir.y);
    }

    bool IsBackplateHitWithBlend(out float3 positionOnBackplatePlane, out float blend, float3 dir)
    {
        float sdf;
        float localScale;
        IsBackplateCommon(sdf, localScale, positionOnBackplatePlane, dir);

        blend = smoothstep(0.0f, localScale*_BlendAmount, max(-sdf, 0));

        return IsHit(sdf, dir.y);
    }

// Cloud layer utilities
    float2 GetFlow(float3 dir)
    {
#ifdef FLOWMAP_WIND
        float angle = atan2(dir.z, dir.x )/(2.0*PI) + 0.5;
        return SAMPLE_TEXTURE2D_LOD(_Flowmap, sampler_Flowmap, float2(angle, abs(dir.y)), 0).rg * 2.0 - 1.0;
#else
        // source: https://www.gdcvault.com/play/1020146/Moving-the-Heavens-An-Artistic
        float3 d = float3(0, 1, 0) - dir;
        return (dir.y > 0) * normalize(d - dot(d, dir) * dir).zx;
#endif
    }

    float3 sampleCloud(float3 dir, float3 skyColor)
    {
#if CLOUDMAP
        if (dir.y < 0) return skyColor;

        float angle = atan2(dir.z, dir.x)/(2.0*PI) + 0.5;
        float4 clouds = SAMPLE_TEXTURE2D_LOD(_Cloudmap, sampler_Cloudmap, float2(angle, dir.y), 0);
        return lerp(skyColor, clouds.rgb, clouds.a);
#else
        return SAMPLE_TEXTURECUBE_LOD(_Cubemap, sampler_Cubemap, dir, 0).rgb;
#endif
    }

    float random(float2 uv)
    {
        return frac(sin(dot(uv.xy, float2(12.9898,78.233))) * 43758.5453);
    }

    float simpleNoiseValue(float2 uv)
    {
        float2 i = floor(uv);
        float2 f = frac(uv);
        f = f * f * (3. - 2. * f);

        float lb = random(i + float2(0., 0.));
        float rb = random(i + float2(1., 0.));
        float lt = random(i + float2(0., 1.));
        float rt = random(i + float2(1., 1.));

        return lerp(lerp(lb, rb, f.x), 
                lerp(lt, rt, f.x), f.y);
    }
    
    float simpleNoise(float2 UV, float Scale)
    {
        float t = 0.0;
    
        float freq = pow(2.0, float(0));
        float amp = pow(0.5, float(3-0));
        t += simpleNoiseValue(float2(UV.x*Scale/freq, UV.y*Scale/freq))*amp;
    
        freq = pow(2.0, float(1));
        amp = pow(0.5, float(3-1));
        t += simpleNoiseValue(float2(UV.x*Scale/freq, UV.y*Scale/freq))*amp;
    
        freq = pow(2.0, float(2));
        amp = pow(0.5, float(3-2));
        t += simpleNoiseValue(float2(UV.x*Scale/freq, UV.y*Scale/freq))*amp;
    
        return t;
    }
    
    float2 gradientNoiseValue(float2 p)
    {
        // Permutation and hashing used in webgl-nosie goo.gl/pX7HtC
        p = p % 289;
        float x = (34 * p.x + 1) * p.x % 289 + p.y;
        x = (34 * x + 1) * x % 289;
        x = frac(x / 41) * 2 - 1;
        return normalize(float2(x - floor(x + 0.5), abs(x) - 0.5));
    }
    
    float gradientNoise(float2 UV, float Scale)
    { 
        float2 p = UV * Scale;
        float2 ip = floor(p);
        float2 fp = frac(p);
        float d00 = dot(gradientNoiseValue(ip), fp);
        float d01 = dot(gradientNoiseValue(ip + float2(0, 1)), fp - float2(0, 1));
        float d10 = dot(gradientNoiseValue(ip + float2(1, 0)), fp - float2(1, 0));
        float d11 = dot(gradientNoiseValue(ip + float2(1, 1)), fp - float2(1, 1));
        fp = fp * fp * fp * (fp * (fp * 6 - 15) + 10);
        return lerp(lerp(d00, d01, fp.y), lerp(d10, d11, fp.y), fp.x) + 0.5;
    }
    
    float saturation(float3 In)
    {
        return dot(In, float3(0.2126729, 0.7151522, 0.0721750));
    }
// End of cloud layer utilities

    float3 GetSkyColor(float3 dir)
    {
        float3 sky = SAMPLE_TEXTURECUBE_LOD(_Cubemap, sampler_Cubemap, dir, 0).rgb;

#if WIND
        float3 windDir = RotationUp(dir, float2(_WindCos, _WindSin));
#else
        float3 windDir = dir;
#endif
        
#if PROCEDURAL_CLOUDS
        if (dir.y < 0) return sky;

        float2 uv = 1.2*windDir.xz / dir.y;
        float2 uv1 = uv, uv2 = uv;

    #if WIND
        uv1.x += _WindForce * 0.01;
        uv2.x = uv1.x + 0.2 * _Time.y;
    #endif
        
        float noise1 = simpleNoise(uv1, 5);
        float noise2 = simpleNoise(uv1, 33) + gradientNoise(uv2, 0.5);
        
        float4 falloffs = float4(0, 20, 1.0-_Coverage, 1.0);
        float a = smoothstep(falloffs.x, falloffs.y, noise1);
        float b = smoothstep(falloffs.z, falloffs.w, noise2 * 0.5);
        float clouds = saturation(a * b) + (240.0 - 200.0 * _Coverage)*_Opacity;
        return lerp(sky, clouds, a * b * dir.y * 50.0);
#elif WIND
        float3 tangent = cross(dir, float3(0.0, 1.0, 0.0));
        float3 bitangent = cross(tangent, dir);

        // Compute flow factor
        float2 flow = GetFlow(windDir);

        float time = _WindForce * 0.01;
        float2 alpha = frac(float2(time, time + 0.5)) - 0.5;

        float2 uv1 = alpha.x * flow;
        float2 uv2 = alpha.y * flow;

        float3 dir1 = dir + uv1.x * tangent + uv1.y * bitangent;
        float3 dir2 = dir + uv2.x * tangent + uv2.y * bitangent;

        // Sample twice
        float3 color1 = sampleCloud(dir1, sky);
        float3 color2 = sampleCloud(dir2, sky);

        // Blend color samples
        return lerp(color1, color2, abs(2.0 * alpha.x));
#elif CLOUDMAP
        return sampleCloud(dir, sky);
#else
        return sky;
#endif
    
    }

    float4 GetColorWithRotation(float3 dir, float exposure, float2 cos_sin)
    {
        dir = RotationUp(dir, cos_sin);

        float3 skyColor = GetSkyColor(dir)*_Intensity*exposure;
        skyColor = ClampToFloat16Max(skyColor);

        return float4(skyColor, 1.0);
    }

    float4 RenderSky(Varyings input, float exposure)
    {
        float3 viewDirWS = GetSkyViewDirWS(input.positionCS.xy);

        // Reverse it to point into the scene
        float3 dir = -viewDirWS;

        return GetColorWithRotation(dir, exposure, _CosSinPhi);
    }

    float3 GetScreenSpaceAmbientOcclusionForBackplate(float2 positionSS, float NdotV, float perceptualRoughness)
    {
        float indirectAmbientOcclusion = 1.0 - LOAD_TEXTURE2D_X(_AmbientOcclusionTexture, positionSS).x;
        float directAmbientOcclusion   = lerp(1.0, indirectAmbientOcclusion, _AmbientOcclusionParam.w);

        return lerp(_AmbientOcclusionParam.rgb, 1.0, directAmbientOcclusion);
    }

    float4 RenderSkyWithBackplate(Varyings input, float3 positionOnBackplate, float exposure, float3 originalDir, float blend, float depth)
    {
        // Reverse it to point into the scene
        float3 offset = RotationUp(float3(_OffsetTexX, 0, _OffsetTexY), _CosSinPhiPlate);
        float3 dir    = positionOnBackplate - float3(0, _ProjectionDistance + _GroundLevel, 0) + offset; // No need for normalization

        PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw, depth, UNITY_MATRIX_I_VP, UNITY_MATRIX_V);

        HDShadowContext shadowContext = InitShadowContext();
        float shadow;
        // Use uniform directly - The float need to be cast to uint (as unity don't support to set a uint as uniform)
        uint renderingLayers = _EnableLightLayers ? asuint(unity_RenderingLayer.x) : DEFAULT_LIGHT_LAYERS;
        float3 shadow3;
        ShadowLoopMin(shadowContext, posInput, float3(0, 1, 0), _ShadowFilter, renderingLayers, shadow3);
        shadow = dot(shadow3, float3(1.0f/3.0f, 1.0f/3.0f, 1.0f/3.0f));

        float3 shadowColor = ComputeShadowColor(shadow, _ShadowTint, 0.0f);

        float3 output = lerp(            GetColorWithRotation(originalDir,                         exposure, _CosSinPhi).rgb,
                             shadowColor*GetColorWithRotation(RotationUp(dir, _CosSinPhiPlateTex), exposure, _CosSinPhi).rgb, blend);

        float3 ao = GetScreenSpaceAmbientOcclusionForBackplate(posInput.positionSS, originalDir.z, 1.0f);

        return float4(ao*output, exposure);
    }

    float4 FragBaking(Varyings input) : SV_Target
    {
        return RenderSky(input, 1.0);
    }

    float4 FragRender(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        return RenderSky(input, GetCurrentExposureMultiplier());
    }

    float4 RenderBackplate(Varyings input, float exposure)
    {
        float3 viewDirWS = -GetSkyViewDirWS(input.positionCS.xy);
        float3 finalPos;
        float depth;
        float blend;
        if (IsBackplateHitWithBlend(finalPos, blend, viewDirWS))
        {
            depth = ComputeNormalizedDeviceCoordinatesWithZ(finalPos - _WorldSpaceCameraPos, UNITY_MATRIX_VP).z;
        }
        else
        {
            depth = UNITY_RAW_FAR_CLIP_VALUE;
        }

        float curDepth = LoadCameraDepth(input.positionCS.xy);

        if (curDepth > depth)
            discard;

        float4 results = 0; // Warning
        if (curDepth == UNITY_RAW_FAR_CLIP_VALUE)
            results = RenderSky(input, exposure);
        else if (curDepth <= depth)
            results = RenderSkyWithBackplate(input, finalPos, exposure, viewDirWS, blend, depth);

        return results;
    }

    float4 FragBakingBackplate(Varyings input) : SV_Target
    {
        return RenderBackplate(input, 1.0);
    }

    float4 FragRenderBackplate(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        return RenderBackplate(input, GetCurrentExposureMultiplier());
    }

    float GetDepthWithBackplate(Varyings input)
    {
        float3 viewDirWS = -GetSkyViewDirWS(input.positionCS.xy);
        float3 finalPos;
        float depth;
        if (IsBackplateHit(finalPos, viewDirWS))
        {
            depth = ComputeNormalizedDeviceCoordinatesWithZ(finalPos - _WorldSpaceCameraPos, UNITY_MATRIX_VP).z;
        }
        else
        {
            depth = UNITY_RAW_FAR_CLIP_VALUE;
        }

        return depth;
    }

    float FragBakingBackplateDepth(Varyings input) : SV_Depth
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        return GetDepthWithBackplate(input);
    }

    float4 FragRenderBackplateDepth(Varyings input, out float depth : SV_Depth) : SV_Target0
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        depth = GetDepthWithBackplate(input);

        PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw, depth, UNITY_MATRIX_I_VP, UNITY_MATRIX_V);

        NormalData normalData;
        normalData.normalWS            = float3(0, 1, 0);
        normalData.perceptualRoughness = 1.0f;

        float4 gbufferNormal = 0;

        if (depth != UNITY_RAW_FAR_CLIP_VALUE)
            EncodeIntoNormalBuffer(normalData, posInput.positionSS, gbufferNormal);

        return gbufferNormal;
    }

    ENDHLSL

    SubShader
    {
        // Regular HDRI Sky
        // For cubemap
        Pass
        {
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragBaking
            ENDHLSL
        }

        // For fullscreen Sky
        Pass
        {
            ZWrite Off
            ZTest LEqual
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragRender
            ENDHLSL
        }

        // HDRI Sky with Backplate
        // For cubemap with Backplate
        Pass
        {
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragBakingBackplate
            ENDHLSL
        }

        // For fullscreen Sky with Backplate
        Pass
        {
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragRenderBackplate
            ENDHLSL
        }

        // HDRI Sky with Backplate for PreRenderSky (Depth Only Pass)
        // DepthOnly For cubemap with Backplate
        Pass
        {
            ZWrite On
            ZTest LEqual
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragBakingBackplateDepth
            ENDHLSL
        }

        // DepthOnly For fullscreen Sky with Backplate
        Pass
        {
            ZWrite On
            ZTest LEqual
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment FragRenderBackplateDepth
            ENDHLSL
        }
    }
    Fallback Off
}
