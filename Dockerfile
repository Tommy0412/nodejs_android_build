# =============================================================================
# Node.js Android ARM64 Builder  (Termux-style)
# =============================================================================
# Produces:
#   /artifacts/lib/libnode.so        ← JNI-loadable shared library
#   /artifacts/include/node/         ← Node.js public headers
#   /artifacts/include/uv/           ← libuv headers (bundled)
#   /artifacts/include/v8/           ← V8 headers
#
# Usage:
#   docker build \
#     --build-arg NODE_VERSION=24.13.0 \
#     --build-arg NDK_VERSION=r27c \
#     --build-arg ANDROID_API=24 \
#     --build-arg JOBS=8 \
#     -t node-android-builder .
#
#   # Extract artifacts
#   docker run --rm -v $(pwd)/output:/out node-android-builder \
#     cp -r /artifacts/. /out/
# =============================================================================

FROM ubuntu:22.04 AS builder

# Use bash with pipefail for all RUN steps.
# Default Docker shell is /bin/sh which does not support pipefail,
# causing `cmd | tee` to swallow non-zero exit codes from cmd.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── Build arguments ────────────────────────────────────────────────────────
ARG NODE_VERSION=24.13.0
ARG NDK_VERSION=r27c
ARG ANDROID_API=24
ARG JOBS=4

# Termux repo ref (branch/tag) to pull patches from.
# Set to a specific commit SHA for reproducibility, or "master" for latest.
ARG TERMUX_REF=master

# 16KB page alignment — required for Android 15+ devices with 16KB page size.
# Also fully backward-compatible with 4KB page devices.
# Set to 4096 to produce a classic 4KB-aligned build instead.
ARG PAGE_SIZE=16384

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_VERSION=${NODE_VERSION}
ENV NDK_VERSION=${NDK_VERSION}
ENV ANDROID_API=${ANDROID_API}
ENV JOBS=${JOBS}
ENV TERMUX_REF=${TERMUX_REF}
ENV PAGE_SIZE=${PAGE_SIZE}

# ── System dependencies ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    g++-12 \
    git \
    patch \
    perl \
    python3 \
    python3-pip \
    python-is-python3 \
    unzip \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12

# ── Android NDK ────────────────────────────────────────────────────────────
WORKDIR /opt
RUN echo "Downloading Android NDK ${NDK_VERSION}..." && \
    wget -q "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
    && unzip -q "android-ndk-${NDK_VERSION}-linux.zip" \
    && mv "android-ndk-${NDK_VERSION}" /opt/android-ndk \
    && rm "android-ndk-${NDK_VERSION}-linux.zip" \
    && echo "NDK ready at /opt/android-ndk"

