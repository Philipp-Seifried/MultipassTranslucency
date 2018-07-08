/*
Copyright 2018 Philipp Seifried

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated 
documentation files (the "Software"), to deal in the Software without restriction, including without limitation 
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, 
and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions 
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED 
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
DEALINGS IN THE SOFTWARE.
*/


/*
Proof of concept for a multipass approach to translucency/subsurface-scattering, which avoids reading back
the depth buffer, by encoding z values in the alpha channel and using blend operations to calculate thickness
and mask out the backlit first pass.
This needs at least a 16-bit alpha channel, so it requires HDR rendering.
*/

Shader "Custom/MultipassSS" {
	Properties {
		_Color ("Color", Color) = (1,1,1,1)
		_SSColor ("Translucent Tint", Color) = (1,1,1,1)
		_MainTex ("Albedo (RGB)", 2D) = "white" {}
		_Glossiness("Smoothness", Range(0,1)) = 0.5
		_Metallic("Metallic", Range(0,1)) = 0.0
		_Attenuation("Attenuation", Float) = 2
	}
	
	SubShader {
		/*
		-------------------------------------------------------------------------------------
		Pass 1: draw backfacing geometry
		
		This draws with culled frontfaces, and fills the alpha channel with the z-distance in
		the camera's view space, relative to the object's origin. The _Attenuation multiplier is 
		used to scale z-values in this pass and the next, so that the distance between front- and 
		backfaces is scaled up.
		You can change the lighting for backfaces freely, as long as culling, blending and
		alpha output stay the same. I used a simple lambert surface shader here and squared the result
		for a more pronounced effect where backfaces catch a lot of light.
		*/
		
		Tags { "RenderType"="Opaque" }
		LOD 200
		Cull Front
		Blend Off

		CGPROGRAM
		#pragma surface surf Lambert noshadow vertex:vert finalcolor:finalColor keepalpha // Note the keepalpha pragma.

		sampler2D _MainTex;
		float4 _SSColor;
		float _Attenuation;

		struct Input {
			float2 uv_MainTex;
			float cameraSpaceZ;
		};

		void vert(inout appdata_full v, out Input o) {
			UNITY_INITIALIZE_OUTPUT(Input, o);
			float3 camToObjectOrigin = UnityObjectToViewPos(float3(0.0, 0.0, 0.0));
			float3 camToVertex = UnityObjectToViewPos(v.vertex);
			o.cameraSpaceZ = (camToVertex.z - camToObjectOrigin.z) * _Attenuation;
		}
		
		void surf(Input IN, inout SurfaceOutput o) {
			o.Albedo = tex2D(_MainTex, IN.uv_MainTex).rgb * _SSColor;
			float z = IN.cameraSpaceZ;
			o.Alpha = z;
		}

		void finalColor(Input IN, SurfaceOutput o, inout float4 color)
		{
			color.rgb = pow(color.rgb, 2);
		}
		ENDCG
		
		/*
		-------------------------------------------------------------------------------------
		Pass 2: draw frontfacing geometry to calculate and store thickness in alpha.
		
		We again store the relative z-coordinates in alpha, this time for the front-facing geometry.
		"BlendOp Add, Sub" and "Blend Zero One, One One" sets DstAlpha to source Z minus destination Z, while
		leaving DstColor unchanged.
		*/

		Tags{ "RenderType" = "Opaque" }

		LOD 200
		Cull Back
		BlendOp Add, Sub
		Blend Zero One, One One

		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#include "UnityCG.cginc"
			
			float _Attenuation;
			
			struct appdata
			{
				float4 vertex : POSITION;
			};

			struct v2f
			{
				float4 vertex : SV_POSITION;
				float cameraSpaceZ : TEXCOORD0;
			};

			v2f vert (appdata v)
			{
				v2f o;
				o.vertex = UnityObjectToClipPos(v.vertex);
				
				float3 camToObjectOrigin = UnityObjectToViewPos(float3(0.0, 0.0, 0.0));
				float3 camToVertex = UnityObjectToViewPos(v.vertex);
				o.cameraSpaceZ = (camToVertex.z - camToObjectOrigin.z) * _Attenuation;

				return o;
			}
			
			float4 frag (v2f i) : SV_Target
			{
				return float4(0,0,0,i.cameraSpaceZ);
			}
			ENDCG
		}

		
		/*
		-------------------------------------------------------------------------------------
		Pass 3: Darken destination based on thickness
		
		This pass takes the destination color and multiplies it with OneMinusDstAlpha, in effect darkening the existing fragments
		where z-differences are high. Where DstAlpha > 1, this will produce negative color values, which we clip in the pass after this one.
		*/

		Tags{ "RenderType" = "Opaque" }

		LOD 200
		Cull Back
		BlendOp Add
		Blend Zero OneMinusDstAlpha, One Zero

		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#include "UnityCG.cginc"

			struct appdata
			{
				float4 vertex : POSITION;
			};

			struct v2f
			{
				float4 vertex : SV_POSITION;
			};

			v2f vert (appdata v)
			{
				v2f o;
				o.vertex = UnityObjectToClipPos(v.vertex);
				return o;
			}
			
			float4 frag (v2f i) : SV_Target
			{
				return float4(0,0,0,1);
			}
			ENDCG
		}

		/*
		-------------------------------------------------------------------------------------
		Pass 4: clip color values to >= 0
		
		This pass ensures that DstColor values are at least 0.
		*/

		Tags{ "RenderType" = "Opaque" }

		LOD 200
		Cull Back
		BlendOp Max
		Blend One One
		
		Pass
		{
			CGPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#include "UnityCG.cginc"

			struct appdata
			{
				float4 vertex : POSITION;
			};

			struct v2f
			{
				float4 vertex : SV_POSITION;
			};

			v2f vert (appdata v)
			{
				v2f o;
				o.vertex = UnityObjectToClipPos(v.vertex);
				return o;
			}
			
			float4 frag (v2f i) : SV_Target
			{
				return float4(0,0,0,1);
			}
			ENDCG
		}

		/*
		-------------------------------------------------------------------------------------
		Pass 5: This pass adds the final front facing color and lighting.
		
		You can plug any surface (or frag) shader in here, provided that the blend operations stay the same.
		*/

		Tags{ "RenderType" = "Opaque" }

		LOD 200
		Cull Back
		BlendOp Add
		Blend One One, One Zero // add color, overwrite alpha with this shader's output.

		CGPROGRAM
		// Physically based Standard lighting model, and enable shadows on all light types
		#pragma surface surf Standard fullforwardshadows 

		// Use shader model 3.0 target, to get nicer looking lighting
		#pragma target 3.0

		sampler2D _MainTex;

		struct Input {
			float2 uv_MainTex;
		};

		half _Glossiness;
		half _Metallic;
		fixed4 _Color;

		void surf(Input IN, inout SurfaceOutputStandard o) {
			float4 c = tex2D(_MainTex, IN.uv_MainTex)*_Color;
			o.Albedo = c.rgb;
			o.Metallic = _Metallic;
			o.Smoothness = _Glossiness;
			o.Alpha = c.a;
		}
		ENDCG
		
	}
	FallBack "Diffuse"
}
