#!/bin/bash
# Content-based regression tests for a downstream media library's transcode profiles.
#
# Run inside the container, with the repository's test media mounted read-only:
#
#   docker run --rm -v "$PWD/test-media:/test-media:ro" -v "$PWD/tests:/tests:ro" \
#     ffmpeg-test bash /tests/run-profile-regression-tests.sh
#
# ## Why this exists next to run-media-tests.sh
#
# `run-media-tests.sh` asks "can this build encode VP9 at all?" - a capability check, and
# the right one for catching a missing `--enable-libvpx`. This file asks a different
# question: **does a real downstream argument set still produce the file it produced
# before?** Those come apart constantly. An image can gain every codec and still break its
# users, because:
#
#   * a container default changed and `moov` no longer precedes `mdat`, so every stored
#     file needs a full download before playback starts;
#   * an encoder now reports a different profile/level/tag, and the players that were
#     targeted by `-tag:v hvc1` or `-level:v 4.0` stop accepting the output;
#   * an argument became a no-op, so `-crf` silently falls back to a default and the whole
#     library is re-encoded at the wrong quality;
#   * decode-side behaviour moved - EXIF/display-matrix rotation, `clap` cropping - and
#     every derived thumbnail comes out the wrong shape.
#
# None of those change what `ffprobe -show_entries stream=codec_name` prints. All of them
# break the consumer. So each profile below is run END TO END and the OUTPUT is examined:
# container facts exactly, signal quality against the input within a band.
#
# ## Thresholds are floors, never goldens
#
# This repository exists to upgrade ffmpeg and its libraries. Encoders retune between
# releases: the same `-crf 26` legitimately lands a fraction of a dB away from where it
# did last year. Recording exact numbers here would paint every upgrade red and the suite
# would be `--update`d without being read, which is worse than having no suite.
#
# So nothing here is compared against a recorded measurement. The mechanical facts
# (codec, profile, level, tag, pixel format, channel count, box order) are asserted
# EXACTLY, because no encoder release may change them; the perceptual numbers are held
# against floors far below where a working encoder lands and far above where a broken
# argument set does. A regression that matters fails a floor by an order of magnitude.
#
# ## Test material
#
# Only what is already in this repository (see test-media/*/LICENSE.txt and SOURCE.md) plus
# clips this script generates with ffmpeg itself - synthetic sweeps and re-containered
# excerpts, written to a temporary directory and deleted on exit. Nothing new is committed.

set -uo pipefail

MEDIA_DIR="${MEDIA_DIR:-/test-media}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/media-metrics.sh
source "$HERE/lib/media-metrics.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASSED=0
FAILED=0
TOTAL=0
CURRENT=""
CURRENT_FAILURES=0

# ---------------------------------------------------------------------------- harness
#
# A test collects EVERY failed expectation before reporting, rather than dying on the
# first. When an encoder upgrade shifts three facts at once, seeing all three in one run
# is the difference between one investigation and three.

t_start() {
  CURRENT="$1"
  CURRENT_FAILURES=0
  TOTAL=$((TOTAL + 1))
  echo "  TEST: $CURRENT"
}

t_note() { echo "        - $1"; }

t_fail() {
  CURRENT_FAILURES=$((CURRENT_FAILURES + 1))
  echo "        ! $1"
}

