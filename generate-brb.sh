#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:-brb_source.jpg}"
OUTPUT="${2:-BRB_Australia_IRL_10s.mp4}"
DURATION="${DURATION:-10}"
FPS="${FPS:-30}"
WIDTH=1920
HEIGHT=1080
TOTAL_FRAMES=$((FPS * DURATION))

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg is not installed." >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ERROR: ffprobe is not installed." >&2
  exit 1
fi

if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: input image not found: $INPUT" >&2
  echo "Put the image next to this script as brb_source.jpg, or pass another file name." >&2
  exit 1
fi

TMP_OUTPUT="${OUTPUT%.*}.tmp.mp4"
rm -f "$TMP_OUTPUT"

# The source image already contains all wording and graphic design.
# This script adds only motion and finishing effects:
# - seamless breathing zoom and tiny camera drift
# - gentle colour/brightness pulse
# - subtle vignette and film grain
# - short low-opacity digital glitch flashes
# - silent AAC track so the file is stream-safe

ffmpeg -hide_banner -y \
  -loop 1 -framerate "$FPS" -i "$INPUT" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
  -t "$DURATION" \
  -filter_complex "
    [0:v]
      scale=2304:1296:force_original_aspect_ratio=increase,
      crop=2304:1296,
      zoompan=
        z='1.035+0.018*(1-cos(2*PI*on/${TOTAL_FRAMES}))/2':
        x='iw/2-(iw/zoom/2)+10*sin(2*PI*on/${TOTAL_FRAMES})':
        y='ih/2-(ih/zoom/2)+6*cos(2*PI*on/${TOTAL_FRAMES})':
        d=1:s=${WIDTH}x${HEIGHT}:fps=${FPS},
      setsar=1,
      eq=eval=frame:
        contrast='1.045+0.015*sin(2*PI*t/${DURATION})':
        brightness='-0.018+0.008*sin(2*PI*t/${DURATION})':
        saturation='1.08+0.025*sin(2*PI*t/${DURATION})',
      vignette=angle=PI/5.2:eval=frame,
      noise=alls=2.2:allf=t+u,
      split=2[clean][glitchsrc];

    [glitchsrc]
      crop=${WIDTH}:110:0:430,
      rgbashift=rh=10:bh=-8:gh=3,
      format=rgba,
      colorchannelmixer=aa=0.18[glitch];

    [clean][glitch]
      overlay=x='18*sin(35*t)':y=430:
        enable='between(mod(t,5),4.72,4.82)+between(mod(t,7),6.45,6.53)',
      format=yuv420p[v]
  " \
  -map "[v]" -map 1:a:0 \
  -c:v libx264 \
  -preset medium \
  -profile:v high \
  -level 4.1 \
  -pix_fmt yuv420p \
  -r "$FPS" \
  -g $((FPS * 2)) \
  -keyint_min $((FPS * 2)) \
  -sc_threshold 0 \
  -b:v 4500k \
  -maxrate 4500k \
  -bufsize 9000k \
  -c:a aac \
  -b:a 128k \
  -ar 48000 \
  -movflags +faststart \
  -shortest \
  "$TMP_OUTPUT"

mv -f "$TMP_OUTPUT" "$OUTPUT"

ffprobe -v error \
  -show_entries format=duration:stream=codec_name,width,height,r_frame_rate,sample_rate \
  -of default=noprint_wrappers=1 \
  "$OUTPUT"

echo
echo "Created: $(realpath "$OUTPUT")"
echo "Source:  $(realpath "$INPUT")"
echo "Effects: seamless zoom, drift, colour pulse, vignette, grain and subtle glitch"
