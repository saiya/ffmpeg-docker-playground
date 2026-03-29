#!/bin/bash
set -euo pipefail

# Media processing tests for ffmpeg Docker image
# Run inside the container with test-media mounted at /test-media

MEDIA_DIR="/test-media"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

PASSED=0
FAILED=0
TOTAL=0

# --- Helper Functions ---

run_test() {
  local name="$1"
  shift
  TOTAL=$((TOTAL + 1))
  echo -n "  TEST: $name ... "
  if "$@"; then
    PASSED=$((PASSED + 1))
    echo "PASS"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL"
  fi
}

assert_file_exists() {
  [ -f "$1" ]
}

assert_file_min_size() {
  local file="$1" min_bytes="$2"
  [ -f "$file" ] || return 1
  local actual_size
  actual_size=$(stat -c %s "$file")
  [ "$actual_size" -ge "$min_bytes" ]
}

assert_codec() {
  local file="$1" stream_type="$2" expected="$3"
  local actual
  actual=$(ffprobe -v quiet -select_streams "${stream_type}:0" -show_entries stream=codec_name -of csv=p=0 "$file" | head -1 | tr -d '[:space:]')
  [ "$actual" = "$expected" ]
}

assert_has_stream() {
  local file="$1" stream_type="$2"
  ffprobe -v quiet -select_streams "${stream_type}:0" -show_entries stream=codec_name -of csv=p=0 "$file" | grep -q .
}

assert_psnr_above() {
  local original="$1" encoded="$2" threshold="$3"
  local psnr_output
  psnr_output=$(ffmpeg -i "$original" -i "$encoded" -lavfi psnr -f null - 2>&1)
  local avg_psnr
  avg_psnr=$(echo "$psnr_output" | grep -oP 'average:\K[0-9.]+' | tail -1)
  [ -z "$avg_psnr" ] && return 1
  awk "BEGIN { exit ($avg_psnr < $threshold) }"
}

assert_ssim_above() {
  local original="$1" encoded="$2" threshold="$3"
  local ssim_output
  ssim_output=$(ffmpeg -i "$original" -i "$encoded" -lavfi ssim -f null - 2>&1)
  local avg_ssim
  avg_ssim=$(echo "$ssim_output" | grep -oP 'All:\K[0-9.]+' | tail -1)
  [ -z "$avg_ssim" ] && return 1
  awk "BEGIN { exit ($avg_ssim < $threshold) }"
}

# --- Audio Tests ---

echo "=== Audio Transcoding Tests ==="

run_test "MP3 -> AAC" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" -c:a aac "'$WORK_DIR'/out.m4a" 2>/dev/null &&
  ffprobe -v quiet -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/out.m4a" | grep -q aac
'

run_test "MP3 -> Opus" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" -c:a libopus "'$WORK_DIR'/out.opus" 2>/dev/null &&
  ffprobe -v quiet -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/out.opus" | grep -q opus
'

run_test "MP3 -> Vorbis/OGG" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" -c:a libvorbis "'$WORK_DIR'/out.ogg" 2>/dev/null &&
  ffprobe -v quiet -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/out.ogg" | grep -q vorbis
'

run_test "MP3 -> FLAC (lossless)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" -c:a flac "'$WORK_DIR'/out.flac" 2>/dev/null &&
  ffprobe -v quiet -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/out.flac" | grep -q flac
'

run_test "MP3 -> WAV (PCM decode)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" "'$WORK_DIR'/out.wav" 2>/dev/null &&
  [ -f "'$WORK_DIR'/out.wav" ] && [ "$(stat -c %s "'$WORK_DIR'/out.wav")" -gt 1000 ]
'

run_test "OGG -> MP3 (libmp3lame)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.ogg" -c:a libmp3lame "'$WORK_DIR'/out.mp3" 2>/dev/null &&
  ffprobe -v quiet -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/out.mp3" | grep -q mp3
'

run_test "MP3 -> fdk-aac" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" -c:a libfdk_aac "'$WORK_DIR'/out_fdk.m4a" 2>/dev/null &&
  ffprobe -v quiet -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/out_fdk.m4a" | grep -q aac
'

echo ""
echo "=== Audio Analysis Tests ==="

run_test "Spectrogram generation (showspectrumpic)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/audio/ff-16b-2c-44100hz.mp3" -lavfi showspectrumpic=s=1024x512 "'$WORK_DIR'/spectrogram.png" 2>/dev/null &&
  [ -f "'$WORK_DIR'/spectrogram.png" ] && [ "$(stat -c %s "'$WORK_DIR'/spectrogram.png")" -gt 1000 ]