t_end() {
  if [ "$CURRENT_FAILURES" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    echo "        PASS"
  else
    FAILED=$((FAILED + 1))
    echo "        FAIL ($CURRENT_FAILURES problem(s))"
  fi
}

expect_eq() {
  local what="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    t_fail "$what is '$actual', expected '$expected'"
  fi
}

expect_ge() {
  local what="$1" actual="$2" min="$3"
  if [ -z "$actual" ]; then
    t_fail "$what could not be measured"
  elif ! num_ge "$actual" "$min"; then
    t_fail "$what is $actual, expected >= $min"
  else
    t_note "$what = $actual (floor $min)"
  fi
}

expect_le() {
  local what="$1" actual="$2" max="$3"
  if [ -z "$actual" ]; then
    t_fail "$what could not be measured"
  elif ! num_le "$actual" "$max"; then
    t_fail "$what is $actual, expected <= $max"
  else
    t_note "$what = $actual (cap $max)"
  fi
}

expect_within_ratio() {
  local what="$1" actual="$2" reference="$3" tolerance="$4"
  if ! ratio_within "$actual" "$reference" "$tolerance"; then
    t_fail "$what is $actual, expected within ${tolerance} of $reference"
  fi
}

expect_true() {
  local what="$1"
  shift
  if ! "$@"; then t_fail "$what"; fi
}

ff() { ffmpeg -nostdin -hide_banner -v error -y "$@"; }

# ------------------------------------------------------------------------- thresholds
#
# Each one records what it is guarding against, because a threshold nobody can explain is
# a threshold nobody dares tighten and nobody trusts when it fires.

# A transcode whose length drifts by more than this is a truncated or padded encode - the
# failure that otherwise reaches a user as "the last minute of the album is missing".
DURATION_TOLERANCE=0.03

# Video, measured against the file that was fed in. Real encoders at these CRFs land above
# 30 dB / 0.97 on this material; a lost `-crf`, a wrong pixel format or a half-finished
# encode lands far below. VP9 gets its own floor because `-crf 34` is deliberately a
# lower quality point than the H.26x profiles' `-crf 26`.
VIDEO_PSNR_MIN=25
VIDEO_SSIM_MIN=0.90
VP9_PSNR_MIN=22
VP9_SSIM_MIN=0.85

# Audio, measured against the file that was fed in. A 128 kbit/s lossy encode of this
# material sits around 0.9 spectrogram SSIM and 20-40 dB SDR; a channel collapse, a wrong
# sample rate or cover art leaking into the audio stream drops SSIM below 0.6, and a lost
# encoder-delay compensation destroys SDR while leaving SSIM almost untouched.
AUDIO_SSIM_MIN=0.60
AUDIO_SDR_MIN=10

# The nominal bitrate of both lossy audio profiles is 128 kbit/s. The band is wide because
# a container adds overhead and an encoder may aim slightly off; it is still narrow enough
# that a dropped `-b:a 128k` (which sends libfdk_aac and libopus to defaults elsewhere)
# shows up here.
AUDIO_BITRATE_MIN=90000
AUDIO_BITRATE_MAX=200000

# ---------------------------------------------------------------- the profiles under test
#
# These are the argument vectors a downstream media library runs in production, kept here
# verbatim so that a change in this image is measured against what its consumers actually
# ask for. They are pure ffmpeg arguments - no policy, no naming, nothing about where the
# files come from or go. The reasoning behind each choice belongs to that project; what
# matters here is that this build keeps honouring them.

# Lossless archival audio. The `aformat` clamp is the interesting part: it forces a
# 48 kHz / 24-bit source down to a rate and depth the target players are guaranteed to
# handle, so the resampler is exercised on every run.
PROFILE_FLAC=(-map 0:a:0 -c:a flac
  -af "aformat=sample_fmts=u8|s16:sample_rates=32000|44100:channel_layouts=stereo")

# Lossy audio for general playback: AAC-LC in MP4, progressive-download friendly.
PROFILE_AAC=(-map 0:a:0 -c:a libfdk_aac -b:a 128k -f mp4 -movflags +faststart)

# Generic fallback video: H.264 Main@4.0 + AAC-LC in MP4.
PROFILE_H264=(-c:v libx264 -profile:v main -level:v 4.0 -crf 26 -preset:v medium
  -c:a libfdk_aac -b:a 128k -f mp4 -movflags +faststart)

# Video for Apple devices: HEVC Main, Main Tier, Level 5.0, tagged `hvc1` (Safari will not
# play `hev1`-tagged HEVC in MP4 at all, which makes the tag a functional requirement
# rather than a cosmetic one).
PROFILE_H265=(-c:v libx265 -level:v 5.0 -x265-params "no-high-tier:level-idc=5.0"
  -crf 26 -preset medium -tag:v hvc1 -c:a libfdk_aac -b:a 128k
  -f mp4 -movflags +faststart)

# Video for Chrome/Firefox: VP9 + Opus in WebM. `-b:v 0` is what makes `-crf` a pure
# quality target; without it libvpx caps the bitrate and the quality collapses on exactly
# the busiest scenes.
PROFILE_VP9=(-c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -c:a libopus -b:a 128k -f webm)

# Still images are normalised to JPEG with three arguments, and the middle one is the
# reason this is tested at all: without `-pix_fmt yuvj420p` this build picks 4:4:4 for an
# RGB input and the JPEG comes out ~1.5x larger for no visible gain - a regression that is
# invisible in the picture and only shows up on the storage bill.
JPEG_ARGS=(-frames:v 1 -q:v 4 -pix_fmt yuvj420p)

# ---------------------------------------------------------------------------- fixtures

echo "=== Preparing fixtures ==="

SRC_VIDEO="$WORK_DIR/source-video.mp4"
SRC_LOSSY_AUDIO="$WORK_DIR/source-lossy.mp3"
SRC_LOSSLESS_AUDIO="$WORK_DIR/source-lossless.flac"
SRC_COVER_IMAGE="$MEDIA_DIR/image/thinking-head.png"
SRC_AUDIO_WITH_COVER="$WORK_DIR/source-with-cover.mp3"
SRC_ROTATED_VIDEO="$WORK_DIR/source-rotated.mp4"

# Excerpts rather than the whole files: the profiles are quality-targeted, so four seconds
# measures them exactly as well as eighteen does, and `-c copy` keeps the excerpt's
# bitstream identical to the committed material.
ff -i "$MEDIA_DIR/video/H264_AAC.mp4" -t 4 -c copy "$SRC_VIDEO"
ff -i "$MEDIA_DIR/audio/ff-16b-2c-44100hz.mp3" -t 8 -c copy "$SRC_LOSSY_AUDIO"

# A lossless source at 48 kHz / 24-bit, so that the FLAC profile's resample and bit-depth
# reduction actually run instead of being a no-op. Two INDEPENDENT sweeps, one per channel:
# a swapped or collapsed channel is then visible in the spectrogram, which a mono sine
# could never show. Both sweeps stay below 4 kHz, inside the band a 128 kbit/s lossy
# encoder keeps, so the perceptual numbers measure the pipeline rather than the codec's
# advertised lowpass.
SWEEP='aevalsrc=0.45*sin(2*PI*(120+900*t)*t)|0.45*sin(2*PI*(300+1600*t)*t):s=48000:d=2'
ff -f lavfi -i "$SWEEP" -c:a flac -sample_fmt s32 "$SRC_LOSSLESS_AUDIO"

# Audio carrying attached cover art, for the artwork-extraction path.
ff -i "$SRC_LOSSY_AUDIO" -i "$SRC_COVER_IMAGE" -map 0:a -map 1:v -c:a copy -c:v copy \
  -id3v2_version 3 -metadata:s:v title="Album cover" "$SRC_AUDIO_WITH_COVER"

# A clip carrying a display matrix, for the decode-side rotation check. `-display_rotation`
# is an INPUT option and writes real side data on the stream; the older
# `-metadata:s:v rotate=90` writes a tag that current builds no longer turn into a display
# matrix, so it would produce a fixture that proves nothing.
ff -display_rotation 90 -i "$SRC_VIDEO" -c copy "$SRC_ROTATED_VIDEO"

echo "  fixtures ready in $WORK_DIR"
echo ""

# ------------------------------------------------------------------ audio profile tests

echo "=== Audio profiles ==="

t_start "FLAC profile: 48kHz/24-bit source -> 44.1kHz/16-bit, LOSSLESSLY"
OUT="$WORK_DIR/out-flac.flac"
if ! ff -i "$SRC_LOSSLESS_AUDIO" "${PROFILE_FLAC[@]}" "$OUT"; then
  t_fail "the transcode itself failed"
else
  expect_eq "container" "$(probe_format "$OUT" format_name)" "flac"
  expect_eq "codec" "$(probe_stream "$OUT" a:0 codec_name)" "flac"
  expect_eq "sample format" "$(probe_stream "$OUT" a:0 sample_fmt)" "s16"
  expect_eq "sample rate" "$(probe_stream "$OUT" a:0 sample_rate)" "44100"
  expect_eq "channels" "$(probe_stream "$OUT" a:0 channels)" "2"
  # `-map 0:a:0` exists to stop cover art becoming a video stream in the output.
  expect_eq "video streams" "$(probe_stream_count "$OUT" v)" "0"
  expect_within_ratio "duration" "$(probe_format "$OUT" duration)" \
    "$(probe_format "$SRC_LOSSLESS_AUDIO" duration)" "$DURATION_TOLERANCE"

  # The strongest statement available about a lossless profile, and the reason no
  # perceptual metric is used here: run the profile's own filter chain on the source into
  # raw PCM, decode the FLAC output into raw PCM, and require the two to be BIT-IDENTICAL.
  # Both sides go through the same resampler, so this survives an ffmpeg upgrade that
  # improves the filter - while a FLAC encoder that stopped being lossless, or a filter
  # chain that quietly stopped being applied, fails immediately.
  REFERENCE_PCM=$(pcm_sha256 "$SRC_LOSSLESS_AUDIO" s16le \
    "aformat=sample_fmts=u8|s16:sample_rates=32000|44100:channel_layouts=stereo")
  OUTPUT_PCM=$(pcm_sha256 "$OUT" s16le)
  expect_eq "decoded PCM digest" "$OUTPUT_PCM" "$REFERENCE_PCM"
fi
t_end

t_start "AAC-LC profile: MP4, 128k, faststart"
OUT="$WORK_DIR/out-aac.m4a"
if ! ff -i "$SRC_LOSSY_AUDIO" "${PROFILE_AAC[@]}" "$OUT"; then
  t_fail "the transcode itself failed"
else
  expect_eq "container" "$(probe_format "$OUT" format_name)" "mov,mp4,m4a,3gp,3g2,mj2"
  expect_eq "codec" "$(probe_stream "$OUT" a:0 codec_name)" "aac"
  # The profile is a promise to a specific decoder: HE-AAC or AAC-Main here would not play
  # where LC does.
  expect_eq "codec profile" "$(probe_stream "$OUT" a:0 profile)" "LC"
  expect_eq "channels" "$(probe_stream "$OUT" a:0 channels)" "2"
  expect_eq "sample rate" "$(probe_stream "$OUT" a:0 sample_rate)" "44100"
  expect_eq "video streams" "$(probe_stream_count "$OUT" v)" "0"
  expect_true "moov precedes mdat (+faststart)" mp4_faststart "$OUT"
  expect_within_ratio "duration" "$(probe_format "$OUT" duration)" \
    "$(probe_format "$SRC_LOSSY_AUDIO" duration)" "$DURATION_TOLERANCE"

  BITRATE=$(probe_format "$OUT" bit_rate)
  if ! num_ge "$BITRATE" "$AUDIO_BITRATE_MIN" || ! num_le "$BITRATE" "$AUDIO_BITRATE_MAX"; then
    t_fail "bitrate $BITRATE outside ${AUDIO_BITRATE_MIN}..${AUDIO_BITRATE_MAX} (-b:a 128k lost?)"
  fi

  expect_ge "spectrogram SSIM vs source" "$(spectrogram_ssim "$SRC_LOSSY_AUDIO" "$OUT")" \
    "$AUDIO_SSIM_MIN"
  expect_ge "SDR vs source (dB)" "$(audio_sdr_min "$SRC_LOSSY_AUDIO" "$OUT")" "$AUDIO_SDR_MIN"
fi
t_end

echo ""

# ------------------------------------------------------------------ video profile tests

# Shared checks for the three video profiles: the audio half, the length, and the two
# perceptual numbers. The container and video-stream facts differ per profile and are
# asserted at each call site.
check_video_output() {
  local out="$1" psnr_min="$2" ssim_min="$3" quality
  expect_within_ratio "duration" "$(probe_format "$out" duration)" \
    "$(probe_format "$SRC_VIDEO" duration)" "$DURATION_TOLERANCE"
  expect_eq "video streams" "$(probe_stream_count "$out" v)" "1"
  expect_eq "audio streams" "$(probe_stream_count "$out" a)" "1"

  quality=$(video_quality "$SRC_VIDEO" "$out")
  if [ -z "$quality" ]; then
    t_fail "PSNR/SSIM could not be measured"
  else
    expect_ge "PSNR vs source (dB)" "${quality% *}" "$psnr_min"
    expect_ge "SSIM vs source" "${quality#* }" "$ssim_min"
  fi
  expect_ge "audio spectrogram SSIM vs source" "$(spectrogram_ssim "$SRC_VIDEO" "$out")" \
    "$AUDIO_SSIM_MIN"
}

echo "=== Video profiles ==="

t_start "H.264 Main@4.0 + AAC-LC profile"
OUT="$WORK_DIR/out-h264.mp4"
if ! ff -i "$SRC_VIDEO" "${PROFILE_H264[@]}" "$OUT"; then
  t_fail "the transcode itself failed"
else
  expect_eq "container" "$(probe_format "$OUT" format_name)" "mov,mp4,m4a,3gp,3g2,mj2"
  expect_eq "video codec" "$(probe_stream "$OUT" v:0 codec_name)" "h264"
  expect_eq "video profile" "$(probe_stream "$OUT" v:0 profile)" "Main"
  # ffprobe reports H.264 levels x10: 4.0 -> 40.
  expect_eq "video level" "$(probe_stream "$OUT" v:0 level)" "40"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuv420p"
  expect_eq "audio codec" "$(probe_stream "$OUT" a:0 codec_name)" "aac"
  expect_eq "audio profile" "$(probe_stream "$OUT" a:0 profile)" "LC"
  expect_true "moov precedes mdat (+faststart)" mp4_faststart "$OUT"
  check_video_output "$OUT" "$VIDEO_PSNR_MIN" "$VIDEO_SSIM_MIN"
fi
t_end

t_start "HEVC Main@5.0 Main-tier, hvc1-tagged, + AAC-LC profile"
OUT="$WORK_DIR/out-h265.mp4"
if ! ff -i "$SRC_VIDEO" "${PROFILE_H265[@]}" "$OUT"; then
  t_fail "the transcode itself failed"
else
  expect_eq "container" "$(probe_format "$OUT" format_name)" "mov,mp4,m4a,3gp,3g2,mj2"
  expect_eq "video codec" "$(probe_stream "$OUT" v:0 codec_name)" "hevc"
  expect_eq "video profile" "$(probe_stream "$OUT" v:0 profile)" "Main"
  # HEVC levels are reported x30, so the requested 5.0 is a CAP of 150. x265 signals the
  # lowest level the content actually needs and `--level-idc` is the ceiling, so the
  # number below depends on the clip - what must never happen is the encoder exceeding
  # the ceiling, because a stream above Level 5.0 is refused by the hardware decoders
  # this profile targets.
  expect_le "video level" "$(probe_stream "$OUT" v:0 level)" "150"
  # The functional one: Safari refuses `hev1`-tagged HEVC in MP4.
  expect_eq "codec tag" "$(probe_stream "$OUT" v:0 codec_tag_string)" "hvc1"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuv420p"
  expect_eq "audio codec" "$(probe_stream "$OUT" a:0 codec_name)" "aac"
  expect_eq "audio profile" "$(probe_stream "$OUT" a:0 profile)" "LC"
  expect_true "moov precedes mdat (+faststart)" mp4_faststart "$OUT"
  check_video_output "$OUT" "$VIDEO_PSNR_MIN" "$VIDEO_SSIM_MIN"
fi
t_end

t_start "VP9 + Opus (WebM) profile"
OUT="$WORK_DIR/out-vp9.webm"
if ! ff -i "$SRC_VIDEO" "${PROFILE_VP9[@]}" "$OUT"; then
  t_fail "the transcode itself failed"
else
  # `-f webm` rather than `-f matroska` on purpose: it enforces the WebM subset, so a
  # stream that does not belong in WebM fails here instead of in a browser.
  expect_eq "container" "$(probe_format "$OUT" format_name)" "matroska,webm"
  expect_eq "video codec" "$(probe_stream "$OUT" v:0 codec_name)" "vp9"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuv420p"
  expect_eq "audio codec" "$(probe_stream "$OUT" a:0 codec_name)" "opus"
  check_video_output "$OUT" "$VP9_PSNR_MIN" "$VP9_SSIM_MIN"
fi
t_end

t_start "VP9: -crf is honoured, and -b:v 0 never costs quality"
# Two separate worries, one encode budget.
#
# `-crf` becoming a no-op is the loud one: an argument that stops being read leaves every
# codec name in the output correct and re-encodes an entire library at the wrong quality.
# Encoding the same source at two very different CRFs and requiring the numbers to move
# apart is the direct test, and it needs no recorded value to compare against.
#
# `-b:v 0` is the quiet one. It is what makes `-crf` a pure quality target; without it
# libvpx caps the bitrate and quality collapses - but only once the CRF result would
# exceed the cap, which short test material never does. So it cannot be proven on a clip
# this size; what CAN be checked is that including it is never the worse choice, which is
# what would show up if its meaning ever inverted.
OUT_CRF34="$WORK_DIR/out-vp9-crf34.webm"
OUT_CRF50="$WORK_DIR/out-vp9-crf50.webm"
OUT_NO_BV="$WORK_DIR/out-vp9-nobv.webm"
if ! ff -i "$SRC_VIDEO" -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -an -f webm "$OUT_CRF34" ||
  ! ff -i "$SRC_VIDEO" -c:v libvpx-vp9 -crf 50 -b:v 0 -row-mt 1 -an -f webm "$OUT_CRF50" ||
  ! ff -i "$SRC_VIDEO" -c:v libvpx-vp9 -crf 34 -row-mt 1 -an -f webm "$OUT_NO_BV"; then
  t_fail "one of the three encodes failed"
else
  Q34=$(video_quality "$SRC_VIDEO" "$OUT_CRF34")
  Q50=$(video_quality "$SRC_VIDEO" "$OUT_CRF50")
  QNO=$(video_quality "$SRC_VIDEO" "$OUT_NO_BV")
  if [ -z "$Q34" ] || [ -z "$Q50" ] || [ -z "$QNO" ]; then
    t_fail "PSNR/SSIM could not be measured"
  else
    t_note "crf 34: PSNR ${Q34% *} dB, crf 50: PSNR ${Q50% *} dB, crf 34 without -b:v 0: ${QNO% *} dB"
    GAIN=$(awk -v a="${Q34% *}" -v b="${Q50% *}" 'BEGIN { printf "%.4f", a - b }')
    expect_ge "PSNR gained by crf 34 over crf 50 (dB)" "$GAIN" 2
    SIZE34=$(stat -c %s "$OUT_CRF34")
    SIZE50=$(stat -c %s "$OUT_CRF50")
    t_note "crf 34 = $SIZE34 bytes, crf 50 = $SIZE50 bytes"
    if [ "$SIZE34" -le "$SIZE50" ]; then
      t_fail "the crf 34 output ($SIZE34 B) is not larger than the crf 50 one ($SIZE50 B)"
    fi
    expect_ge "PSNR with -b:v 0 (dB)" "${Q34% *}" "${QNO% *}"
  fi
fi
t_end

echo ""

# ------------------------------------------------------------------------- image tests

echo "=== Image conversion ==="

t_start "JPEG normalisation: -pix_fmt yuvj420p, -q:v 4, single frame"
OUT="$WORK_DIR/out-image.jpeg"
if ! ff -i "$SRC_COVER_IMAGE" "${JPEG_ARGS[@]}" "$OUT"; then
  t_fail "the conversion itself failed"
else
  expect_eq "codec" "$(probe_stream "$OUT" v:0 codec_name)" "mjpeg"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuvj420p"
  expect_eq "width" "$(probe_stream "$OUT" v:0 width)" \
    "$(probe_stream "$SRC_COVER_IMAGE" v:0 width)"
  expect_eq "height" "$(probe_stream "$OUT" v:0 height)" \
    "$(probe_stream "$SRC_COVER_IMAGE" v:0 height)"

  QUALITY=$(video_quality "$SRC_COVER_IMAGE" "$OUT")
  if [ -z "$QUALITY" ]; then
    t_fail "PSNR/SSIM could not be measured"
  else
    expect_ge "SSIM vs source" "${QUALITY#* }" "$VIDEO_SSIM_MIN"
  fi
fi
t_end

t_start "JPEG normalisation: without -pix_fmt an RGB source still picks 4:4:4"
# The guard for the argument that is invisible in the picture. If this build ever starts
# defaulting an RGB input to 4:2:0, this test fails - and that is a WELCOME failure worth
# reading, because it means the downstream argument could be simplified. If instead the
# 4:2:0 output stops being smaller, the `-pix_fmt` argument has stopped working.
OUT_DEFAULT="$WORK_DIR/out-image-default.jpeg"
if ! ff -i "$SRC_COVER_IMAGE" -frames:v 1 -q:v 4 "$OUT_DEFAULT"; then
  t_fail "the conversion itself failed"
else
  DEFAULT_FMT=$(probe_stream "$OUT_DEFAULT" v:0 pix_fmt)
  t_note "default pixel format for an RGB input: $DEFAULT_FMT"
  expect_eq "default pixel format" "$DEFAULT_FMT" "yuvj444p"
  SIZE_420=$(stat -c %s "$WORK_DIR/out-image.jpeg")
  SIZE_444=$(stat -c %s "$OUT_DEFAULT")
  t_note "4:2:0 = $SIZE_420 bytes, 4:4:4 = $SIZE_444 bytes"
  if [ "$SIZE_420" -ge "$SIZE_444" ]; then
    t_fail "the 4:2:0 output ($SIZE_420 B) is not smaller than the 4:4:4 one ($SIZE_444 B)"
  fi
fi
t_end

t_start "JPEG normalisation of an alpha source flattens rather than failing"
OUT="$WORK_DIR/out-image-alpha.jpeg"
if ! ff -i "$MEDIA_DIR/image/alpha-lossy.webp" "${JPEG_ARGS[@]}" "$OUT"; then
  t_fail "the conversion itself failed"
else
  expect_eq "codec" "$(probe_stream "$OUT" v:0 codec_name)" "mjpeg"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuvj420p"
  expect_eq "width" "$(probe_stream "$OUT" v:0 width)" \
    "$(probe_stream "$MEDIA_DIR/image/alpha-lossy.webp" v:0 width)"
fi
t_end

echo ""

# --------------------------------------------------------------------- thumbnail tests

echo "=== Thumbnail pipeline ==="

t_start "Six thumbnail sizes from ONE decode (split + per-branch lanczos scale)"
# Generating N sizes with N ffmpeg runs means N decodes of the source; a large photo
# decoded six times is six times the work for identical output. The one-pass form below is
# what a downstream library actually runs, and it depends on `split` accepting an
# arbitrary branch count and on `-map` selecting filter outputs by label.
SIZES=(1200 600 320 160 80 40)
FILTER="[0:v]split=${#SIZES[@]}"
for i in "${!SIZES[@]}"; do FILTER="${FILTER}[b$i]"; done
ARGS=()
for i in "${!SIZES[@]}"; do
  FILTER="$FILTER;[b$i]scale=${SIZES[$i]}:-2:flags=lanczos[s$i]"
  ARGS+=(-map "[s$i]" "${JPEG_ARGS[@]}" "$WORK_DIR/thumb-${SIZES[$i]}.jpeg")
done
if ! ff -i "$SRC_COVER_IMAGE" -filter_complex "$FILTER" "${ARGS[@]}"; then
  t_fail "the one-pass thumbnail run failed"
else
  for size in "${SIZES[@]}"; do
    file="$WORK_DIR/thumb-$size.jpeg"
    if [ ! -s "$file" ]; then
      t_fail "no output for the ${size}px box"
      continue
    fi
    expect_eq "${size}px thumbnail width" "$(probe_stream "$file" v:0 width)" "$size"
    expect_eq "${size}px thumbnail pixel format" "$(probe_stream "$file" v:0 pix_fmt)" "yuvj420p"
  done
fi
t_end

t_start "Video tile sheet (select + scale + tile) has the geometry it claims"
# The scrub-bar preview: evenly spaced frames laid out in a fixed-width grid, as ONE JPEG.
# `isnan(prev_selected_t)` is the load-bearing term - without it `prev_selected_t` is NaN
# for the first frame, the comparison is false, and the sheet comes out empty. The
# backslash before the comma is filter-graph escaping, not shell escaping.
TILE_W=320
TILE_H=240
TILE_X=10
TILE_Y=1
INTERVAL_SEC=1
OUT="$WORK_DIR/out-tiles.jpeg"
SELECT="select=isnan(prev_selected_t)+gte(t-prev_selected_t\\,${INTERVAL_SEC})"
if ! ff -i "$SRC_VIDEO" -frames 1 \
  -vf "${SELECT},scale=${TILE_W}:${TILE_H},tile=${TILE_X}x${TILE_Y}" \
  "${JPEG_ARGS[@]}" "$OUT"; then
  t_fail "the tile sheet run failed"
else
  expect_eq "sheet width" "$(probe_stream "$OUT" v:0 width)" "$((TILE_W * TILE_X))"
  expect_eq "sheet height" "$(probe_stream "$OUT" v:0 height)" "$((TILE_H * TILE_Y))"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuvj420p"

  # An empty or misaligned sheet is a plausible failure (see the `isnan` note) and it is
  # still a valid JPEG of exactly the right size, so the pixels have to be looked at.
  # Cropping the first cell out of the sheet and comparing it with the source's first
  # frame - scaled the same way - tests three things at once: frames landed in the sheet,
  # the first one is the FIRST frame, and the grid origin is where the geometry says.
  FIRST_CELL="$WORK_DIR/out-tile-cell0.jpeg"
  FIRST_FRAME="$WORK_DIR/out-first-frame.jpeg"
  ff -i "$OUT" -vf "crop=${TILE_W}:${TILE_H}:0:0" "${JPEG_ARGS[@]}" "$FIRST_CELL"
  ff -i "$SRC_VIDEO" -frames:v 1 -vf "scale=${TILE_W}:${TILE_H}" "${JPEG_ARGS[@]}" "$FIRST_FRAME"
  CELL_QUALITY=$(video_quality "$FIRST_FRAME" "$FIRST_CELL")
  if [ -z "$CELL_QUALITY" ]; then
    t_fail "the first cell could not be compared with the first frame"
  else
    expect_ge "SSIM of the sheet's first cell vs the first frame" "${CELL_QUALITY#* }" 0.95
  fi
fi
t_end

t_start "Representative frame extraction seeks and re-encodes at full quality"
OUT="$WORK_DIR/out-frame.jpeg"
if ! ff -ss 1000ms -i "$SRC_VIDEO" -frames 1 "${JPEG_ARGS[@]}" "$OUT"; then
  t_fail "the frame extraction failed"
else
  expect_eq "codec" "$(probe_stream "$OUT" v:0 codec_name)" "mjpeg"
  expect_eq "pixel format" "$(probe_stream "$OUT" v:0 pix_fmt)" "yuvj420p"
  expect_eq "frame size" \
    "$(probe_stream "$OUT" v:0 width)x$(probe_stream "$OUT" v:0 height)" \
    "$(decoded_frame_size "$SRC_VIDEO")"
fi
t_end

echo ""

# ------------------------------------------------------------- decode-side expectations

echo "=== Decode-side behaviour ==="

t_start "Attached cover art is extracted byte-for-byte with -c:v copy"
# Artwork is copied, never re-encoded: the picture in the file is the picture that gets
# stored. A build where the mp3 demuxer stopped exposing the attached picture as a stream,
# or where `-f image2` started re-encoding, changes the digest.
OUT="$WORK_DIR/out-cover.png"
if ! ff -i "$SRC_AUDIO_WITH_COVER" -map 0:v -c:v copy -f image2 "$OUT"; then
  t_fail "the artwork extraction failed"
else
  expect_eq "extracted artwork digest" \
    "$(sha256sum "$OUT" | cut -d' ' -f1)" \
    "$(sha256sum "$SRC_COVER_IMAGE" | cut -d' ' -f1)"
fi
t_end

t_start "The display matrix is applied on DECODE, not merely reported"
# Downstream thumbnail geometry is derived from the decoded frame, so this build's habit of
# applying rotation itself is depended upon. If it ever stopped, every rotated clip would
# produce transposed thumbnails - and nothing else would fail.
STORED="$(probe_stream "$SRC_ROTATED_VIDEO" v:0 width)x$(probe_stream "$SRC_ROTATED_VIDEO" v:0 height)"
DECODED="$(decoded_frame_size "$SRC_ROTATED_VIDEO")"
UNROTATED="$(decoded_frame_size "$SRC_VIDEO")"
t_note "stored $STORED, decoded $DECODED, unrotated $UNROTATED"
if [ -z "$DECODED" ]; then
  t_fail "the decoded frame size could not be read"
else
  expect_eq "decoded size of the rotated clip" "$DECODED" \
    "$(echo "$UNROTATED" | awk -F x '{print $2 "x" $1}')"
fi
t_end

t_start "ffprobe reports the fields downstream metadata extraction reads"
# A consumer with no separate metadata library takes everything from this JSON. Each field
# below is one such reader: losing any of them is a silent downgrade rather than an error.
#
# Both greps read from a variable rather than a pipe on purpose: `grep -q` stops at the
# first match, and under `pipefail` the producer's resulting SIGPIPE would be reported as
# a failed check rather than a satisfied one.
JSON=$(ffprobe -v error -show_format -show_streams -of json "$WORK_DIR/out-h265.mp4")
for field in codec_name codec_tag_string profile level pix_fmt width height \
  sample_rate channels sample_fmt duration bit_rate; do
  case "$JSON" in
  *"\"$field\""*) ;;
  *) t_fail "ffprobe JSON has no '$field'" ;;
  esac
