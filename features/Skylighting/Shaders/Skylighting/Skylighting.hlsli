#include "Common/Math.hlsli"
#include "Common/Random.hlsli"
#include "Common/SharedData.hlsli"
#include "Common/Spherical Harmonics/SphericalHarmonics.hlsli"

namespace Skylighting
{
#ifdef PSHADER
	Texture3D<sh2> SkylightingProbeArray : register(t50);
#endif

	const static uint3 ARRAY_DIM = uint3(256, 256, 128);
	const static float3 ARRAY_SIZE = 4096.f * 3.f * float3(1, 1, 0.5);
	const static float3 CELL_SIZE = ARRAY_SIZE / ARRAY_DIM;

	float getFadeOutFactor(float3 positionMS)
	{
		float3 uvw = saturate(positionMS / ARRAY_SIZE + .5);
		float3 dists = min(uvw, 1 - uvw);
		float edgeDist = min(dists.x, min(dists.y, dists.z));
		return saturate(edgeDist * 20);
	}

	float mixDiffuse(SharedData::SkylightingSettings params, float visibility)
	{
		return lerp(params.MinDiffuseVisibility, 1.0, saturate(visibility));
	}

	float mixSpecular(SharedData::SkylightingSettings params, float visibility)
	{
		return lerp(params.MinSpecularVisibility, 1.0, saturate(visibility));
	}

	sh2 sample(SharedData::SkylightingSettings params, Texture3D<sh2> probeArray, float3 positionMS, float3 normalWS)
	{
		const static sh2 unitSH = float4(sqrt(4 * Math::PI), 0, 0, 0);
		sh2 scaledUnitSH = unitSH / 1e-10;

		float3 positionMSAdjusted = positionMS - params.PosOffset.xyz;
		float3 uvw = positionMSAdjusted / ARRAY_SIZE + .5;

		if (any(uvw < 0) || any(uvw > 1))
			return scaledUnitSH;

		float3 cellVxCoord = uvw * ARRAY_DIM;
		int3 cell000 = floor(cellVxCoord - 0.5);
		float3 trilinearPos = cellVxCoord - 0.5 - cell000;

		sh2 sum = 0;
		float wsum = 0;
		[unroll] for (int i = 0; i < 2; i++)
			[unroll] for (int j = 0; j < 2; j++)
				[unroll] for (int k = 0; k < 2; k++)
		{
			int3 offset = int3(i, j, k);
			int3 cellID = cell000 + offset;

			if (any(cellID < 0) || any((uint3)cellID >= ARRAY_DIM))
				continue;

			float3 cellCentreMS = cellID + 0.5 - ARRAY_DIM / 2;
			cellCentreMS = cellCentreMS * CELL_SIZE;

			// https://handmade.network/p/75/monter/blog/p/7288-engine_work__global_illumination_with_irradiance_probes
			// basic tangent checks
			float tangentWeight = dot(normalize(cellCentreMS - positionMSAdjusted), normalWS);
			if (tangentWeight <= 0.0)
				continue;
			tangentWeight = sqrt(tangentWeight);

			float3 trilinearWeights = 1 - abs(offset - trilinearPos);
			float w = trilinearWeights.x * trilinearWeights.y * trilinearWeights.z * tangentWeight;

			uint3 cellTexID = (cellID + params.ArrayOrigin.xyz) % ARRAY_DIM;
			sh2 probe = SphericalHarmonics::Scale(probeArray[cellTexID], w);

			sum = SphericalHarmonics::Add(sum, probe);
			wsum += w;
		}

		return SphericalHarmonics::Scale(sum, rcp(wsum + 1e-10));
	}

	float getVL(SharedData::SkylightingSettings params, Texture3D<sh2> probeArray, float3 startPosWS, float3 endPosWS, float2 pxCoord)
	{
		const static uint nSteps = 16;
		const static float step = 1.0 / float(nSteps);

		float3 worldDir = endPosWS - startPosWS;
		float3 worldDirNormalised = normalize(worldDir);

		float noise = Random::InterleavedGradientNoise(pxCoord, SharedData::FrameCount);

		float vl = 0;

		for (uint i = 0; i < nSteps; ++i) {
			float t = saturate(i * step);

			float shadow = 0;
			{
				float3 samplePositionWS = startPosWS + worldDir * t;

				sh2 skylighting = Skylighting::sample(params, probeArray, samplePositionWS, float3(0, 0, 1));

				shadow += Skylighting::mixDiffuse(params, SphericalHarmonics::Unproject(skylighting, worldDirNormalised));
			}
			vl += shadow;
		}
		return vl * step;
	}
}
