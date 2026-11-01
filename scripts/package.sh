#!/bin/sh
# Builds and packages every release target: scripts/package.sh VERSION OUTDIR
#
# Each archive, firetower-<os>-<arch>.tar.gz, unpacks to a folder that
# install.sh recognises as a release (a VERSION file and build/firetower), so
# the installer inside it installs that binary rather than building one.
# SHA256SUMS covers every archive; VERSION says which release this is. The release workflow runs this; so can you.
set -eu
version=${1:?usage: scripts/package.sh VERSION OUTDIR}
out=${2:?usage: scripts/package.sh VERSION OUTDIR}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for target in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
  os=${target%/*} arch=${target#*/}
  name=firetower-$os-$arch
  dir=$work/$name
  mkdir -p "$dir/build"
  (cd "$root" && CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath \
    -ldflags "-s -w -X main.version=$version" -o "$dir/build/firetower" ./cmd/firetower)
  cp -R "$root/agents" "$root/examples" "$dir/"
  cp "$root/install.sh" "$root/LICENSE" "$root/README.md" "$dir/"
  mkdir -p "$dir/docs" && cp "$root/docs/design.md" "$dir/docs/"
  echo "$version" >"$dir/VERSION"
  tar -C "$work" -czf "$out/$name.tar.gz" "$name"
  echo "packaged $name.tar.gz"
done
# The latest release's version, one small file: what `firetower upgrade
# --check` asks for.
echo "$version" >"$out/VERSION"
(cd "$out" && { if command -v sha256sum >/dev/null 2>&1; then sha256sum firetower-*.tar.gz; else shasum -a 256 firetower-*.tar.gz; fi; } >SHA256SUMS)
echo "wrote $out/SHA256SUMS"