done
# `side_data_list` is how cropping and rotation reach a consumer that needs to know the
# stored frame differs from the decoded one.
ROTATED_JSON=$(ffprobe -v error -show_streams -of json "$SRC_ROTATED_VIDEO")
case "$ROTATED_JSON" in
*'"side_data_type": "Display Matrix"'*) ;;
*) t_fail "ffprobe reports no Display Matrix side data for a rotated clip" ;;
esac
t_end

t_start "A non-media file is a clean 'no', not a crash"
# Consumers hand this image whatever a user uploaded. The contract they rely on is a
# non-zero exit with a parseable error - not a hang, not a signal, not a zero exit with
# empty output that would be read as "an empty media file".
NOT_MEDIA="$WORK_DIR/not-media.bin"
head -c 4096 /dev/urandom >"$NOT_MEDIA"
OUTPUT=$(ffprobe -v quiet -of json -show_error -show_format -show_streams "$NOT_MEDIA" 2>&1)
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  t_fail "ffprobe exited 0 on a non-media file"
fi
case "$OUTPUT" in
*'"error"'*) ;;
*) t_fail "ffprobe did not report a structured error for a non-media file" ;;
esac
t_end

echo ""
echo "==============================="
echo "  Results: $PASSED/$TOTAL passed, $FAILED failed"
echo "==============================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
