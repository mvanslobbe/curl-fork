#!/bin/sh
# Compare './perf wssend' before and after the WebSocket mask pool change.
# Both trees are built the same way, at -O2 with OpenSSL, and run
# alternately so runner noise hits both alike.
set -eu

BASE=${BASE:-d5e35fab68}                   # PR's first commit: the test only
HEAD=${HEAD:-9498a221d5}                   # PR head: the test and the fix
FORK=${FORK:-mvanslobbe/curl-fork}
CC=${CC:-cc}
ROUNDS=${ROUNDS:-9}
LOOPS=${LOOPS:-200000}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$HERE/work-$(basename "$CC")}

mkdir -p "$W"
cd "$W"

fetch() { # repo commit dir
  if [ ! -d "$3" ]; then
    mkdir "$3"
    curl -fsSL "https://codeload.github.com/$1/tar.gz/$2" |
      tar xz -C "$3" --strip-components=1
  fi
}
fetch "$FORK" "$BASE" src-before
fetch "$FORK" "$HEAD" src-after
echo "before $BASE, after $HEAD ($FORK)"

cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || true
[ -n "$cpu" ] ||
  cpu=$(sed -n 's/^model name[^:]*: *//p' /proc/cpuinfo 2>/dev/null | head -n 1)
[ -n "$cpu" ] ||
  cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n 1)
echo "$($CC --version | head -n 1), $(uname -sm), ${cpu:-unknown CPU}"

ossl=
if command -v brew >/dev/null; then
  ossl="-DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3)"
fi

# static libcurl with OpenSSL, which provides the random bytes
for v in before after; do
  if [ ! -x "build-$v/tests/perf/perf" ]; then
    # shellcheck disable=SC2086
    cmake -S "src-$v" -B "build-$v" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=ON \
      -DCURL_USE_OPENSSL=ON $ossl -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF \
      -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF \
      -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON >/dev/null
    cmake --build "build-$v" --target perf -j4 >/dev/null
  fi
done
for v in before after; do
  grep -q '^#define USE_OPENSSL 1' "build-$v/lib/curl_config.h" ||
    { echo "build-$v is not using OpenSSL" >&2; exit 1; }
done

: > res.txt
# one untimed run each to warm up caches and CPU clocks
for v in before after; do
  "build-$v/tests/perf/perf" wssend 2000 >/dev/null
done
r=0
while [ "$r" -lt "$ROUNDS" ]; do
  for v in before after; do
    "build-$v/tests/perf/perf" wssend "$LOOPS" |
      awk -v v="$v" '/ns\/frame/ { print v, $1, $(NF - 3) }' >> res.txt
  done
  r=$((r + 1))
done

# median ns/frame of each frame size and version
med() {
  awk -v v="$1" -v t="$2" '$1 == v && $2 == t { print $3 }' res.txt |
    sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'
}

echo
echo "median of $ROUNDS rounds, $LOOPS frames ($((LOOPS / 16)) at 16384 bytes)"
echo
echo "| payload | before | after | change |"
echo "|---|---|---|---|"
for t in 16 125 1024 16384; do
  a=$(med before "$t")
  b=$(med after "$t")
  echo "$t $a $b" | awk '{
    printf "| %s bytes | %.0f ns | %.0f ns | %+.1f%% |\n",
      $1, $2, $3, ($3 - $2) * 100 / $2 }'
done
