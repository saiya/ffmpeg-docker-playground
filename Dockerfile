FROM ubuntu:22.04

ENV DEBIAN_FRONTEND noninteractive
# Don't update bootloader: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=594189
ENV INITRD No
ENV LANG en_US.UTF-8

RUN echo 'force-unsafe-io' >> /etc/dpkg/dpkg.cfg.d/02apt-speedup && \
    apt-get update && \
    apt-get -y install curl && \
    apt-get install -y --no-install-recommends apt-utils && \
    apt-get -y install \
      python3 \
      git-core bash emacs-nox \
      build-essential autoconf libtool pkg-config meson ninja-build cmake cmake-curses-gui yasm nasm gperf \
      zlib1g-dev libbz2-dev liblzma-dev \
      libpng-dev libjpeg-dev libtiff-dev libgif-dev librsvg2-dev \
      libssl-dev \
      libexpat1-dev \
      uuid-dev \
      file locales \
    && \
    locale-gen $(bash -c 'echo ${LANG%.*}') ${LANG} && \
    apt-get clean && \
    rm -r /var/lib/apt/lists/*

# Use bash because I want to use pipefail in this build.
SHELL ["/bin/bash", "-c"]

ARG PREFIX=/usr/local
ARG DEPS_CONFIGURE_OPTS="--prefix=${PREFIX} --enable-static --enable-pic"
ENV PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
ENV MAKEFLAGS -j3

ENV BUILD_DIR=/root/ffmpeg-build
RUN mkdir -p ${BUILD_DIR} && \
    echo BUILD_DIR: ${BUILD_DIR} && \
    echo DEPS_CONFIGURE_OPTS: ${DEPS_CONFIGURE_OPTS}

# Install freetype once, but re-install after harfbuzz installed
ARG FREETYPE_VERSION=2.12.1
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL http://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.gz | tar -zx && \
    cd freetype-${FREETYPE_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure-pre.log && \
    make ${MAKEFLAGS} > make-pre.log 2>&1 && make install 2>&1 | tee -a make-pre.log | tee -a make-pre.log && \
    pkg-config freetype2 --modversion

# Install harfbuzz with freetype support
ARG HARFBUZZ_VERSION=2.6.7
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://www.freedesktop.org/software/harfbuzz/release/harfbuzz-${HARFBUZZ_VERSION}.tar.xz | tar -Jx && \
    cd harfbuzz-${HARFBUZZ_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} 2>&1 | tee -a configure.log && \
    make > make.log 2>&1 && make install 2>&1 | tee -a make.log && \
    pkg-config harfbuzz --modversion

# Re-install freetype with harfbuzz
RUN cd ${BUILD_DIR} && set -o pipefail && cd freetype-${FREETYPE_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} > make.log 2>&1 && make install 2>&1 | tee -a make.log && make distclean 2>&1 | tee -a make.log && \
    pkg-config freetype2 --modversion

# libfribidi
ARG FRIBIDI_VERSION=1.0.12
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz | tar -Jx && \
    cd fribidi-${FRIBIDI_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config fribidi --modversion

# fontconfig (depends on libexpat)
ARG FONTCONFIG_VERSION=2.14.0
# Without ldconfig, fontconfig fails to build (requires to load libfreetype for cache preloading in `make install`)
RUN ldconfig
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.xz | tar -Jx && \
    cd fontconfig-${FONTCONFIG_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --disable-docs | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log  && \
    pkg-config fontconfig --modversion

# libass (depends on fontconfig, fridibi)
ARG LIBASS_VERSION=0.16.0
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz | tar -zx && \
    cd libass-${LIBASS_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-fontconfig | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config libass --modversion

# x264
# https://trac.ffmpeg.org/wiki/CompilationGuide/Ubuntu
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch stable --depth 1 https://code.videolan.org/videolan/x264.git && \
    cd x264 && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-pic --enable-static | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config x264 --modversion

# x265
# https://trac.ffmpeg.org/wiki/CompilationGuide/Ubuntu
ARG X265_VERSION=3.5
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch ${X265_VERSION} --depth 1 https://bitbucket.org/multicoreware/x265_git && \
    cd x265_git/build/linux && \
    cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="${PREFIX}" ../../source 2>&1 | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config x265 --modversion

# ogg
ARG OGG_VERSION=1.3.5
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL http://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz | tar -Jx  && \
    cd libogg-${OGG_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config ogg --modversion

# vorbis
ARG VORBIS_VERSION=1.3.7
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL http://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.gz | tar -zx && \
    cd libvorbis-${VORBIS_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config vorbis --modversion

# theora
ARG THEORA_VERSION=1.1.1
# `sed -i 's/png_\(sizeof\)/\1/g' examples/png2theora.c` is to fix bug (with libpng >= 1.6)
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://ftp.osuosl.org/pub/xiph/releases/theora/libtheora-${THEORA_VERSION}.tar.gz | tar -zx && \
    cd libtheora-${THEORA_VERSION} && \
    sed -i 's/png_\(sizeof\)/\1/g' examples/png2theora.c && \
    ./configure ${DEPS_CONFIGURE_OPTS} --with-ogg=${PREFIX} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config theora --modversion

# lame
ARG LAME_VERSION=3.100
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://jaist.dl.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz | tar -zx && \
    cd lame-${LAME_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-nasm | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log
    # mp3lame doesn't have pkg-config .pc file

# fdk-aac
ARG FDK_AAC_VERSION=v2.0.2
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch ${FDK_AAC_VERSION} --depth 1 https://github.com/mstorsjo/fdk-aac.git && \
    cd fdk-aac && \
    ./autogen.sh | tee -a configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config fdk-aac --modversion

# opus
ARG OPUS_VERSION=v1.3.1
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch ${OPUS_VERSION} --depth 1 https://github.com/xiph/opus.git && \
    cd opus && \
    ./autogen.sh | tee -a configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config opus --modversion

# vpx
ARG VPX_VERSION=refs/tags/v1.12.0
RUN cd ${BUILD_DIR} && set -o pipefail && git clone https://chromium.googlesource.com/webm/libvpx.git && \
    cd libvpx && git checkout ${VPX_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --disable-examples --disable-unit-tests --enable-vp9-highbitdepth --as=yasm | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config vpx --modversion

# AV1 encoder (SvtAv1Enc, library name contains upper-case), requires ffmpeg >= 4.3.3
ARG SVTAV1D_VERSION=v1.2.0
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch ${SVTAV1D_VERSION} --depth 1 https://gitlab.com/AOMediaCodec/SVT-AV1.git && \
    cd SVT-AV1/Build && \
    cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_BUILD_TYPE=Release -DBUILD_DEC=OFF .. 2>&1 | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config SvtAv1Enc --modversion

# AV1 decoder (dav1d)
ARG DAV1D_VERSION=1.0.0
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch ${DAV1D_VERSION} --depth 1 https://code.videolan.org/videolan/dav1d.git && \
    mkdir dav1d/build && cd dav1d/build && \
    meson setup -Denable_tools=false -Denable_tests=false --default-library=static .. --prefix "${PREFIX}" | tee -a configure.log && \
    ninja 2>&1 | tee -a make.log && ninja install 2>&1 | tee -a make.log && \
    pkg-config dav1d --modversion

# webp (library name contains "lib" prefix)
ARG WEBP_VERSION=v1.2.4
RUN cd ${BUILD_DIR} && set -o pipefail && git clone --branch ${WEBP_VERSION} --depth 1 https://chromium.googlesource.com/webm/libwebp && \
    cd libwebp && \
    ./autogen.sh | tee -a configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config libwebp --modversion

# ffmpeg, libav
ARG FFMPEG_VERSION=snapshot
# Make installed libraries visible before building ffmpeg/libav
RUN ldconfig
# pthread is required by libx265 : https://stackoverflow.com/a/62187983/914786
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2 | tar -jx && \
    cd ffmpeg* && \
    ./configure --prefix=${PREFIX} \
      --pkg-config-flags="--static" \
      --enable-shared --disable-static \
      --extra-cflags="-O3" \
      --extra-libs="-lpthread -lm" \
      --disable-debug --disable-doc --disable-ffplay \
      --enable-gpl --enable-nonfree --enable-version3 \
      --enable-pthreads \
      --enable-autodetect --enable-swresample --enable-swscale --enable-postproc --enable-filters \
      --enable-openssl \
      --enable-libwebp \
      --enable-libfreetype --enable-libass --enable-libx264 --enable-libx265  --enable-libvorbis --enable-libtheora --enable-libmp3lame --enable-libfdk-aac --enable-libopus --enable-libvpx --enable-libsvtav1 --enable-libdav1d \
      | tee -a configure.log \
    && \
    make ${MAKEFLAGS} 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log
RUN ldconfig   # Make ffmpeg libraries visible
RUN ffmpeg -codecs

# Back to the default
SHELL ["/bin/sh", "-c"]
