#!/bin/sh
# Compare ws_enc_write_payload() in curl master and in the PR branch.
# Both ws.c files are compiled into the same bench.c and linked to the
# same libcurl, built from the master commit, at -O2 (or each level in OPTS).
set -eu

BASE=${BASE:-ffca9f6375}                   # curl master the PR is based on
HEAD=${HEAD:-2f8c036b24}                   # PR head
FORK=${FORK:-mvanslobbe/curl-fork}
CC=${CC:-cc}
OPTS=${OPTS:--O2}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$HERE/work-$(basename "$CC")}

mkdir -p "$W"
cd "$W"

if [ ! -d src ]; then
  curl -fsSL "https://codeload.github.com/curl/curl/tar.gz/$BASE" | tar xz
  mv "curl-$BASE"* src
fi
curl -fsSL -o ws_master.c "https://raw.githubusercontent.com/curl/curl/$BASE/lib/ws.c"
curl -fsSL -o ws_pr.c "https://raw.githubusercontent.com/$FORK/$HEAD/lib/ws.c"

cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || true
[ -n "$cpu" ] ||
  cpu=$(sed -n 's/^model name[^:]*: *//p' /proc/cpuinfo 2>/dev/null | head -n 1)
[ -n "$cpu" ] ||
  cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n 1)
echo "$($CC --version | head -n 1), $(uname -sm), ${cpu:-unknown CPU}"

for opt in $OPTS; do
  b=build$opt

  # libcurl at BASE, static, no TLS or compression: only bufq and friends
  # are needed. Built with the same compiler and level as the benchmark,
  # as the old code calls into bufq per byte.
  if [ ! -f "$b/lib/libcurl.a" ]; then
    cmake -S src -B "$b" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS_RELEASE="$opt -DNDEBUG" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
      -DCURL_ENABLE_SSL=OFF -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF \
      -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF \
      -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON >/dev/null
    cmake --build "$b" -j4 >/dev/null
  fi

  LIBS=$(sed -n 's/^Libs.private: *//p' "$b/libcurl.pc")
  for v in master pr; do
    $CC $opt -DNDEBUG -DWS_C="\"ws_$v.c\"" -DHAVE_CONFIG_H \
      -DBUILDING_LIBCURL -Isrc/include -Isrc/lib -I"$b/lib" -I. \
      "$HERE/bench.c" "$b/lib/libcurl.a" $LIBS -o "bench_$v$opt"
    "./bench_$v$opt" "out_$v$opt.bin" > "res_$v$opt.txt"
  done

  cmp "out_master$opt.bin" "out_pr$opt.bin"
  echo
  echo "$opt, masked output identical"
  echo
  echo "| frame size | master | PR | speed-up |"
  echo "|---|---|---|---|"
  paste "res_master$opt.txt" "res_pr$opt.txt" | while read -r sz a _ b; do
    echo "| $sz B | $a MB/s | $b MB/s | $(echo "$b $a" | awk '{printf "%.0fx", $1 / $2}') |"
  done
done
