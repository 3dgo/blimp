module view;

import "utils";
import "common";

// The view's camera and screen: between scene pixels, NDC, view space and world space, through gFrame's view
// matrix and inverse projection (so perspective and ortho cameras alike). Reversed-Z: depth 1 is the near plane,
// 0 the far one and the clear (nothing drawn).

// The scene target is the display size / sceneScale rounded up, so the display covers only its top-left
// sceneCover part. The scene VS squeezes clip space into that part (left and top edges fixed): the image lines
// up with the display pixel for pixel, and the projection stays the display's (picking, debug lines).
public float4 scene_cover_clip(float4 clip) {
    float2 cover = gFrame.sceneCover;
    clip.x = clip.x * cover.x + (cover.x - 1) * clip.w;
    clip.y = clip.y * cover.y + (1 - cover.y) * clip.w;
    return clip;
}

// Scene pixel px's centre as the projection's NDC: scene_cover_clip undone. Reads no texture, so any pass at the
// scene size can use it, the scene pass too (the sky), where the depth texture is the bound depth target.
public float2 scene_ndc(uint2 px) {
    float2 uv  = (float2(px) + 0.5) / gFrame.sceneSize;
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float2 cover = gFrame.sceneCover;
    return float2((ndc.x - (cover.x - 1)) / cover.x, (ndc.y - (1 - cover.y)) / cover.y);
}

// Scene pixel px's depth; 0 where nothing was drawn. Blended surfaces don't write depth.
public float scene_depth(uint2 px) {
    return getTexture2dF1(gFrame.depthTextureSlot).Load(int3(px, 0));
}

// NDC and depth → view space. Not at depth 0 with an infinite projection: that divides by zero.
public float3 view_pos(float2 ndc, float depth) {
    float4 v = mul(float4(ndc, depth, 1), gFrame.invProj);
    return v.xyz / v.w;
}

// View space → world space directions: the view matrix is rigid, so its inverse rotation is its transpose.
public float3 world_dir(float3 v) {
    float3x3 R = float3x3(gFrame.viewMat[0].xyz, gFrame.viewMat[1].xyz, gFrame.viewMat[2].xyz);
    return mul(R, v);
}

// View space → world space points: the eye is the view space origin.
public float3 world_pos(float3 v) {
    return gFrame.cameraPos + world_dir(v);
}

// The world position of what scene pixel px shows, false where nothing was drawn.
public bool scene_world_pos(uint2 px, out float3 pos) {
    float depth = scene_depth(px);
    pos = depth == 0 ? 0 : world_pos(view_pos(scene_ndc(px), depth));
    return depth != 0;
}

// Unit direction from world point pos to the view's eye.
public float3 view_dir(float3 pos) {
    return normalize(gFrame.cameraPos - pos);
}

public static const float VIEW_RAY_MISS = 1e6;   // the length of a ray that hit nothing, metres

public struct ViewRay {
    public float3 origin;   // world space, on the near plane
    public float3 dir;
    public float  len;      // metres to the scene surface; VIEW_RAY_MISS where nothing was drawn
}

// The world direction of the ray through ndc (scene_ndc): two points on it in view space, the near plane and
// depth 0.5, rotated into world space. Perspective and ortho alike (ortho: the same for every pixel).
public float3 view_ray_dir(float2 ndc) {
    return normalize(world_dir(view_pos(ndc, 0.5) - view_pos(ndc, 1)));
}

// Scene pixel px's ray, from the near plane to the scene depth.
public ViewRay view_ray(uint2 px) {
    float2 ndc   = scene_ndc(px);
    float3 nearV = view_pos(ndc, 1);
    float  depth = scene_depth(px);
    ViewRay r;
    r.origin = world_pos(nearV);
    r.dir    = view_ray_dir(ndc);
    r.len    = depth == 0 ? VIEW_RAY_MISS : length(view_pos(ndc, depth) - nearV);
    return r;
}
