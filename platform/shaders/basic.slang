struct VertexInput {
    float3 position : POSITION;
    float4 color    : COLOR;
    float2 uv       : TEXCOORD;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD;
    float4 color    : COLOR;
    float viewDepth : VIEWDEPTH;
};

struct CameraState {
    float4x4 view;
    float4x4 proj;
#if !defined(VULKAN) && !defined(AETHER_DEKO)
    uint fogEnabled;
    float fogStart;
    float fogEnd;
    uint _pad;
    float3 fogColor;
    uint alphaBlendEnabled;
    float2 uvOffset;
#endif
};

#if defined(VULKAN)

[[vk::binding(0, 0)]]
ConstantBuffer<CameraState> camera;

struct PushConstants {
    float4x4 model;
    uint textureIndex;
    uint fogEnabled;
    float fogStart;
    float fogEnd;
    float3 fogColor;
    uint alphaBlendEnabled;
    float2 uvOffset;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> pc;

[[vk::binding(0, 1)]]
SamplerState g_sampler;

[[vk::binding(1, 1)]]
Texture2D g_textures[];

float4x4 getModel() { return pc.model; }
float4x4 getView() { return camera.view; }
float4x4 getProj() { return camera.proj; }
uint getTextureIndex() { return pc.textureIndex; }
uint getFogEnabled() { return pc.fogEnabled; }
float getFogStart() { return pc.fogStart; }
float getFogEnd() { return pc.fogEnd; }
float3 getFogColor() { return pc.fogColor; }
uint getAlphaBlendEnabled() { return pc.alphaBlendEnabled; }
float2 getUvOffset() { return pc.uvOffset; }

#elif defined(AETHER_DEKO)

struct DrawUniform {
    float4x4 model;
    float4x4 view;
    float4x4 proj;
    uint textureIndex;
    uint fogEnabled;
    float fogStart;
    float fogEnd;
    float3 fogColor;
    uint alphaBlendEnabled;
    float2 uvOffset;
};

[[vk::binding(0, 0)]]
ConstantBuffer<DrawUniform> draw;

[[vk::binding(1, 0)]]
Sampler2D boundTexture;

float4x4 getModel() { return draw.model; }
float4x4 getView() { return draw.view; }
float4x4 getProj() { return draw.proj; }
uint getTextureIndex() { return draw.textureIndex; }
uint getFogEnabled() { return draw.fogEnabled; }
float getFogStart() { return draw.fogStart; }
float getFogEnd() { return draw.fogEnd; }
float3 getFogColor() { return draw.fogColor; }
uint getAlphaBlendEnabled() { return draw.alphaBlendEnabled; }
float2 getUvOffset() { return draw.uvOffset; }

#else

[[vk::binding(0, 0)]]
ConstantBuffer<CameraState> camera;

struct PerObject {
    float4x4 model;
};

[[vk::binding(1, 0)]]
ConstantBuffer<PerObject> perObject;

[[vk::binding(2, 0)]]
Sampler2D u_combinedTexture;

float4x4 getModel() { return perObject.model; }
float4x4 getView() { return camera.view; }
float4x4 getProj() { return camera.proj; }
uint getFogEnabled() { return camera.fogEnabled; }
float getFogStart() { return camera.fogStart; }
float getFogEnd() { return camera.fogEnd; }
float3 getFogColor() { return camera.fogColor; }
uint getAlphaBlendEnabled() { return camera.alphaBlendEnabled; }
float2 getUvOffset() { return camera.uvOffset; }

#endif

float4 sampleMaterial(float2 uv, float4 vertexColor) {
#if defined(VULKAN)
    uint textureIndex = getTextureIndex();
    if (textureIndex == 0) {
        return vertexColor;
    }
    uint idx = NonUniformResourceIndex(textureIndex);
    return g_textures[idx].Sample(g_sampler, uv) * vertexColor;
#elif defined(AETHER_DEKO)
    if (getTextureIndex() == 0) {
        return vertexColor;
    }
    return boundTexture.Sample(uv) * vertexColor;
#else
    return u_combinedTexture.Sample(uv) * vertexColor;
#endif
}

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    VertexOutput output;
    float4 viewPos = mul(getView(), mul(getModel(), float4(input.position, 1.0)));
    output.position = mul(getProj(), viewPos);
    output.viewDepth = -viewPos.z;
    output.uv = input.uv + getUvOffset();
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    float4 color = sampleMaterial(input.uv, input.color);
    if (getFogEnabled() != 0) {
        float factor = clamp((getFogEnd() - input.viewDepth) / (getFogEnd() - getFogStart()), 0.0, 1.0);
        color.rgb = lerp(getFogColor(), color.rgb, factor);
    }
    if (getAlphaBlendEnabled() == 0) {
        color.a = 1.0;
    } else {
        if (color.a <= 0.1)
            discard;
    }
    return color;
}
