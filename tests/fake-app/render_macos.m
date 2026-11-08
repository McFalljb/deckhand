// The fake app's drawing (tests/fake-app/fake_app.odin): no shaders. A
// render pass clears the slot to the background, then a blit copies a
// solid-colour buffer into each box. Metal only; no window, no sokol.

#import <Metal/Metal.h>
#include <stdint.h>
#include <unistd.h>

void* fake_queue(void* device) {
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    return (void*)CFBridgingRetain([d newCommandQueue]);
}

typedef struct { int x, y, w, h; uint32_t rgb; } fake_box;

// A buffer of w*h pixels of one colour (BGRA), cached by size and colour.
static id<MTLBuffer> solid(id<MTLDevice> d, int w, int h, uint32_t rgb) {
    static NSMutableDictionary<NSString*, id<MTLBuffer>>* cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString* k = [NSString stringWithFormat:@"%d-%d-%06x", w, h, rgb];
    id<MTLBuffer> b = cache[k];
    if (b) return b;
    b = [d newBufferWithLength:(NSUInteger)w * h * 4 options:MTLResourceStorageModeShared];
    uint8_t* p = b.contents;
    for (int i = 0; i < w * h; i++) {
        p[i * 4 + 0] = rgb & 0xFF;
        p[i * 4 + 1] = (rgb >> 8) & 0xFF;
        p[i * 4 + 2] = (rgb >> 16) & 0xFF;
        p[i * 4 + 3] = 0xFF;
    }
    if (cache.count > 64) [cache removeAllObjects];
    cache[k] = b;
    return b;
}

// One frame into texture (w x h px): background bg, then the boxes (px,
// clipped). Commits; the caller then presents (dh_frames_present).
void fake_render(void* queue, void* texture, int w, int h, uint32_t bg, const fake_box* boxes, int n, int slow_ms) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(((bg >> 16) & 0xFF) / 255.0, ((bg >> 8) & 0xFF) / 255.0, (bg & 0xFF) / 255.0, 1);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    for (int i = 0; i < n; i++) {
        fake_box b = boxes[i];
        int x0 = b.x < 0 ? 0 : b.x, y0 = b.y < 0 ? 0 : b.y;
        int x1 = b.x + b.w > w ? w : b.x + b.w, y1 = b.y + b.h > h ? h : b.y + b.h;
        if (x1 <= x0 || y1 <= y0) continue;
        int bw = x1 - x0, bh = y1 - y0;
        id<MTLBuffer> src = solid(q.device, bw, bh, b.rgb);
        [bl copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:(NSUInteger)bw * 4 sourceBytesPerImage:(NSUInteger)bw * bh * 4 sourceSize:MTLSizeMake(bw, bh, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x0, y0, 0)];
    }
    [bl endEncoding];
    if (slow_ms > 0) usleep((useconds_t)slow_ms * 1000);
    [cb commit];
}
