#include "hlsl.h"
#include "matrices.h"

struct VS_Input {
    float3 vsCoord   : vsCoord;
    float3 vsNormal  : vsNormal;
    float2 vsTex     : vsTex;
    float  vsMatIndex: vsMatIndex;
    float4 vsWIndex  : vsWIndex;
    float4 vsWeight  : vsWeight;
    float2 aiBoneMatOffset: aiBoneMatOffset;
};

struct VS_Output {
    float4 Pos       : SV_Position;
    float3 vCoord    : vCoord;
    float3 vNorm     : vNorm;
    float2 vTex      : vTex;
    float  MatIndex  : MatIndex;
};

Texture2D BoneTransform; SamplerState BoneTransformSampler;

float4x4 GetBoneTransform(in float BoneCoord) {
    float2 TexSize;
    BoneTransform.GetDimensions(TexSize.x, TexSize.y);
    float2 PixSize = 1.0 / TexSize;
    
    float2 TexCoord;
    TexCoord.x = frac(BoneCoord / TexSize.x);
    TexCoord.y = trunc(BoneCoord / TexSize.x) / TexSize.y;
    TexCoord += 0.5 * PixSize;
    
    float4x4 m;
    m[0] = BoneTransform.SampleLevel(BoneTransformSampler, float2(TexCoord.x,                 TexCoord.y), 0);
    m[1] = BoneTransform.SampleLevel(BoneTransformSampler, float2(TexCoord.x +     PixSize.x, TexCoord.y), 0);
    m[2] = BoneTransform.SampleLevel(BoneTransformSampler, float2(TexCoord.x + 2.0*PixSize.x, TexCoord.y), 0);
    m[3] = BoneTransform.SampleLevel(BoneTransformSampler, float2(TexCoord.x + 3.0*PixSize.x, TexCoord.y), 0);
    return m;
}

float4x4 GetBoneTransform(in float4 Indices, in float4 Weights) {
    float4x4 m = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };
    float4 ind = Indices*4.0;
    if (Indices.x>=0.0) m  = GetBoneTransform(ind.x)*Weights.x;
    if (Indices.y>=0.0) m += GetBoneTransform(ind.y)*Weights.y;
    if (Indices.z>=0.0) m += GetBoneTransform(ind.z)*Weights.z;
    if (Indices.w>=0.0) m += GetBoneTransform(ind.w)*Weights.w;
    return m;
}

VS_Output VS(VS_Input In) {
    VS_Output Out;
    float4x4 mBone = GetBoneTransform(In.vsWIndex+In.aiBoneMatOffset.x, In.vsWeight);
    float3 crd = mul(float4(In.vsCoord, 1.0), mBone).xyz;
    float3 norm = mul( In.vsNormal, (float3x3) mBone );
    Out.vCoord = mul(float4(crd, 1.0), V_Matrix).xyz;
    Out.vNorm = mul(normalize(norm), (float3x3)V_Matrix);
    Out.vTex = In.vsTex;
    Out.Pos = mul(float4(Out.vCoord, 1.0), P_Matrix);
    Out.MatIndex = In.aiBoneMatOffset.y + In.vsMatIndex;
    return Out;
}

///////////////////////////////////////////////////////////////////////////////

//Texture2DArray Maps; SamplerState MapsSampler;

struct PS_Output {
    float4 Color : SV_Target0;
};

struct Material_pbr {
    float3 albedo;
    float3 f0;
    float  roughness;
};

static const float PI = 3.1415926535897932384626433832795;

float GGX_PartialGeometry(float cosThetaN, float alpha)
{
    float cosTheta_sqr = saturate(cosThetaN*cosThetaN);
    float tan2 = ( 1 - cosTheta_sqr ) / cosTheta_sqr;
    float GP = 2 / ( 1 + sqrt( 1 + alpha * alpha * tan2 ) );
    return GP;
}

float GGX_Distribution(float cosNH, float alpha)
{
    float alpha2 = alpha * alpha;
    float NH_sqr = saturate(cosNH * cosNH);
    float den = NH_sqr * alpha2 + (1.0 - NH_sqr);
    return alpha2 / ( PI * den * den );
}

float3 FresnelSchlick(float3 F0, float cosTheta) {
    return F0 + (1.0 - F0) * pow(1.0 - saturate(cosTheta), 5.0);
}

#define MaxSamplesCount 1024
float uSamplesCount;
float4 uHammersleyPts[MaxSamplesCount];

