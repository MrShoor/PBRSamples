#include "hlsl.h"

struct VS_Input {
    float2 vsCoord : vsCoord;
};

struct VS_Output {
    float4 Pos      : SV_Position;
    float2 TexCoord : TexCoord;
};

float2 FBOFlip;

VS_Output VS (VS_Input In) {
    VS_Output Out;
    Out.Pos = float4(In.vsCoord, 0.0, 1.0);
    Out.TexCoord = (In.vsCoord*FBOFlip*float2(1.0,-1.0) + 1.0) * 0.5;
    return Out;
}

///////////////////////////////////////////////////////////////

struct PS_Output {
    float4 Color: SV_Target0;
};

Texture2D uColor; SamplerState uColorSampler;

PS_Output PS (VS_Output In) {
    PS_Output Out;
    Out.Color = uColor.Sample(uColorSampler, In.TexCoord);
    if (Out.Color.a > 0)
        Out.Color /= Out.Color.a;
    else
        Out.Color = 0.0;
    return Out;
}