#!/bin/bash
# Measurement helpers shared by the regression suite.
#
# Everything here answers one of three questions about a file this image produced:
#
#   * probe_*            what does the container SAY it is?   (mechanical, exact)
#   * mp4_faststart      is the moov box before the mdat?     (mechanical, exact)
#   * video_quality /    does it still look / sound like the  (perceptual, banded)
#     spectrogram_ssim / input?
#     audio_sdr_min
#
# The perceptual ones exist because "ffprobe says h264" is not the same statement as "the
# encode worked". A truncated, black or silent output is still a well-formed file with the
# right codec name in it, and only a signal comparison against the input can tell the
# difference.
#
# Sourced, not executed. No global state beyond the functions themselves.

# ---------------------------------------------------------------------------- probing

# Value of one ffprobe `stream=` entry, for one stream selector (e.g. v:0, a:0).
# Prints the empty string when the entry is absent, so callers can compare directly.
probe_stream() {
  local file="$1" select="$2" entry="$3"
  ffprobe -v error -select_streams "$select" -show_entries "stream=$entry" \
    -of default=nw=1:nk=1 "$file" | head -1 | tr -d '[:space:]'
}

# Value of one ffprobe `format=` entry.
probe_format() {
  local file="$1" entry="$2"
  ffprobe -v error -show_entries "format=$entry" -of default=nw=1:nk=1 "$file" |
    head -1 | tr -d '[:space:]'
}

probe_stream_count() {
  local file="$1" select="$2"
  ffprobe -v error -select_streams "$select" -show_entries stream=index \
    -of default=nw=1:nk=1 "$file" | grep -c .
}

# ---------------------------------------------------------------------------- MP4 boxes

# Top-level box types of an MP4/MOV file, in file order, one per line.
#
# Hand-parsed with dd/od because ffprobe does not report box ORDER, and the order is the
# entire content of the `+faststart` promise: a player that has to fetch the tail of a
# large file before it can start is the regression this catches. Only the first few boxes
# are ever needed, so this reads 8-byte headers and seeks - it never walks the payload.
mp4_top_level_boxes() {
  local file="$1"
  local total offset=0 size type
  total=$(stat -c %s "$file")
  while [ "$((offset + 8))" -le "$total" ]; do
    size=$(dd if="$file" bs=1 skip="$offset" count=4 status=none | od -An -tu4 --endian=big |
      tr -d ' \n')
    type=$(dd if="$file" bs=1 skip="$((offset + 4))" count=4 status=none | tr -cd '[:print:]')
    [ -n "$size" ] || break
    echo "$type"
    if [ "$size" -eq 1 ]; then
      # 64-bit size follows the type. Not produced for files this size, but a wrong
      # answer here would be worse than an early exit.
      size=$(dd if="$file" bs=1 skip="$((offset + 8))" count=8 status=none |
        od -An -tu8 --endian=big | tr -d ' \n')
      [ -n "$size" ] || break
    elif [ "$size" -eq 0 ]; then
      break # "to end of file"
    fi
    [ "$size" -ge 8 ] || break
    offset=$((offset + size))
  done
}

# True when `moov` precedes `mdat` - i.e. `-movflags +faststart` did its job.
mp4_faststart() {
  local file="$1" boxes moov mdat i=0
  boxes=$(mp4_top_level_boxes "$file")
  moov=-1
  mdat=-1
  while read -r box; do
    [ "$moov" -lt 0 ] && [ "$box" = "moov" ] && moov=$i
    [ "$mdat" -lt 0 ] && [ "$box" = "mdat" ] && mdat=$i
    i=$((i + 1))
  done <<<"$boxes"
  [ "$moov" -ge 0 ] || return 1
  [ "$mdat" -lt 0 ] && return 0
  [ "$moov" -lt "$mdat" ]
}

# ---------------------------------------------------------------------------- decoding

# The frame size as the DECODER produces it, printed as `<width>x<height>`.
#
# NOT ffprobe's width/height, which are the STORED size: this build applies container
# cropping (`clap`) and the display matrix on decode, so a rotated phone clip decodes to
# transposed dimensions and a cropped one to smaller ones. Downstream code that derives
# thumbnail geometry from the stored size gets it wrong on exactly that material, and
# `ssim`/`psnr` refuse mismatched frames outright - so this is read back from the tool
# rather than re-derived from the side data.
#
# The no-op `scale` filter is there only to make ffmpeg print its own configuration line;
# the regex requires DIGITS because the same filter also logs `w:iw h:ih` beforehand.
decoded_frame_size() {
  local file="$1"
  ffmpeg -nostdin -hide_banner -loglevel verbose -i "$file" -map 0:v:0 -frames:v 1 \
    -vf "scale,format=yuv420p" -f null - 2>&1 |
    grep -oP 'Parsed_scale_\d+ @ [^]]+\] w:\K\d+ h:\d+' | head -1 |
    sed -E 's/ h:/x/'
}