float3x3 CalcTBN(float3 vPos, float3 vNorm, float2 vTex) {
    float3 dPos1 = ddx(vPos);
    float3 dPos2 = ddy(vPos);
    float2 dTex1 = ddx(vTex);
    float2 dTex2 = ddy(vTex);
 
    float3 v2 = cross(dPos2, vNorm);
    float3 v1 = cross(vNorm, dPos1);
    float3 T = v2 * dTex1.x + v1 * dTex2.x;
    float3 B = v2 * dTex1.y + v1 * dTex2.y;
 
    float invdet = 1.0/sqrt(max( dot(T,T), dot(B,B) ));
    
    return float3x3( T * invdet, B * invdet, vNorm );
}

float3x3 GetSampleTransform(float3 Normal) {
  float3x3 w;
  float3 up = abs(Normal.y) < 0.999 ? float3(0,1,0) : float3(1,0,0);
  w[0] = normalize ( cross( up, Normal ) );
  w[1] = cross( Normal, w[0] );
  w[2] = Normal;
  return w;
}

float3 GGX_Sample(float2 E, float alpha) {
    float Phi = 2.0*PI*E.x;
    float cosThetha = saturate(sqrt( (1.0 - E.y) / (1.0 + alpha*alpha * E.y - E.y) ));
    float sinThetha = sqrt( 1.0 - cosThetha*cosThetha);
    return float3(sinThetha*cos(Phi), sinThetha*sin(Phi), cosThetha);
}

float3 CookTorrance_GGX_sample(float3 n, float3 l, float3 v, Material_pbr m, out float3 FK, out float pdf) {
    pdf = 0.0;
    FK = 0.0;
    n = normalize(n);
    v = normalize(v);
    l = normalize(l);
    float3 h = normalize(v+l);
    //precompute dots
    float NL = dot(n, l);
    if (NL <= 0.0) return 0.0;
    float NV = dot(n, v);
    if (NV <= 0.0) return 0.0;
    float NH = dot(n, h);
    float HV = dot(h, v);
    
    //precompute roughness square
    float roug_sqr = m.roughness*m.roughness;
    
    //calc coefficients
    float G = GGX_PartialGeometry(NV, roug_sqr) * GGX_PartialGeometry(NL, roug_sqr);
    float3 F = FresnelSchlick(m.f0, HV);
    FK = F;
    
    float D = GGX_Distribution(NH, roug_sqr);
    pdf = D*NH/(4.0*HV);

    float3 specK = G*F*HV/(NV*NH);
    return max(0.0, specK);
}

float3 m_albedo;
float3 m_f0;
float  m_roughness;

static const float LightInt = 1.0;

TextureCube uRadiance; SamplerState uRadianceSampler;
TextureCube uIrradiance; SamplerState uIrradianceSampler;

float ComputeLOD_AParam(){
    float w, h;
    uRadiance.GetDimensions(w, h);
    return 0.5*log2(w*h/uSamplesCount);
}

float ComputeLOD(float AParam, float pdf, float3 l) {
    float du = 2.0*1.2*(abs(l.z)+1.0);
    return max(0.0, AParam-0.5*log2(pdf*du*du)+1.0);
}

PS_Output PS(VS_Output In) {
    PS_Output Out;
    
    Material_pbr m;
    m.albedo = m_albedo;
    m.f0 = m_f0;
    m.roughness = m_roughness;

    float3 MacroNormal = normalize(In.vNorm);
    float3 ViewDir = normalize(-In.vCoord);
    
    float3x3 HTransform = GetSampleTransform(MacroNormal);
    
    float LOD_Aparam = ComputeLOD_AParam();
    
    Out.Color.rgb = 0.0;
    float3 specColor = 0.0;
    float3 FK_summ = 0.0;
    for (uint i=0; i<(uint)uSamplesCount; i++){
        float3 H = GGX_Sample(uHammersleyPts[i].xy, m.roughness*m.roughness);
        H = mul(H, HTransform);
        float3 LightDir = reflect(-ViewDir, H);

        float3 specK;
        float pdf;
        float3 FK;
        specK = CookTorrance_GGX_sample(MacroNormal, LightDir, ViewDir, m, FK, pdf);
        FK_summ += FK;
        float LOD = ComputeLOD(LOD_Aparam, pdf, LightDir);
        float3 LightColor = uRadiance.SampleLevel(uRadianceSampler, mul(LightDir.xyz, (float3x3)V_InverseMatrix), LOD).rgb*LightInt;
        specColor += specK * LightColor;
    }
    specColor /= uSamplesCount;
    FK_summ /= uSamplesCount;
    float3 LightColor = uIrradiance.Sample(uIrradianceSampler, mul(MacroNormal, (float3x3)V_InverseMatrix)).rgb;
    Out.Color.rgb = m.albedo*saturate(1.0-FK_summ)*LightColor + specColor;

    Out.Color.a = 1.0;
    return Out;
}