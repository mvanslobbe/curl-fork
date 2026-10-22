# ws_enc_write_payload() benchmark

Compares `ws_enc_write_payload()` from curl master with the version in
curl/curl#23567. `bench/run.sh` downloads both copies of `lib/ws.c`,
includes each one into the same `bench/bench.c`, links both against the
same libcurl built from the master commit, checks that the masked output
is identical and prints the median of 7 rounds per frame size.

Run it locally with `./bench/run.sh` (needs curl, cmake and a C compiler).

## AI disclosure

This benchmark was written with the help of Claude Code. I reviewed and
ran it myself.
