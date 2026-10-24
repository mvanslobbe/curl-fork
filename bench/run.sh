#!/bin/sh
# Compare './perf respheaders' in curl master and with the PR change
# applied. Both trees are built the same way, at -O2, and run alternately
# so runner noise hits both alike.
set -eu

BASE=${BASE:-178e5077b6}                   # curl master the PR is based on
CC=${CC:-cc}
ROUNDS=${ROUNDS:-9}
LOOPS=${LOOPS:-50000}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$HERE/work-$(basename "$CC")}

mkdir -p "$W"
cd "$W"

for v in master pr; do
  if [ ! -d "src-$v" ]; then
    curl -fsSL "https://codeload.github.com/curl/curl/tar.gz/$BASE" | tar xz
    mv "curl-$BASE"* "src-$v"
  fi
done
[ -f src-pr/.patched ] ||
  { patch -s -d src-pr -p1 < "$HERE/verify-header.patch" && touch src-pr/.patched; }

cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || true
[ -n "$cpu" ] ||
  cpu=$(sed -n 's/^model name[^:]*: *//p' /proc/cpuinfo 2>/dev/null | head -n 1)
[ -n "$cpu" ] ||
  cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n 1)
echo "$($CC --version | head -n 1), $(uname -sm), ${cpu:-unknown CPU}"

# static libcurl, no TLS or compression: plain HTTP/1.1 is all the test uses
for v in master pr; do
  if [ ! -x "build-$v/tests/perf/perf" ]; then
    cmake -S "src-$v" -B "build-$v" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=ON \
      -DCURL_ENABLE_SSL=OFF -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF \
      -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF \
      -DCURL_USE_LIBSSH2=OFF -DCURL_DISABLE_LDAP=ON >/dev/null
    cmake --build "build-$v" --target perf -j4 >/dev/null
  fi
done

: > res.txt
# one untimed run each to warm up caches and CPU clocks
for v in master pr; do
  "build-$v/tests/perf/perf" respheaders 1000 >/dev/null
done
r=0
while [ "$r" -lt "$ROUNDS" ]; do
  for v in master pr; do
    "build-$v/tests/perf/perf" respheaders "$LOOPS" |
      awk -v v="$v" '/ns\/loop/ { print v, $1, $(NF - 1) }' >> res.txt
  done
  r=$((r + 1))
done

# median ns/loop of each response and version
med() {
  awk -v v="$1" -v t="$2" '$1 == v && $2 == t { print $3 }' res.txt |
    sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'
}

echo
echo "median of $ROUNDS rounds, $LOOPS loops"
echo
echo "| response | master | PR | change |"
echo "|---|---|---|---|"
for t in small:5 typical:26 many:200; do
  a=$(med master "${t%:*}")
  b=$(med pr "${t%:*}")
  echo "$t $a $b" | awk '{ split($1, n, ":");
    printf "| %s headers | %.2f µs | %.2f µs | %+.1f%% |\n",
      n[2], $2 / 1000, $3 / 1000, ($3 - $2) * 100 / $2 }'
done
