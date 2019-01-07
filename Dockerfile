FROM ubuntu:18.04

ENV DEBIAN_FRONTEND noninteractive
# Don't update bootloader: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=594189
ENV INITRD No
ENV LANG en_US.UTF-8

RUN echo 'force-unsafe-io' >> /etc/dpkg/dpkg.cfg.d/02apt-speedup && \
    apt-get update && \
    apt-get -y install curl && \
    apt-get install -y --no-install-recommends apt-utils && \
    apt-get -y install \
      git-core bash emacs-nox \
      build-essential pkg-config cmake yasm nasm gperf \
      zlib1g-dev libpng-dev libjpeg-dev uuid-dev \
      file locales \
    && \
    locale-gen $(bash -c 'echo ${LANG%.*}') ${LANG} && \
    apt-get clean && \
    rm -r /var/lib/apt/lists/*

# Use bash because I want to use pipefail in this build.
SHELL ["/bin/bash", "-c"]

ARG PREFIX=/usr/local
ARG DEPS_CONFIGURE_OPTS="--prefix=${PREFIX} --enable-static --enable-pic"

ENV BUILD_DIR=/root/ffmpeg-build
RUN mkdir -p ${BUILD_DIR} && \
    echo BUILD_DIR: ${BUILD_DIR} && \
    echo DEPS_CONFIGURE_OPTS: ${DEPS_CONFIGURE_OPTS}

# Install freetype once, but re-install after harfbuzz installed
ARG FREETYPE_VERSION=2.9.1
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL http://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.gz | tar -zx && \
    cd freetype-${FREETYPE_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure-pre.log && \
    make > make-pre.log 2>&1 && make install 2>&1 | tee -a make-pre.log | tee -a make-pre.log && \
    pkg-config freetype2 --modversion

# Install harfbuzz with freetype support
ARG HARFBUZZ_VERSION=2.3.0
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://www.freedesktop.org/software/harfbuzz/release/harfbuzz-${HARFBUZZ_VERSION}.tar.bz2 | tar -jx && \
    cd harfbuzz-${HARFBUZZ_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} 2>&1 | tee -a configure.log && \
    make > make.log 2>&1 && make install 2>&1 | tee -a make.log && \
    pkg-config harfbuzz --modversion

# Re-install freetype with harfbuzz
ARG EXPAT_VERSION=2.2.6
RUN cd ${BUILD_DIR} && set -o pipefail && cd freetype-${FREETYPE_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make > make.log 2>&1 && make install 2>&1 | tee -a make.log && make distclean 2>&1 | tee -a make.log && \
    pkg-config freetype2 --modversion

# libexpat
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://downloads.sourceforge.net/project/expat/expat/${EXPAT_VERSION}/expat-${EXPAT_VERSION}.tar.bz2 | tar -jx && \
    cd expat-${EXPAT_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} 2>&1 | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config expat --modversion

# libfribidi
ARG FRIBIDI_VERSION=1.0.5
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.bz2 | tar -jx && \
    cd fribidi-${FRIBIDI_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config fribidi --modversion

# fontconfig (depends on libexpat)
ARG FONTCONFIG_VERSION=2.13.1
# Without ldconfig, fontconfig fails to build (requires to load libfreetype for cache preloading in `make install`)
RUN ldconfig  
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.bz2 | tar -jx && \
    cd fontconfig-${FONTCONFIG_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --disable-docs | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log  && \
    pkg-config fontconfig --modversion

# libass (depends on fontconfig, fridibi)
ARG LIBASS_VERSION=0.14.0
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz | tar -zx && \
    cd libass-${LIBASS_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-fontconfig | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config libass --modversion

# x264
ARG X264_VERSION=20190105-2245-stable
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://download.videolan.org/pub/videolan/x264/snapshots/x264-snapshot-${X264_VERSION}.tar.bz2 | tar -jx && \
    cd x264-snapshot-${X264_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --disable-opencl --disable-cli --enable-pic --enable-static | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config x264 --modversion

# x265
# multilib.sh builds 12/10/8bit versions with `-DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DENABLE_CLI=OFF`
ARG X265_VERSION=2.9
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://download.videolan.org/pub/videolan/x265/x265_${X265_VERSION}.tar.gz | tar -zx && \
    cd x265_${X265_VERSION}/build/linux && \
    ./multilib.sh | tee -a make.log && \
    make -C 8bit install 2>&1 | tee -a make.log  && \
    pkg-config x265 --modversion

# ogg
ARG OGG_VERSION=1.3.3
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL http://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz | tar -zx  && \
    cd libogg-${OGG_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config ogg --modversion

# vorbis
ARG VORBIS_VERSION=1.3.6
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL http://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.gz | tar -zx && \
    cd libvorbis-${VORBIS_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config vorbis --modversion

# theora
ARG THEORA_VERSION=1.1.1
# `sed -i 's/png_\(sizeof\)/\1/g' examples/png2theora.c` is to fix bug (with libpng >= 1.6)
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://ftp.osuosl.org/pub/xiph/releases/theora/libtheora-${THEORA_VERSION}.tar.gz | tar -zx && \
    cd libtheora-${THEORA_VERSION} && \
    sed -i 's/png_\(sizeof\)/\1/g' examples/png2theora.c && \
    ./configure ${DEPS_CONFIGURE_OPTS} --with-ogg=${PREFIX} | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config theora --modversion

# lame
ARG LAME_VERSION=3.100
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://jaist.dl.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz | tar -zx && \
    cd lame-${LAME_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-nasm | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log
    # mp3lame doesn't have pkg-config .pc file

# fdk-aac
ARG FDK_AAC_VERSION=2.0.0
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://downloads.sourceforge.net/project/opencore-amr/fdk-aac/fdk-aac-${FDK_AAC_VERSION}.tar.gz | tar -zx && \
    cd fdk-aac-${FDK_AAC_VERSION} && \
    ./autogen.sh | tee -a configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config fdk-aac --modversion

# opus
ARG OPUS_VERSION=1.3
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://archive.mozilla.org/pub/opus/opus-${OPUS_VERSION}.tar.gz | tar -zx && \
    cd opus-${OPUS_VERSION} && \
    ./autogen.sh | tee -a configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config opus --modversion

# vpx
ARG VPX_VERSION=refs/tags/v1.7.0
RUN cd ${BUILD_DIR} && set -o pipefail && git clone https://chromium.googlesource.com/webm/libvpx && \
    cd libvpx && git checkout ${VPX_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee -a configure.log && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log && \
    pkg-config vpx --modversion

# ffmpeg
ARG FFMPEG_VERSION=4.1
# Make installed libraries visible
RUN ldconfig
RUN cd ${BUILD_DIR} && set -o pipefail && curl -sL https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz | tar -zx && \
    cd ffmpeg-${FFMPEG_VERSION} && \
    ./configure --prefix=${PREFIX} \
      --pkg-config-flags="--static" \
      --enable-shared --disable-static \
      --extra-cflags="-O3" \
      --disable-debug --disable-doc --disable-ffplay \
      --enable-gpl --enable-nonfree --enable-version3 \
      --enable-pthreads \
      --enable-avresample --enable-postproc --enable-filters \
      --enable-libfreetype --enable-libass --enable-libx264 --enable-libx265  --enable-libvorbis --enable-libtheora --enable-libmp3lame --enable-libfdk-aac --enable-libopus --enable-libvpx \
      | tee -a configure.log \
    && \
    make 2>&1 | tee -a make.log && make install 2>&1 | tee -a make.log
RUN ldconfig   # Make ffmpeg libraries visible

# Back to the default
SHELL ["/bin/sh", "-c"]
