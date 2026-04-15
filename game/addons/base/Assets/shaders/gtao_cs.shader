// Why do we need this at all in a compute shader
MODES
{ 
    Default();
    Forward();
}

CS 
{
    #include "common.fxc"
    #include "postprocess/shared.hlsl"

    #include "common\classes\Depth.hlsl"
    #include "common\classes\Motion.hlsl"
    #include "common\classes\Normals.hlsl"
    
    #include "common\thirdparty\XeGTAO.h"
    #include "common\thirdparty\XeGTAO.hlsl"


    //-------------------------------------------------------------------------------------------------------------------

    cbuffer GTAOConstants
    {
        GTAOConstants g_GTAOConsts;
    };

    //-------------------------------------------------------------------------------------------------------------------

    // input output textures for the first pass (XeGTAO_PrefilterDepths16x16)
#if ( D_PASS == 0)
    Texture2DMS<float>           g_srcRawDepth           < Attribute("RawDepth"); > ;           // source depth buffer data (in NDC space in DirectX)
    RWTexture2D<float>           g_outWorkingDepthMIP0   < Attribute("WorkingDepthMIP0"); > ;   // output viewspace depth MIP (these are views into g_srcWorkingDepth MIP levels)
    RWTexture2D<float>           g_outWorkingDepthMIP1   < Attribute("WorkingDepthMIP1"); > ;   // output viewspace depth MIP (these are views into g_srcWorkingDepth MIP levels)
    RWTexture2D<float>           g_outWorkingDepthMIP2   < Attribute("WorkingDepthMIP2"); > ;   // output viewspace depth MIP (these are views into g_srcWorkingDepth MIP levels)
    RWTexture2D<float>           g_outWorkingDepthMIP3   < Attribute("WorkingDepthMIP3"); > ;   // output viewspace depth MIP (these are views into g_srcWorkingDepth MIP levels)
    RWTexture2D<float>           g_outWorkingDepthMIP4   < Attribute("WorkingDepthMIP4"); > ;   // output viewspace depth MIP (these are views into g_srcWorkingDepth MIP levels)
    #endif

    // input output textures for the second pass (XeGTAO_MainPass)
    Texture2D<float>             g_srcWorkingDepth       < Attribute("WorkingDepth"); > ;       // viewspace depth with MIPs, output by XeGTAO_PrefilterDepths16x16 and consumed by XeGTAO_MainPass
    RWTexture2D<float>           g_outWorkingAOTerm      < Attribute("WorkingAOTerm"); > ;      // output AO term (includes bent normals if enabled - packed as R11G11B10 scaled by AO)
    RWTexture2D<float>           g_outWorkingEdges       < Attribute("WorkingEdges"); > ;       // output depth-based edges used by the denoiser

    // input output textures for the third pass
    Texture2D                    g_srcWorkingAOTerm      < Attribute("WorkingAOTerm"); > ;    // coming from previous pass
    Texture2D<float>             g_srcWorkingEdges       < Attribute("WorkingEdges"); > ; // coming from previous pass
    RWTexture2D<float>           g_outAO                 < Attribute("FinalAOTerm"); >;         // final AO term - just 'visibility' or 'visibility + bent normals'
    Texture2D                    g_prevAO                < Attribute("FinalAOTermPrev"); >;

    SamplerState                PointClamp               < Filter( POINT ); AddressU( CLAMP ); AddressV( CLAMP ); AddressW( CLAMP ); >;
    SamplerState                BilinearClamp            < Filter( MIN_MAG_MIP_LINEAR ); AddressU( CLAMP ); AddressV( CLAMP ); AddressW( CLAMP ); >;

    //-------------------------------------------------------------------------------------------------------------------

    enum GTAOPasses
    {
        ViewDepthChain,    // XeGTAO depth filter seems to do average depth, maybe we can do DepthMax + DepthMin from our existing depth chain and average that, removing this pass
        MainPass,
        DenoiseSpatial,
        DenoiseTemporal
    };

    DynamicCombo( D_PASS, 0..3, Sys( All ) );
    DynamicCombo( D_QUALITY, 0..2, Sys( All ) );

    //-------------------------------------------------------------------------------------------------------------------

    // These are defined by viewport, CommandList API doesn't expose changing parameters per-viewport so we do it here for now
    GTAOConstants GetConstants()
    {
        GTAOConstants consts = g_GTAOConsts;

        consts.ViewportSize = g_vViewportSize.xy;
		consts.ViewportPixelSize = g_vInvViewportSize.xy;

		float depthLinearizeMul = ( g_flFarPlane * g_flNearPlane ) / ( g_flFarPlane - g_flNearPlane );
		float depthLinearizeAdd = g_flFarPlane / ( g_flFarPlane - g_flNearPlane );

		consts.DepthUnpackConsts = float2( depthLinearizeMul, depthLinearizeAdd );

		consts.CameraTanHalfFOV = float2( 1.0f / g_matViewToProjection[0][0], 1.0f / g_matViewToProjection[1][1] );

		consts.NDCToViewMul = float2( consts.CameraTanHalfFOV.x * 2.0f, consts.CameraTanHalfFOV.y * -2.0f );
		consts.NDCToViewAdd = float2( consts.CameraTanHalfFOV.x * -1.0f, consts.CameraTanHalfFOV.y * 1.0f );

		consts.NDCToViewMul_x_PixelSize = float2( consts.NDCToViewMul.x * consts.ViewportPixelSize.x, consts.NDCToViewMul.y * consts.ViewportPixelSize.y );

        return consts;
    }

    //-------------------------------------------------------------------------------------------------------------------
    lpfloat3 LoadNormal( int2 pos )
    {
        lpfloat3 viewnormal = (lpfloat3)Vector3WsToVs( Normals::Sample( pos ) );
        viewnormal.z = -viewnormal.z;

        return viewnormal;
    }
    
    //-------------------------------------------------------------------------------------------------------------------
    
    [numthreads( 8, 8, 1 )]
    void MainCs( uint2 vDispatchId : SV_DispatchThreadID, uint2 vGroupThreadID : SV_GroupThreadID )
    {
        GTAOConstants sGTAOConsts = GetConstants();

        if (D_PASS == GTAOPasses::ViewDepthChain )
        {
            
            #if( D_PASS == 0 )
                // Write view-space depth MIPs
                XeGTAO_PrefilterDepths16x16(vDispatchId, vGroupThreadID, sGTAOConsts, g_tDepthChain, PointClamp, g_outWorkingDepthMIP0, g_outWorkingDepthMIP1, g_outWorkingDepthMIP2, g_outWorkingDepthMIP3, g_outWorkingDepthMIP4 );
            #endif
        }
        else if (D_PASS == GTAOPasses::MainPass )
        {
            // Hilbert R2 quasi-random sequence for spatiotemporal noise (better than blue noise for this use case)
            // See: https://www.shadertoy.com/view/3tB3z3, https://github.com/GameTechDev/XeGTAO
            uint hilbertIndex = HilbertIndex( vDispatchId.x, vDispatchId.y );
            hilbertIndex += 288 * ( sGTAOConsts.NoiseIndex % 64 ); // 288 found empirically for best results with XE_HILBERT_LEVEL 6
            const lpfloat2 localNoise = lpfloat2( frac( 0.5 + hilbertIndex * float2( 0.75487766624669276005, 0.5698402909980532659114 ) ) );
            const lpfloat3 viewspaceNormal = LoadNormal( vDispatchId.xy );

            lpfloat sliceCount;
            lpfloat stepsPerSlice;

            // Sample counts matched to reference XeGTAO implementation
            // Lower counts are compensated by better noise (Hilbert R2) and temporal denoising
            if (D_QUALITY == 0) 
            {
                sliceCount = 1; // Low quality
                stepsPerSlice = 2;
            } 
            else if (D_QUALITY == 1) 
            {
                sliceCount = 2; // Medium quality
                stepsPerSlice = 2;
            }
            else if (D_QUALITY == 2) 
            {
                sliceCount = 3; // High quality
                stepsPerSlice = 3;
            }

            XeGTAO_MainPass
            (
                vDispatchId,
                sliceCount,
                stepsPerSlice,
                localNoise,
                viewspaceNormal,
                sGTAOConsts,
                g_srcWorkingDepth,
                PointClamp,
                g_outWorkingAOTerm,
                g_outWorkingEdges
            );
        }
        else if (D_PASS == GTAOPasses::DenoiseSpatial )
        {
            // Each thread processes 2 horizontal pixels (XeGTAO optimization: shared gather reads)
            // Dispatch must be at half-width to match
            const uint2 pixCoordBase = vDispatchId * uint2( 2, 1 );
            
            // Early out here, no good way to have a non uniform size dispatch yet
            if( pixCoordBase.x >= sGTAOConsts.ViewportSize.x || pixCoordBase.y >= sGTAOConsts.ViewportSize.y )
                return;

            lpfloat2 aoTerms = XeGTAO_Denoise
            (
                pixCoordBase,       // const uint2 pixCoordBase
                sGTAOConsts,        // const GTAOConstants consts
                g_srcWorkingAOTerm, // Texture2D sourceAOTerm
                g_srcWorkingEdges,  // Texture2D<lpfloat> sourceEdges
                BilinearClamp          // SamplerState texSampler
            );

            g_outAO[pixCoordBase]                = aoTerms.x;
            g_outAO[pixCoordBase + uint2(1, 0)]  = aoTerms.y;
        }
        else if( D_PASS == GTAOPasses::DenoiseTemporal )
        {
            float taaBlendAmount = sGTAOConsts.TAABlendAmount;
            if( g_srcWorkingEdges[ vDispatchId ] < 0.5 )
            {
                taaBlendAmount *= 0.5; // reduce blending for non-edge pixels to preserve more details
            }

            g_outAO[vDispatchId] = Motion::TemporalFilter( vDispatchId.xy, g_srcWorkingAOTerm, g_prevAO, taaBlendAmount ).r;
        }
    }
}