# ── Toolchain env ──────────────────────────────────────────────────────────
ENV NDK_HOME=/opt/android-ndk
ENV TOOLCHAIN=${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64
ENV ANDROID_TARGET=aarch64-linux-android
ENV ANDROID_TARGET_VERSIONED=aarch64-linux-android${ANDROID_API}
ENV PATH="${TOOLCHAIN}/bin:${PATH}"

# These get picked up by Node's configure and GYP
ENV CC_target=${TOOLCHAIN}/bin/aarch64-linux-android${ANDROID_API}-clang
ENV CXX_target=${TOOLCHAIN}/bin/aarch64-linux-android${ANDROID_API}-clang++
ENV AR_target=${TOOLCHAIN}/bin/llvm-ar
ENV RANLIB_target=${TOOLCHAIN}/bin/llvm-ranlib

# ── Download Node.js source ────────────────────────────────────────────────
WORKDIR /build
RUN echo "Downloading Node.js v${NODE_VERSION}..." && \
    wget -q "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.xz" \
    && tar -xJf "node-v${NODE_VERSION}.tar.xz" \
    && mv "node-v${NODE_VERSION}" node-src \
    && rm "node-v${NODE_VERSION}.tar.xz" \
    && echo "Node.js source ready"

# ── Fetch Termux patches ───────────────────────────────────────────────────
# We try the "nodejs-lts" package first (LTS-specific patches), then fall back
# to the "nodejs" package. Both may have patches applicable to newer versions.
RUN echo "Fetching Termux patches from ${TERMUX_REF}..." && \
    mkdir -p /build/termux-patches && \
    \
    # Determine which major version we have
    NODE_MAJOR=$(echo ${NODE_VERSION} | cut -d. -f1) && \
    echo "Node.js major version: ${NODE_MAJOR}" && \
    \
    # Try nodejs-lts first
    PATCH_BASE="https://raw.githubusercontent.com/termux/termux-packages/${TERMUX_REF}/packages" && \
    for PKG in nodejs-lts nodejs; do \
        echo "Trying ${PKG}..." && \
        curl -sfL "${PATCH_BASE}/${PKG}/" \
            | grep -oP '(?<=href=")[^"]+\.patch' \
            | while read PFILE; do \
                echo "  Downloading ${PKG}/${PFILE}" && \
                curl -sfL "${PATCH_BASE}/${PKG}/${PFILE}" \
                     -o "/build/termux-patches/${PKG}-${PFILE}" || true; \
              done ; \
    done && \
    \
    # Fallback: use the GitHub API to list patch files
    for PKG in nodejs-lts nodejs; do \
        API_URL="https://api.github.com/repos/termux/termux-packages/contents/packages/${PKG}?ref=${TERMUX_REF}"; \
        curl -sfL "${API_URL}" 2>/dev/null \
            | python3 -c "import sys, json; items = json.load(sys.stdin); patches = [i['download_url'] for i in items if i['name'].endswith('.patch')]; print('\n'.join(patches))" \
            | while read URL; do \
                FNAME=$(basename "$URL"); \
                echo "  [API] Downloading ${PKG}/${FNAME}"; \
                curl -sfL "$URL" -o "/build/termux-patches/${PKG}-${FNAME}" || true; \
              done ; \
    done && \
    \
    echo "Patches downloaded:" && ls /build/termux-patches/ || echo "(none)"

# ── Apply patches ──────────────────────────────────────────────────────────
# We apply patches in order, skipping ones that don't apply cleanly
# (some patches are version-specific and may not apply to newer Node)
RUN cd /build/node-src && \
    APPLIED=0 && SKIPPED=0 && \
    for p in $(ls /build/termux-patches/*.patch 2>/dev/null | sort); do \
        echo -n "Applying $(basename $p) ... " && \
        if patch -p1 --dry-run < "$p" > /dev/null 2>&1; then \
            patch -p1 < "$p" && APPLIED=$((APPLIED+1)) && echo "OK"; \
        else \
            echo "SKIP (does not apply cleanly)" && SKIPPED=$((SKIPPED+1)); \
        fi; \
    done && \
    echo "Patches: ${APPLIED} applied, ${SKIPPED} skipped"

# ── Also apply any local patches (mounted at build time) ──────────────────
COPY patches/ /build/local-patches/
RUN cd /build/node-src && \
    for p in $(ls /build/local-patches/*.patch 2>/dev/null | sort); do \
        echo -n "Applying local $(basename $p) ... " && \
        if patch -p1 --dry-run < "$p" > /dev/null 2>&1; then \
            patch -p1 < "$p" && echo "OK"; \
        else \
            echo "SKIP"; \
        fi; \
    done

# ── Copy NDK cpu-features header into sysroot ─────────────────────────────
RUN cp "${NDK_HOME}/sources/android/cpufeatures/cpu-features.h" \
       "${TOOLCHAIN}/sysroot/usr/include/cpu-features.h"

# ── Configure Node.js for Android ARM64 ───────────────────────────────────
#
# Key flags:
#   --dest-os=android       Target Android
#   --dest-cpu=arm64        aarch64 target
#   --cross-compiling       Tell GYP it's a cross build (don't exec target binaries)
#   --shared                Build libnode.so
#   --with-intl=small-icu   Bundle minimal ICU
#   --without-npm           Not needed for embedded use
#   --without-inspector     Saves ~2MB
#   --openssl-no-asm        NDK clang lacks some OpenSSL ASM optimizations
#   --without-snapshot      THE KEY FLAG for Android cross-compilation.
#                           Skips building mksnapshot entirely. mksnapshot is a
#                           HOST binary that generates the V8 startup snapshot
#                           (a serialised heap for faster cold start). When
#                           cross-compiling for Android, mksnapshot requires
#                           host-side V8 trap handler symbols that GYP never
#                           links into the host binary, causing undefined symbol
#                           errors regardless of how many libraries we inject.
#                           Without a snapshot Node.js starts slightly slower
#                           (~50-100ms) but is functionally identical — the VM
#                           just initialises the heap from scratch instead of
#                           deserialising it. For an embedded library this is
#                           an entirely acceptable trade-off, and it's exactly
#                           what Termux uses for their Android builds.
RUN cd /build/node-src && \
    export GYP_DEFINES="target_arch=arm64 host_arch=x64 host_os=linux android_ndk_path=${NDK_HOME}" && \
    PAGE_LDFLAGS="-Wl,-z,max-page-size=${PAGE_SIZE} -Wl,-z,common-page-size=${PAGE_SIZE}" && \
    export LDFLAGS="${PAGE_LDFLAGS}" && \
    ./configure \
        --dest-os=android \
        --dest-cpu=arm64 \
        --cross-compiling \
        --shared \
        --with-intl=small-icu \
        --without-npm \
        --without-inspector \
        --without-snapshot \
        --openssl-no-asm \
        --prefix=/output \
        2>&1 | tee /build/configure.log && \
    echo "Configure done" && \
    echo "Page size flags: ${PAGE_LDFLAGS}"

# ── Build + Install ────────────────────────────────────────────────────────
RUN cd /build/node-src && \
    export GYP_DEFINES="target_arch=arm64 host_arch=x64 host_os=linux android_ndk_path=${NDK_HOME}" && \
    echo "Building Node.js (this will take a while)..." && \
    make -j${JOBS} 2>&1 | tee /build/build.log && \
    echo "Build complete!" && \
    make install

RUN mkdir -p /artifacts/lib /artifacts/include && \
    \
    echo "=== Collecting libnode.so ===" && \
    # Search multiple possible output locations
    for dir in \
        "/build/node-src/out/Release" \
        "/build/node-src/out" \
        "/output/lib"; \
    do \
        find "$dir" -maxdepth 2 -name "libnode.so*" 2>/dev/null | while read f; do \
            echo "  Found: $f" && cp "$f" /artifacts/lib/; \
        done; \
    done && \
    \
    echo "=== Collecting headers ===" && \
    # Node public headers
    [ -d /output/include/node ] && cp -r /output/include/node /artifacts/include/ || \
    [ -d /build/node-src/include/node ] && cp -r /build/node-src/include/node /artifacts/include/ && \
    \
    # libuv headers (bundled deps)
    [ -d /build/node-src/deps/uv/include ] && \
        cp -r /build/node-src/deps/uv/include /artifacts/include/uv || true && \
    \
    # V8 headers
    [ -d /build/node-src/deps/v8/include ] && \
        cp -r /build/node-src/deps/v8/include /artifacts/include/v8 || true && \
    \
    # openssl headers (sometimes needed for node embedding)
    [ -d /build/node-src/deps/openssl/openssl/include ] && \
        cp -r /build/node-src/deps/openssl/openssl/include/openssl \
              /artifacts/include/openssl || true && \
    \
    echo "=== Stripping libnode.so ===" && \
    ${TOOLCHAIN}/bin/llvm-strip --strip-unneeded \
        /artifacts/lib/libnode.so 2>/dev/null || true && \
    \
    echo "=== Final artifacts ===" && \
    ls -lh /artifacts/lib/ && \
    echo "" && echo "Headers:" && ls /artifacts/include/ && \
    \
    # Verify it's actually ARM64
    file /artifacts/lib/libnode.so 2>/dev/null || \
    ${TOOLCHAIN}/bin/llvm-readelf -h /artifacts/lib/libnode.so | grep -E "Class|Machine" && \
    \
    echo "" && echo "=== Verifying page alignment ===" && \
    # Check PT_LOAD segment alignment in the ELF program headers.
    # All LOAD segments must be aligned to PAGE_SIZE (16384 = 0x4000).
    # If any segment shows alignment < 0x4000 the build should be re-checked.
    ${TOOLCHAIN}/bin/llvm-readelf -l /artifacts/lib/libnode.so \
        | grep -E "LOAD|GNU_RELRO" && \
    echo "" && \
    ALIGN=$(${TOOLCHAIN}/bin/llvm-readelf -l /artifacts/lib/libnode.so \
        | awk '/LOAD/{print $NF}' | sort -u) && \
    echo "LOAD segment alignments: ${ALIGN}" && \
    for A in ${ALIGN}; do \
        DEC=$(printf "%d" "${A}" 2>/dev/null || echo 0) && \
        if [ "${DEC}" -lt "${PAGE_SIZE}" ] 2>/dev/null; then \
            echo "WARNING: segment alignment ${A} is less than PAGE_SIZE=${PAGE_SIZE}!" ; \
        else \
            echo "OK: alignment ${A} >= ${PAGE_SIZE}" ; \
        fi ; \
    done

# ── Runtime image ──────────────────────────────────────────────────────────
# A minimal image that just holds the artifacts for easy extraction
FROM ubuntu:22.04 AS artifacts
RUN apt-get update && apt-get install -y --no-install-recommends \
    file binutils-aarch64-linux-gnu && rm -rf /var/lib/apt/lists/*
COPY --from=builder /artifacts /artifacts
CMD ["find", "/artifacts", "-type", "f", "-ls"]