# SHA-256 of a file's decoded samples, in a caller-chosen PCM form.
#   pcm_sha256 <file> <sample-format> [filter]
# Two files with the same digest are the same audio, full stop - which is the only check
# strong enough for a LOSSLESS profile, where "close enough" is a bug.
pcm_sha256() {
  local file="$1" fmt="$2" filter="${3:-}"
  local args=(-nostdin -hide_banner -v error -i "$file" -map 0:a:0)
  [ -n "$filter" ] && args+=(-af "$filter")
  args+=(-c:a "pcm_$fmt" -f "${fmt}" -)
  ffmpeg "${args[@]}" | sha256sum | cut -d' ' -f1
}

# ---------------------------------------------------------------------- video quality

# `<psnr-db> <ssim>` of `test` against `ref`, computed in one pass.
#
# `settb=AVTB,setpts=PTS-STARTPTS` on both sides is load-bearing, not tidiness: the two
# files carry different time bases and often a non-zero start time, and framesync pairs
# frames by TIMESTAMP. Without the reset a 40 ms container offset silently compares frame
# N with frame N+1 and reports a PSNR ~10 dB too low - a measurement error that looks
# exactly like a real regression. `format=yuv420p` makes an 8-bit and a 10-bit decode of
# the same content comparable.
video_quality() {
  local ref="$1" test="$2" out psnr ssim
  local prep="settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p"
  out=$(ffmpeg -nostdin -hide_banner -i "$test" -i "$ref" -filter_complex \
    "[0:v]${prep},split=2[t1][t2];[1:v]${prep},split=2[r1][r2];[t1][r1]ssim[s];[s]nullsink;[t2][r2]psnr" \
    -f null - 2>&1)
  psnr=$(echo "$out" | grep -oP 'PSNR .*average:\K[0-9.]+' | tail -1)
  ssim=$(echo "$out" | grep -oP 'SSIM .*All:\K[0-9.]+' | tail -1)
  [ -n "$psnr" ] && [ -n "$ssim" ] || return 1
  echo "$psnr $ssim"
}

# ---------------------------------------------------------------------- audio quality
#
# Two files encoded by different codecs never line up sample for sample, so subtracting
# waveforms answers the wrong question. What a listener notices is the time-frequency
# energy distribution - which is what a spectrogram is a picture of. Rendering both sides
# under IDENTICAL settings and running SSIM (a perceptual IMAGE metric) over the two
# pictures turns "do these sound alike?" into a number.
#
# The settings are frozen here as constants because changing one silently invalidates
# every threshold measured against them.
#
#   fltp/44100/stereo - the encoders' native precision differs and quantisation is not
#                       what is being measured; showspectrumpic draws one band PER
#                       CHANNEL, so a mono/stereo pair would produce differently-shaped
#                       pictures and SSIM would compare apples to oranges.
#   1024x512, log     - fine enough that a real encoding difference moves the number,
#                       coarse enough that a one-sample offset does not.
#   mode=separate     - keeps channels in separate bands, so a swapped or collapsed
#                       channel is visible.
#   legend=disabled   - axis furniture would be identical pixels inflating every SSIM.
AUDIO_NORMALISE="aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo"
SPECTROGRAM="showspectrumpic=s=1024x512:mode=separate:legend=disabled:scale=log:color=intensity"

spectrogram_ssim() {
  local a="$1" b="$2" value
  value=$(ffmpeg -nostdin -hide_banner -i "$a" -i "$b" -filter_complex \
    "[0:a]${AUDIO_NORMALISE},${SPECTROGRAM}[sa];[1:a]${AUDIO_NORMALISE},${SPECTROGRAM}[sb];[sb][sa]ssim" \
    -f null - 2>&1 | grep -oP 'SSIM .*All:\K[0-9.]+' | tail -1)
  [ -n "$value" ] || return 1
  echo "$value"
}

# Worst per-channel signal-to-distortion ratio in dB, of `test` against `ref`.
#
# The time-domain counterpart of the spectrogram check, kept because it fails in a
# different direction: a constant time offset (a lost edit list, an encoder-delay
# regression) destroys SDR while barely moving spectrogram SSIM. Agreeing on both is a
# much stronger statement than agreeing on either.
audio_sdr_min() {
  local ref="$1" test="$2" value
  value=$(ffmpeg -nostdin -hide_banner -i "$ref" -i "$test" -filter_complex \
    "[0:a]${AUDIO_NORMALISE}[r];[1:a]${AUDIO_NORMALISE}[t];[r][t]asdr" \
    -f null - 2>&1 | grep -oP 'SDR ch\d+: \K(-?[0-9.]+|inf)' |
    awk 'BEGIN{m="";} {v=($0=="inf")?1e9:$0+0; if(m==""||v<m)m=v;} END{if(m!="")print m;}')
  [ -n "$value" ] || return 1
  echo "$value"
}

# ---------------------------------------------------------------------------- numbers
#
# No `bc` in this image, and none is wanted: awk is in coreutils' company and does the
# comparison in floating point without a second dependency.

num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
num_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }

# |1 - a/b| <= tol
ratio_within() {
  awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN {
    if (b == 0) exit 1
    d = 1 - a / b
    if (d < 0) d = -d
    exit !(d <= t)
  }'
}
