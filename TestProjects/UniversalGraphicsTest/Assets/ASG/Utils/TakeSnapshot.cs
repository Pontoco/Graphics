using System.IO;
using System.Text;
#if UNITY_EDITOR
using UnityEditor;
#endif
using UnityEngine;
using UnityEngine.SceneManagement;

// Screen Recorder will save individual images of active scene in any resolution and of a specific image format
// including raw, jpg, png, and ppm.  Raw and PPM are the fastest image formats for saving.
//
// You can compile these images into a video using ffmpeg:
// ffmpeg -i screen_3840x2160_%d.ppm -y test.avi

public class TakeSnapshot : MonoBehaviour
{
    // configure with raw, jpg, png, or ppm (simple raw format)
    public enum Format
    {
        RAW,
        JPG,
        PNG,
        PPM
    }

    public bool CAPTURE;
    public int captureHeight = 1080;

    // commands
    private bool captureScreenshot;

    private bool captureVideo;

    // 4k = 3840 x 2160   1080p = 1920 x 1080
    public int captureWidth = 1920;
    private int counter; // image #

    public Format format = Format.PPM;

    // private vars for screenshot
    private Rect rect;
    private RenderTexture renderTexture;
    private Texture2D screenShot;

    private void OnValidate()
    {
        if (CAPTURE)
        {
            CAPTURE = false;
            TakeShot();
        }
    }

    // create a unique filename using a one-up variable
    private string uniqueFilename(int width, int height)
    {
        string folder = Path.Combine(SceneManager.GetActiveScene().path.Replace(".unity", ""), "Screenshots");

        // make sure directoroy exists
        Directory.CreateDirectory(folder);

        // count number of files of specified format in folder
        var mask = string.Format("screen_{0}x{1}*.{2}", width, height, format.ToString().ToLower());
        counter = Directory.GetFiles(folder, mask, SearchOption.TopDirectoryOnly).Length;

        // use width, height, and counter for unique file name
        var filename = Path.Combine(folder,
            string.Format("screen_{0}x{1}_{2}.{3}", width, height, counter, format.ToString().ToLower()));

        // up counter for next call
        ++counter;

        // return unique filename
        return filename;
    }

    private void Update()
    {
        // check keyboard 'k' for one time screenshot capture and holding down 'v' for continious screenshots
        captureScreenshot |= Input.GetKeyDown("k");
        captureVideo = Input.GetKey("v");

        if (captureScreenshot || captureVideo)
        {
            captureScreenshot = false;

            TakeShot();
        }
    }

    private void TakeShot()
    {
        // create screenshot objects if needed
        if (renderTexture == null)
        {
            // creates off-screen render texture that can rendered into
            rect = new Rect(0, 0, captureWidth, captureHeight);
            renderTexture = new RenderTexture(captureWidth, captureHeight, 24);
            screenShot = new Texture2D(captureWidth, captureHeight, TextureFormat.RGB24, false);
        }

        // get main camera and manually render scene into rt
        var camera = GetComponent<Camera>(); // NOTE: added because there was no reference to camera in original script; must add this script to Camera
        camera.targetTexture = renderTexture;
        camera.Render();

        // read pixels will read from the currently active render texture so make our offscreen
        // render texture active and then read the pixels
        RenderTexture.active = renderTexture;
        screenShot.ReadPixels(rect, 0, 0);

        // reset active camera texture and render texture
        camera.targetTexture = null;
        RenderTexture.active = null;

        // get our unique filename
        var filename = uniqueFilename((int) rect.width, (int) rect.height);

        // pull in our file header/data bytes for the specified image format (has to be done from main thread)
        byte[] fileHeader = null;
        byte[] fileData = null;
        if (format == Format.RAW)
        {
            fileData = screenShot.GetRawTextureData();
        }
        else if (format == Format.PNG)
        {
            fileData = screenShot.EncodeToPNG();
        }
        else if (format == Format.JPG)
        {
            fileData = screenShot.EncodeToJPG();
        }
        else // ppm
        {
            // create a file header for ppm formatted file
            var headerStr = string.Format("P6\n{0} {1}\n255\n", rect.width, rect.height);
            fileHeader = Encoding.ASCII.GetBytes(headerStr);
            fileData = screenShot.GetRawTextureData();
        }

        // create file and write optional header with image bytes
        var f = File.Create(filename);
        if (fileHeader != null) f.Write(fileHeader, 0, fileHeader.Length);
        f.Write(fileData, 0, fileData.Length);
        f.Close();
        Debug.Log(string.Format("Wrote screenshot {0} of size {1}", filename, fileData.Length));

        // cleanup if needed
        DestroyImmediate(renderTexture);
        renderTexture = null;
        screenShot = null;

#if UNITY_EDITOR
        AssetDatabase.Refresh();
#endif
    }
}
