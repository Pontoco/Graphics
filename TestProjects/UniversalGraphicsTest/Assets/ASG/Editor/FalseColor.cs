using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace Scenes._256_ASG_SubsurfaceScattering.Editor
{
    [CreateAssetMenu(fileName = "ShadingModes", menuName = "ASG/Shading Modes")]
    public class ShadingModes : ScriptableObject
    {
        public bool UseFalseColor;

        private void OnValidate()
        {
            if (UseFalseColor)
            {
                Shader.EnableKeyword("DEBUG_FALSE_COLOR");
            }
            else
            {
                Shader.DisableKeyword("DEBUG_FALSE_COLOR");
            }

            // If using false color, disable post processing volume on all cameras
            // Note: You'll have to revert this in git. I'm not aware of a way to disable it globally.
            // Note: This is a best effort, and might not work in all cases.
            foreach (var camera in Camera.allCameras)
            {
                camera.GetComponent<Volume>().enabled = false;
            }
        }
    }
}
