#!/bin/sh
# Builds the x86_64 Linux client in a Fedora container. Output: linux/dist/ubiquitas
# Fedora 43: a binary linked against an older glibc/GTK also runs on newer ones (Bazzite tracks current Fedora).
set -e
cd "$(dirname "$0")"

docker build --platform linux/amd64 -t ubiquitas-build - <<'EOF'
FROM fedora:43
RUN dnf install -y gcc cargo gtk4-devel && dnf clean all
EOF

# registry and target dir live in volumes, so rebuilds are incremental and don't mix with the Mac's target/
docker run --rm --platform linux/amd64 \
    -v "$PWD":/src -w /src \
    -v ubiquitas-cargo:/root/.cargo -v ubiquitas-target:/target -e CARGO_TARGET_DIR=/target \
    ubiquitas-build sh -c 'cargo build --release && mkdir -p dist && cp /target/release/ubiquitas dist/'

echo "built $(pwd)/dist/ubiquitas"
