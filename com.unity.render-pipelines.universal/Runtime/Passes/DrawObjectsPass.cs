using System.Collections.Generic;
using UnityEngine.Assertions;

namespace UnityEngine.Rendering.Universal.Internal
{
    /// <summary>
    /// Draw  objects into the given color and depth target
    ///
    /// You can use this pass to render objects that have a material and/or shader
    /// with the pass names UniversalForward or SRPDefaultUnlit.
    /// </summary>
    public class DrawObjectsPass : ScriptableRenderPass
    {
        FilteringSettings m_FilteringSettings;
        RenderStateBlock m_RenderStateBlock;
        List<ShaderTagId> m_ShaderTagIdList = new List<ShaderTagId>();
        string m_ProfilerTag;
        ProfilingSampler m_ProfilingSampler;
        bool m_IsOpaque;

        // (ASG) Adding color grading to forward pass
        int m_lutParamsProp = Shader.PropertyToID("_Lut_Params");
        int m_userLutParamsProp = Shader.PropertyToID("_UserLut_Params");
        int m_userLutProp = Shader.PropertyToID("_UserLut");
        int m_internalLutProp = Shader.PropertyToID("_InternalLut");
        RenderTargetHandle m_internalLut;
        ColorLookup m_ColorLookup;
        ColorAdjustments m_ColorAdjustments;
        Tonemapping m_Tonemapping;
        bool m_doColorTransform = false; // whether this pass should do color grading / tonemapping

        public DrawObjectsPass(string profilerTag, bool opaque, RenderPassEvent evt, RenderQueueRange renderQueueRange, LayerMask layerMask, StencilState stencilState, int stencilReference)
        {
            m_ProfilerTag = profilerTag;
            m_ProfilingSampler = new ProfilingSampler(profilerTag);
            m_ShaderTagIdList.Add(new ShaderTagId("UniversalForward"));
            m_ShaderTagIdList.Add(new ShaderTagId("LightweightForward"));
            m_ShaderTagIdList.Add(new ShaderTagId("SRPDefaultUnlit"));
            renderPassEvent = evt;
            m_FilteringSettings = new FilteringSettings(renderQueueRange, layerMask);
            m_RenderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);
            m_IsOpaque = opaque;

            if (stencilState.enabled)
            {
                m_RenderStateBlock.stencilReference = stencilReference;
                m_RenderStateBlock.mask = RenderStateMask.Stencil;
                m_RenderStateBlock.stencilState = stencilState;
            }
        }

        // Sets up the pass to queue up without doing the color transform
        public void Setup()
        {
            m_doColorTransform = false;
        }

        // Sets up the pass to queue up with the color transform
        public void Setup(in RenderTargetHandle internalLut, bool generatedLutTexture)
        {
            m_doColorTransform = generatedLutTexture;

            m_internalLut = internalLut;
            var stack = VolumeManager.instance.stack;
            m_ColorLookup = stack.GetComponent<ColorLookup>();
            m_ColorAdjustments = stack.GetComponent<ColorAdjustments>();
            m_Tonemapping = stack.GetComponent<Tonemapping>();
        }

        /// <inheritdoc/>
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get(m_ProfilerTag);
            using (new ProfilingScope(cmd, m_ProfilingSampler))
            {
                // (ASG) Feed the color grading and tonemapping information into the shader
                if (UniversalRenderPipeline.asset.colorTransformation == ColorTransformation.InForwardPass &&
                    m_doColorTransform)
                {
                    cmd.EnableShaderKeyword("_COLOR_TRANSFORM_IN_FORWARD");

                    // Post exposure is controlled non-linearly for better artistic control.
                    ref var postProcessingData = ref renderingData.postProcessingData;

                    int lutHeight = postProcessingData.lutSize;
                    int lutWidth = lutHeight * lutHeight;
                    float postExposureLinear = Mathf.Pow(2f, m_ColorAdjustments.postExposure.value);
                    cmd.SetGlobalTexture(m_internalLutProp, m_internalLut.Identifier());
                    cmd.SetGlobalVector(m_lutParamsProp,
                        new Vector4(1f / lutWidth, 1f / lutHeight, lutHeight - 1f, postExposureLinear));

                    if (m_ColorLookup.IsActive())
                    {
                        cmd.SetGlobalTexture(m_userLutProp, m_ColorLookup.texture.value);
                        cmd.SetGlobalVector(m_userLutParamsProp, new Vector4(1, 0, 0, 1));
                    }

                    // (ASG) Note: in HDR grading mode, tonemapping is done via the LUT, so no keywords are set.
                    if (postProcessingData.gradingMode == ColorGradingMode.HighDynamicRange)
                    {
                        cmd.EnableShaderKeyword(ShaderKeywordStrings.HDRGrading);
                    }
                    else
                    {
                        cmd.DisableShaderKeyword(ShaderKeywordStrings.HDRGrading);
                        switch (m_Tonemapping.mode.value)
                        {
                            case TonemappingMode.Neutral:
                                cmd.DisableShaderKeyword(ShaderKeywordStrings.TonemapACES);
                                cmd.EnableShaderKeyword(ShaderKeywordStrings.TonemapNeutral);
                                break;
                            case TonemappingMode.ACES:
                                cmd.DisableShaderKeyword(ShaderKeywordStrings.TonemapNeutral);
                                cmd.EnableShaderKeyword(ShaderKeywordStrings.TonemapACES);
                                break;
                            default:  // None
                                cmd.DisableShaderKeyword(ShaderKeywordStrings.TonemapNeutral);
                                cmd.DisableShaderKeyword(ShaderKeywordStrings.TonemapACES);
                                break;
                        }
                    }
                }
                else
                {
                    cmd.DisableShaderKeyword("_COLOR_TRANSFORM_IN_FORWARD");
                }

                context.ExecuteCommandBuffer(cmd);
                cmd.Clear();

                Camera camera = renderingData.cameraData.camera;
                var sortFlags = (m_IsOpaque) ? renderingData.cameraData.defaultOpaqueSortFlags : SortingCriteria.CommonTransparent;
                var drawSettings = CreateDrawingSettings(m_ShaderTagIdList, ref renderingData, sortFlags);
                context.DrawRenderers(renderingData.cullResults, ref drawSettings, ref m_FilteringSettings, ref m_RenderStateBlock);

                // Render objects that did not match any shader pass with error shader
                RenderingUtils.RenderObjectsWithError(context, ref renderingData.cullResults, camera, m_FilteringSettings, SortingCriteria.None);
            }
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
    }
}
