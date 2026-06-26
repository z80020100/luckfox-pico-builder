# check=skip=FromPlatformFlagConstDisallowed
# Native arm64 cross-toolchain builder for arm-rockchip830-linux-uclibcgnueabihf (ARMv7 uClibc).
# Rebuilds the vendor toolchain with crosstool-NG on an aarch64 host so the compiler
# runs native (no x86-64 emulation).
# No gcc-multilib: it only lets an x86-64 host run 32-bit x86 tools; native arm64 never needs it.
FROM --platform=linux/arm64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# crosstool-NG build deps plus the deps it needs to build the target toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gawk bison flex texinfo help2man gperf \
        libtool libtool-bin automake autoconf \
        libncurses-dev \
        python3 python3-dev \
        wget curl git ca-certificates \
        rsync unzip bzip2 xz-utils patch file \
    && rm -rf /var/lib/apt/lists/*

# Build and install crosstool-NG from source. Pinned to 1.24.0 to match the
# vendor toolchain's component versions (gcc 8.3.0, binutils 2.32, uClibc-ng
# 1.0.31, gdb 8.2.1 — all crosstool-NG 1.24.0 defaults), so the restored vendor
# .config rebuilds the same versions with no migration drift.
ARG CTNG_VERSION=1.24.0
RUN mkdir -p /opt/ctng-dl \
    && wget -q -P /opt/ctng-dl "https://github.com/crosstool-ng/crosstool-ng/releases/download/crosstool-ng-${CTNG_VERSION}/crosstool-ng-${CTNG_VERSION}.tar.xz" \
    && echo "804ced838ea7fe3fac1e82f0061269de940c82b05d0de672e7d424af98f22d2d  /opt/ctng-dl/crosstool-ng-${CTNG_VERSION}.tar.xz" | sha256sum -c - \
    && tar -xf "/opt/ctng-dl/crosstool-ng-${CTNG_VERSION}.tar.xz" -C /opt/ctng-dl \
    && cd "/opt/ctng-dl/crosstool-ng-${CTNG_VERSION}" \
    && ./configure --prefix=/opt/ctng \
    && make -j"$(nproc)" \
    && make install \
    && cd / && rm -rf "/opt/ctng-dl/crosstool-ng-${CTNG_VERSION}" "/opt/ctng-dl/crosstool-ng-${CTNG_VERSION}.tar.xz"
ENV PATH=/opt/ctng/bin:$PATH

# Pre-stage the three sources crosstool-NG won't fetch on its own. ct-ng
# downloads and checksums everything else (gcc, binutils, uClibc, ...) at build
# time, but not these three. linux and isl are pinned as custom-location tarballs
# that ct-ng treats as user-supplied — it neither fetches nor checksums them — yet
# reproducing the vendor toolchain needs these exact versions. expat is here
# because ct-ng's own fetch fails on the vendor's dead SourceForge URL.
# These are fixed build inputs — like crosstool-NG itself — so bake them into the
# image with sha256: the only integrity check linux/isl ever get (expat is
# re-verified by ct-ng against its built-in digest). They live in /opt/ctng-dl
# rather than /workspace (shadowed by a runtime volume mount); the build script
# links them into the work tree where ct-ng looks.
RUN wget -q -O /opt/ctng-dl/expat-2.2.6.tar.bz2 "https://github.com/libexpat/libexpat/releases/download/R_2_2_6/expat-2.2.6.tar.bz2" \
    && wget -q -O /opt/ctng-dl/linux-5.10.66.tar.xz "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.66.tar.xz" \
    && wget -q -O /opt/ctng-dl/isl-0.24.tar.xz "https://libisl.sourceforge.io/isl-0.24.tar.xz" \
    && echo "17b43c2716d521369f82fc2dc70f359860e90fa440bea65b3b85f0b246ea81f2  /opt/ctng-dl/expat-2.2.6.tar.bz2" | sha256sum -c - \
    && echo "5dfa06bbbbd164b9ea669ec637b1e6d05fb5fea8ef3aeb6729f2cbcd0dfcc8a7  /opt/ctng-dl/linux-5.10.66.tar.xz" | sha256sum -c - \
    && echo "043105cc544f416b48736fff8caf077fb0663a717d06b1113f16e391ac99ebad  /opt/ctng-dl/isl-0.24.tar.xz" | sha256sum -c -

# crosstool-NG refuses to run as root. Create an unprivileged build user; the
# build script drops to it after fixing up mount ownership.
RUN useradd -m -s /bin/bash builder

WORKDIR /workspace
CMD ["/bin/bash"]
