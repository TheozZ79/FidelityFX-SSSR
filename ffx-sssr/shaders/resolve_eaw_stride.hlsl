/**********************************************************************
Copyright (c) 2020 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

#ifndef SSR_EAW_RESOLVE
#define SSR_EAW_RESOLVE

// In:
Texture2D<SSR_NORMALS_TEXTURE_FORMAT> g_normal              : register(t0);
Texture2D<SSR_ROUGHNESS_TEXTURE_FORMAT> g_roughness         : register(t1);
Texture2D<SSR_DEPTH_TEXTURE_FORMAT> g_depth_buffer          : register(t2);
Buffer<uint> g_tile_list                                    : register(t3);
SamplerState g_linear_sampler                               : register(s0);

// Out:
RWTexture2D<float4> g_temporally_denoised_reflections       : register(u0);
RWTexture2D<float4> g_denoised_reflections                  : register(u1); // will hold the reflection colors at the end of the resolve pass. 

min16float3 LoadRadiance(int2 idx)
{
    return g_temporally_denoised_reflections.Load(int3(idx, 0)).xyz;
}

min16float LoadRoughnessValue(int2 idx)
{
    return SssrUnpackRoughness(g_roughness.Load(int3(idx, 0)));
}

min16float GetRoughnessRadiusWeight(min16float roughness_p, min16float roughness_q, min16float dist)
{
    return 1.0 - smoothstep(10 * roughness_p, 500 * roughness_p, dist);
}

// Calculates SSR color
min16float4 ResolveScreenspaceReflections(int2 did, min16float center_roughness)
{
    const min16float roughness_sigma_min = 0.001;
    const min16float roughness_sigma_max = 0.01;

    min16float3 sum = 0.0;
    min16float total_weight = 0.0;

    const int radius = 2;
    for (int dy = -radius; dy <= radius; ++dy)
    {
        for (int dx = -radius; dx <= radius; ++dx)
        {
            int2 texel_coords = did + SSR_EAW_STRIDE * int2(dx, dy);

            min16float3 radiance = LoadRadiance(texel_coords);
            min16float roughness = LoadRoughnessValue(texel_coords);

            min16float weight = GetEdgeStoppingRoughnessWeightFP16(center_roughness, roughness, roughness_sigma_min, roughness_sigma_max)
                * GetRoughnessRadiusWeight(center_roughness, roughness, length(texel_coords - did));
            sum += weight * radiance;
            total_weight += weight;
        }
    }

    sum /= max(total_weight, 0.0001);
    return min16float4(sum, 1);
}

void Resolve(int2 did)
{
    min16float3 center_radiance = LoadRadiance(did);
    min16float center_roughness = LoadRoughnessValue(did);
    if (!DoSSR(center_roughness) || IsMirrorReflection(center_roughness))
    {
        return;
    }
    g_denoised_reflections[did.xy] = ResolveScreenspaceReflections(did, center_roughness);
}

[numthreads(8, 8, 1)]
void main(uint2 group_thread_id : SV_GroupThreadID, uint group_id : SV_GroupID)
{
    uint packed_base_coords = g_tile_list[group_id];
    uint2 base_coords = Unpack(packed_base_coords);
    uint2 coords = base_coords + group_thread_id;
    Resolve((int2)coords);
}

#endif // SSR_EAW_RESOLVE