'

# --- Video Tests ---

echo ""
echo "=== Video Transcoding Tests ==="

run_test "H264 -> H265 (libx265)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -c:v libx265 -c:a copy "'$WORK_DIR'/h265.mp4" 2>/dev/null &&
  ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/h265.mp4" | grep -q hevc
'

run_test "H264 -> VP9/WebM (libvpx-vp9 + libopus)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -c:v libvpx-vp9 -b:v 1M -c:a libopus "'$WORK_DIR'/vp9.webm" 2>/dev/null &&
  ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/vp9.webm" | grep -q vp9
'

run_test "WebM -> H264/MP4 (libx264 + aac)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/VP8_vorbis.webm" -c:v libx264 -c:a aac "'$WORK_DIR'/h264.mp4" 2>/dev/null &&
  ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/h264.mp4" | grep -q h264
'

run_test "H264 -> AV1 (libsvtav1)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -c:v libsvtav1 -preset 8 -c:a copy "'$WORK_DIR'/av1.mp4" 2>/dev/null &&
  ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "'$WORK_DIR'/av1.mp4" | grep -q av1
'

echo ""
echo "=== Video Quality Tests ==="

run_test "PSNR > 25 dB (H264 re-encode CRF 23)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -c:v libx264 -crf 23 -c:a copy "'$WORK_DIR'/psnr_test.mp4" 2>/dev/null &&
  psnr_out=$(ffmpeg -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -i "'$WORK_DIR'/psnr_test.mp4" -lavfi psnr -f null - 2>&1) &&
  avg=$(echo "$psnr_out" | grep -oP "average:\K[0-9.]+" | tail -1) &&
  echo "(PSNR avg=$avg)" &&
  awk "BEGIN { exit ($avg < 25) }"
'

run_test "SSIM > 0.90 (H264 re-encode CRF 23)" bash -c '
  ssim_out=$(ffmpeg -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -i "'$WORK_DIR'/psnr_test.mp4" -lavfi ssim -f null - 2>&1) &&
  avg=$(echo "$ssim_out" | grep -oP "All:\K[0-9.]+" | tail -1) &&
  echo "(SSIM avg=$avg)" &&
  awk "BEGIN { exit ($avg < 0.90) }"
'

echo ""
echo "=== Video Frame & Filter Tests ==="

run_test "Frame extraction (PNG)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/H264_AAC.mp4" -vf "select=eq(n\,0)" -vframes 1 "'$WORK_DIR'/frame.png" 2>/dev/null &&
  [ -f "'$WORK_DIR'/frame.png" ] && [ "$(stat -c %s "'$WORK_DIR'/frame.png")" -gt 100 ]
'

run_test "drawtext filter (freetype/libass)" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/video/H264_AAC.mp4" \
    -vf "drawtext=text='\''Test'\'':fontsize=24:fontcolor=white:x=10:y=10" \
    -c:v libx264 -c:a copy "'$WORK_DIR'/drawtext.mp4" 2>/dev/null &&
  [ -f "'$WORK_DIR'/drawtext.mp4" ] && [ "$(stat -c %s "'$WORK_DIR'/drawtext.mp4")" -gt 100 ]
'

# --- Image Tests ---

echo ""
echo "=== Image Conversion Tests ==="

run_test "PNG -> WebP" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/image/thinking-head.png" "'$WORK_DIR'/out.webp" 2>/dev/null &&
  [ -f "'$WORK_DIR'/out.webp" ] && [ "$(stat -c %s "'$WORK_DIR'/out.webp")" -gt 100 ]
'

run_test "BMP -> PNG" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/image/programming.bmp" "'$WORK_DIR'/out.png" 2>/dev/null &&
  [ -f "'$WORK_DIR'/out.png" ] && [ "$(stat -c %s "'$WORK_DIR'/out.png")" -gt 100 ]
'

run_test "WebP -> PNG" bash -c '
  ffmpeg -y -i "'$MEDIA_DIR'/image/alpha-lossy.webp" "'$WORK_DIR'/from_webp.png" 2>/dev/null &&
  [ -f "'$WORK_DIR'/from_webp.png" ] && [ "$(stat -c %s "'$WORK_DIR'/from_webp.png")" -gt 100 ]
'

# --- Summary ---

echo ""
echo "==============================="
echo "  Results: $PASSED/$TOTAL passed, $FAILED failed"
echo "==============================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
