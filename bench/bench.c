/* Benchmark ws_enc_write_payload() from the lib/ws.c named by WS_C.
 * Usage: bench <file for the masked output> */
#include WS_C

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define ROUNDS 7

static double now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int cmpd(const void *a, const void *b)
{
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
  static const size_t sizes[] = { 16, 125, 1000, 16384, 1 << 20 };
  static uint8_t in[1 << 20], out[1 << 20];
  CURL *data = curl_easy_init();
  struct ws_encoder enc;
  struct bufq q;
  FILE *dump;
  size_t s, i;

  if(argc != 2 || !data || !(dump = fopen(argv[1], "wb")))
    return 1;
  for(i = 0; i < sizeof(in); i++)
    in[i] = (uint8_t)(i * 131 + 7);
  memset(&enc, 0, sizeof(enc));
  memcpy(enc.mask, "\x12\x34\x56\x78", 4);
  Curl_bufq_init2(&q, 65535, 2, BUFQ_OPT_SOFT_LIMIT);

  for(s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
    size_t sz = sizes[s], total = (size_t)64 << 20, r, n, x;
    double mbs[ROUNDS];

    /* masked output for every start offset, compared by run.sh */
    for(x = 0; x < 4; x++) {
      enc.xori = (unsigned int)x;
      enc.payload_len = enc.payload_remain = (curl_off_t)sz;
      if(ws_enc_write_payload(&enc, data, in + x, sz, &q, &n) || n != sz ||
         Curl_bufq_read(&q, out, sz, &n) || n != sz)
        return 2;
      fwrite(out, 1, sz, dump);
      Curl_bufq_reset(&q);
    }

    for(i = 0; i < ROUNDS; i++) {
      double t0 = now();
      for(r = 0; r < total / sz; r++) {
        enc.payload_len = enc.payload_remain = (curl_off_t)sz;
        if(ws_enc_write_payload(&enc, data, in, sz, &q, &n) || n != sz)
          return 3;
        Curl_bufq_reset(&q);
      }
      mbs[i] = (double)total / (now() - t0) / 1e6;
    }
    qsort(mbs, ROUNDS, sizeof(mbs[0]), cmpd);
    printf("%zu %.0f\n", sz, mbs[ROUNDS / 2]);
  }
  fclose(dump);
  Curl_bufq_free(&q);
  curl_easy_cleanup(data);
  return 0;
}
