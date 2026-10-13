#include "VoiceDraftGzip.h"
#include <zlib.h>
int vd_gunzip(const unsigned char *source, size_t length, unsigned char *output, size_t *outputLength) {
    if (length > 2000000 || *outputLength > 2000000) return -1;
    z_stream stream = {0};
    stream.next_in = (Bytef *)source; stream.avail_in = (uInt)length;
    stream.next_out = output; stream.avail_out = (uInt)*outputLength;
    if (inflateInit2(&stream, 15 + 16) != Z_OK) return -1;
    int status = inflate(&stream, Z_FINISH);
    *outputLength = stream.total_out;
    int complete = status == Z_STREAM_END && stream.avail_in == 0;
    inflateEnd(&stream); return complete ? 0 : -1;
}
