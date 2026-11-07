// Image decoding for Quick Look: stb_image (vendored, public domain) behind a tiny
// C API Zig calls. Decodes to RGBA8 and box-downscales anything larger than
// `max_dim` on its longest side, so a 50-megapixel photo becomes a few MB of texture
// instead of 200. Runs on the preview loader thread; only the GL upload (below)
// runs on the render thread.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_FAILURE_USERMSG
#include "stb_image.h"

#include <GL/gl.h>
#include <stdint.h>
#include <stdlib.h>

static unsigned char *downscale(unsigned char *src, int w, int h, int max_dim, int *ow, int *oh) {
    int longest = w > h ? w : h;
    if (max_dim <= 0 || longest <= max_dim) {
        *ow = w;
        *oh = h;
        return src;
    }
    int nw = (int)((long long)w * max_dim / longest);
    int nh = (int)((long long)h * max_dim / longest);
    if (nw < 1) nw = 1;
    if (nh < 1) nh = 1;
    unsigned char *dst = (unsigned char *)malloc((size_t)nw * nh * 4);
    if (!dst) {
        *ow = w;
        *oh = h;
        return src;
    }
    // Box filter: average every source pixel that falls in each destination pixel.
    for (int y = 0; y < nh; y++) {
        int y0 = (int)((long long)y * h / nh), y1 = (int)((long long)(y + 1) * h / nh);
        if (y1 <= y0) y1 = y0 + 1;
        for (int x = 0; x < nw; x++) {
            int x0 = (int)((long long)x * w / nw), x1 = (int)((long long)(x + 1) * w / nw);
            if (x1 <= x0) x1 = x0 + 1;
            unsigned long sum[4] = {0, 0, 0, 0};
            unsigned long n = 0;
            for (int sy = y0; sy < y1; sy++) {
                const unsigned char *row = src + ((size_t)sy * w + x0) * 4;
                for (int sx = x0; sx < x1; sx++, row += 4) {
                    sum[0] += row[0];
                    sum[1] += row[1];
                    sum[2] += row[2];
                    sum[3] += row[3];
                    n++;
                }
            }
            unsigned char *d = dst + ((size_t)y * nw + x) * 4;
            for (int k = 0; k < 4; k++) d[k] = (unsigned char)(sum[k] / n);
        }
    }
    stbi_image_free(src);
    *ow = nw;
    *oh = nh;
    return dst;
}

// zfd_image_load decodes the file at `path` (NULL on failure). Free with zfd_image_free.
unsigned char *zfd_image_load(const char *path, int max_dim, int *w, int *h) {
    int iw, ih, comp;
    unsigned char *px = stbi_load(path, &iw, &ih, &comp, 4);
    if (!px) return NULL;
    return downscale(px, iw, ih, max_dim, w, h);
}

// zfd_image_load_mem decodes an encoded image held in memory (PNG from pdftoppm/ffmpeg).
unsigned char *zfd_image_load_mem(const unsigned char *buf, int len, int max_dim, int *w, int *h) {
    int iw, ih, comp;
    unsigned char *px = stbi_load_from_memory(buf, len, &iw, &ih, &comp, 4);
    if (!px) return NULL;
    return downscale(px, iw, ih, max_dim, w, h);
}

// zfd_image_orient turns/mirrors RGBA pixels as EXIF orientation `o` (2..8) says, so
// they show upright; returns the new buffer (the old one is freed) and its size.
unsigned char *zfd_image_orient(unsigned char *src, int w, int h, int o, int *ow, int *oh) {
    if (o < 2 || o > 8) {
        *ow = w;
        *oh = h;
        return src;
    }
    int swap = o >= 5;
    int nw = swap ? h : w, nh = swap ? w : h;
    unsigned char *dst = (unsigned char *)malloc((size_t)w * h * 4);
    if (!dst) {
        *ow = w;
        *oh = h;
        return src;
    }
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int dx, dy; // where source (x, y) lands
            switch (o) {
            case 2: dx = w - 1 - x; dy = y; break;             // mirrored
            case 3: dx = w - 1 - x; dy = h - 1 - y; break;     // 180
            case 4: dx = x; dy = h - 1 - y; break;             // flipped
            case 5: dx = y; dy = x; break;                     // transposed
            case 6: dx = h - 1 - y; dy = x; break;             // 90 clockwise
            case 7: dx = h - 1 - y; dy = w - 1 - x; break;     // transversed
            default: dx = y; dy = w - 1 - x; break;            // 8: 270 clockwise
            }
            const unsigned char *sp = src + ((size_t)y * w + x) * 4;
            unsigned char *dp = dst + ((size_t)dy * nw + dx) * 4;
            dp[0] = sp[0];
            dp[1] = sp[1];
            dp[2] = sp[2];
            dp[3] = sp[3];
        }
    }
    free(src);
    *ow = nw;
    *oh = nh;
    return dst;
}

// zfd_image_size reads an image's size from its header, without decoding it (0 if
// it isn't an image stb reads).
int zfd_image_size(const char *path, int *w, int *h) {
    int comp;
    return stbi_info(path, w, h, &comp);
}

// zfd_image_size_mem is zfd_image_size for an image already in memory (one inside
// an archive, read in place).
int zfd_image_size_mem(const unsigned char *buf, int len, int *w, int *h) {
    int comp;
    return stbi_info_from_memory(buf, len, w, h, &comp);
}

// Both stbi's buffers and ours come from malloc (stb's default allocator).
void zfd_image_free(unsigned char *px) { free(px); }

// zfd_texture_upload makes an RGBA8 GL texture (linear filtering). Render thread.
unsigned int zfd_texture_upload(const unsigned char *px, int w, int h) {
    GLuint tex = 0;
    GLint prev = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glBindTexture(GL_TEXTURE_2D, (GLuint)prev);
    return tex;
}

void zfd_texture_free(unsigned int tex) {
    GLuint t = tex;
    if (t) glDeleteTextures(1, &t);
}
