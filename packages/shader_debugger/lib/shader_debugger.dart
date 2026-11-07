/// Debug-only runtime for the Flutter shader debugger.
///
/// Wrap fragment shaders in [DebugShader]. In debug mode it records their
/// uniforms, and while the DevTools extension shows a heatmap it draws the
/// instrumented probe in their place; it also reads the probe's exact value
/// at a pixel. [ShaderDebugger] answers the
/// extension's `ext.shader_debugger.*` service extensions.
///
/// Depending on this package is also what makes DevTools offer the Shader
/// Debugger extension: the built extension ships in `extension/devtools/`.
library;

export 'src/debug_shader.dart'
    show
        DebugImageSampler,
        DebugShader,
        DebugUniformFloat,
        DebugUniformVec2,
        DebugUniformVec3,
        DebugUniformVec4;
export 'src/shader_debugger.dart'
    show
        HeatmapState,
        PixelReading,
        ProbeRejection,
        ShaderDebugger,
        UniformRejection;
