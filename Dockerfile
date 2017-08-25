FROM ubuntu:16.04

ARG APT_SOURCES_LIST=ubuntu/xenial/sources.list.ap-northeast-1.ec2

ENV DEBIAN_FRONTEND noninteractive
# Don't update bootloader: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=594189
ENV INITRD No
ENV LANG en_US.UTF-8

ADD ${APT_SOURCES_LIST} /etc/apt/sources.list

RUN echo 'force-unsafe-io' >> /etc/dpkg/dpkg.cfg.d/02apt-speedup && \
    apt-get update && \
    apt-get -y install curl && \
    apt-get install -y --no-install-recommends apt-utils && \
    apt-get -y install \
      git-core emacs24-nox \
      build-essential pkg-config cmake yasm gperf \
      zlib1g-dev libpng-dev libjpeg-dev \
      file \
    && \
    locale-gen $(bash -c 'echo ${LANG%.*}') ${LANG} && \
    apt-get clean && \
    rm -r /var/lib/apt/lists/*


# ARG FFMPEG_VERSION will be defined at later
ARG   HARFBUZZ_VERSION=1.5.0
ARG   FREETYPE_VERSION=2.8
ARG      EXPAT_VERSION=2.2.4
ARG FONTCONFIG_VERSION=2.12.4
ARG    FRIBIDI_VERSION=0.19.7
ARG     LIBASS_VERSION=0.13.7
ARG       X264_VERSION=20170823-2245-stable
ARG       X265_VERSION=2.5
ARG        OGG_VERSION=1.3.2
ARG     VORBIS_VERSION=1.3.5
ARG     THEORA_VERSION=1.1.1
ARG       LAME_VERSION=3.99.5
ARG    FDK_AAC_VERSION=0.1.5
ARG       OPUS_VERSION=1.2.1

ARG PREFIX=/usr/local
ARG DEPS_CONFIGURE_OPTS="--prefix=${PREFIX} --enable-static --enable-pic"

ENV BUILD_DIR=/root/ffmpeg-build
RUN mkdir -p ${BUILD_DIR} && \
    echo BUILD_DIR: ${BUILD_DIR} && \
    echo DEPS_CONFIGURE_OPTS: ${DEPS_CONFIGURE_OPTS}

# Install freetype once, but re-install after harfbuzz installed
RUN cd ${BUILD_DIR} && curl -sL http://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.gz | tar -zx && \
    cd freetype-${FREETYPE_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure-pre.log && \
    make > make-pre.log 2>&1 && make install 2>&1 | tee make-pre.log | tee make-pre.log && \
    pkg-config freetype2 --modversion

# Install harfbuzz with freetype support
RUN cd ${BUILD_DIR} && curl -sL https://www.freedesktop.org/software/harfbuzz/release/harfbuzz-${HARFBUZZ_VERSION}.tar.bz2 | tar -jx && \
    cd harfbuzz-${HARFBUZZ_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} 2>&1 | tee configure.log && \
    make > make.log 2>&1 && make install 2>&1 | tee make.log && \
    pkg-config harfbuzz --modversion

# Install freetype with harfbuzz, circular dependency resolved
RUN cd ${BUILD_DIR} && cd freetype-${FREETYPE_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log && \
    make > make.log 2>&1 && make install 2>&1 | tee make.log && make distclean 2>&1 | tee make.log && \
    pkg-config freetype2 --modversion

# fontconfig depends on libexpat
RUN cd ${BUILD_DIR} && curl -sL https://downloads.sourceforge.net/project/expat/expat/${EXPAT_VERSION}/expat-${EXPAT_VERSION}.tar.bz2 | tar -jx && \
    cd expat-${EXPAT_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} 2>&1 | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config expat --modversion

RUN cd ${BUILD_DIR} && curl -sL http://fribidi.org/download/fribidi-${FRIBIDI_VERSION}.tar.bz2 | tar -jx && \
    cd fribidi-${FRIBIDI_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config fribidi --modversion

RUN ldconfig  # Otherwise, fontconfig fails to build (requires to load libfreetype for cache preloading in `make install`)
RUN cd ${BUILD_DIR} && curl -sL https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.bz2 | tar -jx && \
    cd fontconfig-${FONTCONFIG_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --disable-docs | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log  && \
    pkg-config fontconfig --modversion

# libass depends on fontconfig, fridibi
RUN cd ${BUILD_DIR} && curl -sL https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz | tar -zx && \
    cd libass-${LIBASS_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-fontconfig | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config libass --modversion

RUN cd ${BUILD_DIR} && curl -sL https://ftp.videolan.org/pub/videolan/x264/snapshots/x264-snapshot-${X264_VERSION}.tar.bz2 | tar -jx && \
    cd x264-snapshot-${X264_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --disable-opencl --disable-cli --enable-pic --enable-static | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config x264 --modversion

# multilib.sh builds 12/10/8bit versions with `-DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DENABLE_CLI=OFF`
RUN cd ${BUILD_DIR} && curl -sL https://download.videolan.org/pub/videolan/x265/x265_${X265_VERSION}.tar.gz | tar -zx && \
    cd x265_${X265_VERSION}/build/linux && \
    ./multilib.sh | tee make.log && \
    make -C 8bit install 2>&1 | tee make.log  && \
    pkg-config x265 --modversion

RUN cd ${BUILD_DIR} && curl -sL http://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.gz | tar -zx  && \
    cd libogg-${OGG_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config ogg --modversion

RUN cd ${BUILD_DIR} && curl -sL http://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.gz | tar -zx && \
    cd libvorbis-${VORBIS_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config vorbis --modversion

RUN cd ${BUILD_DIR} && curl -sL http://downloads.xiph.org/releases/theora/libtheora-${THEORA_VERSION}.tar.gz | tar -zx && \
    cd libtheora-${THEORA_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --with-ogg=${PREFIX} | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config theora --modversion

RUN cd ${BUILD_DIR} && curl -sL https://downloads.sf.net/project/lame/lame/${LAME_VERSION%.*}/lame-${LAME_VERSION}.tar.gz | tar -zx && \
    cd lame-${LAME_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} --enable-nasm | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log
    # mp3lame doesn't have pkg-config .pc file

RUN cd ${BUILD_DIR} && curl -sL https://downloads.sourceforge.net/project/opencore-amr/fdk-aac/fdk-aac-${FDK_AAC_VERSION}.tar.gz | tar -zx && \
    cd fdk-aac-${FDK_AAC_VERSION} && \
    ./autogen.sh | tee configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config fdk-aac --modversion

RUN cd ${BUILD_DIR} && curl -sL https://archive.mozilla.org/pub/opus/opus-${OPUS_VERSION}.tar.gz | tar -zx && \
    cd opus-${OPUS_VERSION} && \
    ./autogen.sh | tee configure.log && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config opus --modversion

ARG VPX_VERSION=refs/tags/v1.6.1
RUN cd ${BUILD_DIR} && git clone https://chromium.googlesource.com/webm/libvpx && \
    cd libvpx && git checkout ${VPX_VERSION} && \
    ./configure ${DEPS_CONFIGURE_OPTS} | tee configure.log && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log && \
    pkg-config vpx --modversion


ARG FFMPEG_VERSION=3.3
RUN ldconfig   # Make installed libraries visible
RUN cd ${BUILD_DIR} && curl -sL https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz | tar -zx && \
    cd ffmpeg-${FFMPEG_VERSION} && \
    ./configure --prefix=${PREFIX} \
      --pkg-config-flags="--static" \
      --enable-shared --disable-static \
      --extra-cflags="-O3 -mtune=native -march=native" \
      --disable-debug --disable-doc --disable-ffplay \
      --enable-gpl --enable-nonfree --enable-version3 \
      --enable-pthreads \
      --enable-avresample --enable-postproc --enable-filters \
      --enable-libfreetype --enable-libass --enable-libx264 --enable-libx265  --enable-libvorbis --enable-libtheora --enable-libmp3lame --enable-libfdk-aac --enable-libopus --enable-libvpx \
      | tee configure.log \
    && \
    make 2>&1 | tee make.log && make install 2>&1 | tee make.log  && make distclean 2>&1 | tee make.log
RUN ldconfig   # Make ffmpeg family visible

RUN ffmpeg -codecs | tee ${BUILD_DIR}/ffmpeg.codecs.txt

