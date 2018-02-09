// Ring shader for Kopernicus
// by Ghassen Lahmar (blackrack)

Shader "Kopernicus/Rings"
{
	SubShader
	{
		Tags
		{
			"Queue" = "Transparent"
			"IgnoreProjector" = "True"
			"RenderType" = "Transparent"
		}

		Pass
		{
			ZWrite On
			Cull Back
			// Alpha blend
			Blend SrcAlpha OneMinusSrcAlpha

			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma glsl
			#pragma target 3.0

			#include "UnityCG.cginc"

			// These properties are the global inputs shared by all pixels

			uniform sampler2D _MainTex; uniform float4 _MainTex_ST;

			uniform float innerRadius;
			uniform float outerRadius;

			uniform float planetRadius;
			uniform float sunRadius;

			uniform float3 sunPosRelativeToPlanet;

			uniform float penumbraMultiplier;

			// Unity will set this to the material color automatically
			uniform float4 _Color;

			// Properties to simulate a shade moving past the inner surface of the ring
			uniform sampler2D _InnerShadeTexture;
			uniform int       innerShadeTiles;
			uniform float     innerShadeOffset;

			#define M_PI 3.1415926535897932384626

			//Detail fields
			uniform sampler2D _DetailTex; uniform float4 _DetailTex_ST;
			uniform float _Div1;
			uniform float _Div2;
			uniform float _Pass1;
			uniform float _Pass2;
			uniform float _CullDistance;
			uniform float _Dust;
			uniform sampler2D _DustTex; uniform float4 _DustTex_ST;
			uniform float _DivDU;
			uniform float _DivDV;
			uniform float _DustMult;
			uniform float _CullRough;
			uniform float _CullGain;
			uniform float _DustGain;
			uniform float _DustAlpha;
			uniform float _MainScaleU;
			uniform float _MainScaleV;
			uniform float _MainOffsetU;
			uniform float _MainOffsetV;

			// This structure defines the inputs for each pixel
			struct v2f
			{
				float4 pos:          SV_POSITION;
				float3 worldPos:     TEXCOORD0;
				// Moved from fragment shader
				float3 planetOrigin: TEXCOORD1;
				float2 texCoord:     TEXCOORD2;
			};

			// Set up the inputs for the fragment shader
			v2f vert(appdata_base v)
			{
				v2f o;
				o.pos = mul(UNITY_MATRIX_MVP,    v.vertex);
				o.worldPos = mul(unity_ObjectToWorld, v.vertex);
				o.planetOrigin = mul(unity_ObjectToWorld, float4(0, 0, 0, 1)).xyz;
				o.texCoord = v.texcoord;
				return o;
			}

			// Mie scattering
			// Copied from Scatterer/Proland
			float PhaseFunctionM(float mu, float mieG)
			{
				// Mie phase function
				return 1.5 * 1.0 / (4.0 * M_PI) * (1.0 - mieG * mieG) * pow(1.0 + (mieG * mieG) - 2.0 * mieG * mu, -3.0 / 2.0) * (1.0 + mu * mu) / (2.0 + mieG * mieG);
			}

			// Eclipse function from Scatterer
			// Used here to cast the planet shadow on the ring
			// Will simplify it later and keep only the necessary bits for the ring
			// Original Source:   wikibooks.org/wiki/GLSL_Programming/Unity/Soft_Shadows_of_Spheres
			float getEclipseShadow(float3 worldPos, float3 worldLightPos, float3 occluderSpherePosition, float3 occluderSphereRadius, float3 lightSourceRadius)
			{
				float3 lightDirection = float3(worldLightPos - worldPos);
				float3 lightDistance = length(lightDirection);
				lightDirection = lightDirection / lightDistance;

				// Computation of level of shadowing w
				// Occluder planet
				float3 sphereDirection = float3(occluderSpherePosition - worldPos);
				float  sphereDistance = length(sphereDirection);
				sphereDirection = sphereDirection / sphereDistance;

				float dd = lightDistance * (asin(min(1.0, length(cross(lightDirection, sphereDirection)))) - asin(min(1.0, occluderSphereRadius / sphereDistance)));

				float w = smoothstep(-1.0, 1.0, -dd / lightSourceRadius)
					* smoothstep(0.0, 0.2, dot(lightDirection, sphereDirection));

				return (1 - w);
			}

			// Check whether our shadow squares cover this pixel
			float getInnerShadeShadow(v2f i)
			{
				// The shade only slides around the ring, so we use the X tex coord.
				float2 shadeTexCoord = float2(
					i.texCoord.x,
					i.texCoord.y / innerShadeTiles + innerShadeOffset
					);
				// Check the pixel currently above the one we're rendering.
				float4 shadeColor = tex2D(_InnerShadeTexture, shadeTexCoord);
				// If the shade is solid, then it blocks the light.
				// If it's transparent, then the light goes through.
				return 1 - 0.8 * shadeColor.a;
			}

			// Either we're a sun with a ringworld and shadow squares,
			// or we're a planet orbiting a sun and casting shadows.
			// There's no middle ground. So if shadow squares are turned on,
			// disable eclipse shadows.
			float getShadow(v2f i)
			{
				if (innerShadeTiles > 0) {
					return getInnerShadeShadow(i);
				}
				else {
					// Do everything relative to planet position
					// *6000 to convert to local space, might be simpler in scaled?
					float3 worldPosRelPlanet = i.worldPos - i.planetOrigin;
					return getEclipseShadow(worldPosRelPlanet * 6000, sunPosRelativeToPlanet, 0, planetRadius, sunRadius * penumbraMultiplier);
				}
			}

			// Choose a color to use for the pixel represented by 'i'
			float4 frag(v2f i) : COLOR
			{
				// Lighting
				// Fix this for additional lights later, will be useful when I do the Planetshine update for Scatterer
				// Assuming directional light only for now
				float3 lightDir = normalize(_WorldSpaceLightPos0.xyz);

				// Instead use the viewing direction (inspired from observing space engine rings)
				// Looks more interesting than I expected
				float3 viewdir = normalize(i.worldPos - _WorldSpaceCameraPos);
				float  mu = dot(lightDir, -viewdir);
				float  dotLight = 0.5 * (mu + 1);

				// Mie scattering through rings when observed from the back
				// Needs to be negative?
				float mieG = -0.95;
				// Result too bright for some reason, the 0.03 fixes it
				float mieScattering = 0.03 * PhaseFunctionM(mu, mieG);

				// Planet shadow on ring, or inner shade shadow on inner face
				float shadow = getShadow(i);

				
				//Distances
				float RCDist = distance(i.worldPos.rgb, _WorldSpaceCameraPos); //Ring-Cam distance
				float P1_Dist = saturate((RCDist / _Pass1)); //Clamped division by pass 1 max dist
				float P2_Dist = saturate((RCDist / _Pass2)); //Clamped division by pass 2 max dist
				float PD_Dist = saturate((RCDist / _Dust)); //Clamped division by pass 3 max dist

				//UV coords
				float2 dust_UV = float2((i.texCoord.r*_DivDU), (i.texCoord.g*_DivDV));
				float2 Main_UV = float2(((_MainScaleU*i.texCoord.r) + _MainOffsetU), ((i.texCoord.g*_MainScaleV) + _MainOffsetV));

				//Textures
				float4 color = tex2D(_MainTex, TRANSFORM_TEX(Main_UV, _MainTex)); //Main tex
				float4 DP_1 = tex2D(_DetailTex, TRANSFORM_TEX((i.texCoord*_Div1), _DetailTex)); // Pass 1
				float4 DP_2 = tex2D(_DetailTex, TRANSFORM_TEX((i.texCoord*_Div2), _DetailTex)); // Pass 2
				float4 DP_D = tex2D(_DustTex, TRANSFORM_TEX(dust_UV, _DustTex)); //Pass 3

				//Processing
				float3 CPass1 = lerp(saturate((DP_1.r > 0.5 ? (1.0 - (1.0 - 2.0*(DP_1.r - 0.5))*(1.0 - color.rgb)) : (2.0*DP_1.r*color.rgb))), color.rgb, P1_Dist); //Detail pass 1
				float3 CPass2 = lerp(saturate((DP_2.r > 0.5 ? (1.0 - (1.0 - 2.0*(DP_2.r - 0.5))*(1.0 - CPass1)) : (2.0*DP_2.r*CPass1))), CPass1, P2_Dist); //Detail pass 2
				float DustTex = ((DP_D.r*_DustMult) + DP_D.r);
				float3 CPass3 = lerp((saturate((DustTex > 0.5 ? (1.0 - (1.0 - 2.0*(DustTex - 0.5))*(1.0 - CPass2)) : (2.0*DustTex*CPass2)))*_DustGain), CPass2, PD_Dist); //Detail pass 3: dust

				//Alpha processing
				float APass1 = lerp((color.a*DP_1.g), color.a, P1_Dist);
				float APass2 = lerp((APass1*DP_2.g), APass1, P2_Dist);
				float APass3 = saturate(((DP_D.g*_DustAlpha*DP_2.g) > 0.5 ? (1.0 - (1.0 - 2.0*((DP_D.g*_DustAlpha*DP_2.g) - 0.5))*(1.0 - APass2)) : (2.0*(DP_D.g*_DustAlpha*DP_2.g)*P2_Dist)));

				//Cull processing
				float Cull = saturate((((RCDist / _CullDistance)*_CullRough) + _CullGain));

				//Final processing w. distance-based cull
				float4 finalCol = float4(CPass3, lerp(0.0, lerp((APass3*APass2), APass2, PD_Dist), Cull));

				// Combine material color with texture color and shadow
				finalCol.xyz = _Color * shadow * (finalCol.xyz * dotLight + finalCol.xyz * mieScattering);

				// I'm kinda proud of this shader so far, it's short and clean
				return finalCol;
			}
			ENDCG
		}
	}
}