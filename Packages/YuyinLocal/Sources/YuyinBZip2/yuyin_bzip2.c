#include "yuyin_bzip2.h"

#include <bzlib.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

struct yuyin_bz2_stream {
    bz_stream bz;
    int open;
};

yuyin_bz2_stream *yuyin_bz2_open(void) {
    yuyin_bz2_stream *s = calloc(1, sizeof(yuyin_bz2_stream));
    if (!s) return NULL;
    if (BZ2_bzDecompressInit(&s->bz, 0, 0) != BZ_OK) {
        free(s);
        return NULL;
    }
    s->open = 1;
    return s;
}

int yuyin_bz2_decompress(
    yuyin_bz2_stream *s,
    const uint8_t *in,
    size_t in_len,
    size_t *in_consumed,
    uint8_t *out,
    size_t out_cap,
    size_t *out_produced
) {
    *in_consumed = 0;
    *out_produced = 0;
    if (!s || !s->open) return -1;

    unsigned int in_chunk = in_len > UINT_MAX ? UINT_MAX : (unsigned int)in_len;
    unsigned int out_chunk = out_cap > UINT_MAX ? UINT_MAX : (unsigned int)out_cap;
    s->bz.next_in = (char *)in;
    s->bz.avail_in = in_chunk;
    s->bz.next_out = (char *)out;
    s->bz.avail_out = out_chunk;

    int status = BZ2_bzDecompress(&s->bz);
    *in_consumed = in_chunk - s->bz.avail_in;
    *out_produced = out_chunk - s->bz.avail_out;

    if (status == BZ_OK) return 0;
    if (status == BZ_STREAM_END) return 1;
    return -1;
}

int yuyin_bz2_reset(yuyin_bz2_stream *s) {
    if (!s) return -1;
    if (s->open) BZ2_bzDecompressEnd(&s->bz);
    memset(&s->bz, 0, sizeof(bz_stream));
    s->open = BZ2_bzDecompressInit(&s->bz, 0, 0) == BZ_OK;
    return s->open ? 0 : -1;
}

void yuyin_bz2_close(yuyin_bz2_stream *s) {
    if (!s) return;
    if (s->open) BZ2_bzDecompressEnd(&s->bz);
    free(s);
}
