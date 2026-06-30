# check=skip=FromPlatformFlagConstDisallowed
# Native arm64 build environment for the Luckfox Pico (RV1106) — no x86 emulation.
# Pairs with the native arm64 toolchain and host-tool builds.

FROM --platform=linux/arm64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# SDK build dependencies from the Luckfox wiki, minus gcc-multilib/g++-multilib
# (x86-only packages with no arm64 build; a native arm64 toolchain needs neither).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ssh make gcc g++ gawk texinfo libssl-dev bison flex fakeroot \
        cmake unzip gperf autoconf device-tree-compiler libncurses5-dev \
        pkg-config bc python-is-python3 python3 passwd openssl \
        openssh-client file cpio rsync curl wget ca-certificates expect \
        xz-utils lzop bzip2 gzip patch perl \
    && rm -rf /var/lib/apt/lists/*

# arm64 builds of the host tools the SDK ships only as x86-64 prebuilts under
# sysdrv/tools/pc/*; the build step overlays them onto the SDK clone.
RUN apt-get update && apt-get install -y --no-install-recommends \
        e2fsprogs squashfs-tools mtd-utils genromfs erofs-utils u-boot-tools \
        lz4 mtools dosfstools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["/bin/bash"]
