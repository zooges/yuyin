#ifndef YUYIN_BZIP2_H
#define YUYIN_BZIP2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Incremental bzip2 decoder (constant memory, any archive size).
typedef struct yuyin_bz2_stream yuyin_bz2_stream;

yuyin_bz2_stream *yuyin_bz2_open(void);

/// Decodes from `in` into `out`.
/// Returns 0 = progress (call again / feed more), 1 = end of a bzip2 stream,
/// -1 = corrupt data or internal error.
int yuyin_bz2_decompress(
    yuyin_bz2_stream *stream,
    const uint8_t *in,
    size_t in_len,
    size_t *in_consumed,
    uint8_t *out,
    size_t out_cap,
    size_t *out_produced
);

/// Prepares for a concatenated stream (pbzip2 archives).
int yuyin_bz2_reset(yuyin_bz2_stream *stream);

void yuyin_bz2_close(yuyin_bz2_stream *stream);

#ifdef __cplusplus
}
#endif

#endif
