#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:-brb_source.jpg}"
OUTPUT="${2:-BRB_Australia_IRL_10s.mp4}"
DURATION=10
FPS=30
FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg is not installed." >&2
  exit 1
fi

if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: input image not found: $INPUT" >&2
  echo "Put your image next to this script and name it brb_source.jpg, or pass another file name." >&2
  exit 1
fi

if [[ ! -f "$FONT" ]]; then
  echo "ERROR: font not found: $FONT" >&2
  exit 1
fi

ffmpeg -y \
  -loop 1 -framerate "$FPS" -i "$INPUT" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
  -t "$DURATION" \
  -filter_complex "
    [0:v]
      scale=2200:1238:force_original_aspect_ratio=increase,
      crop=2200:1238,
      zoompan=
        z='1.02+0.025*sin(2*PI*on/(${FPS}*${DURATION}))':
        x='iw/2-(iw/zoom/2)+8*sin(2*PI*on/(${FPS}*${DURATION}))':
        y='ih/2-(ih/zoom/2)+5*cos(2*PI*on/(${FPS}*${DURATION}))':
        d=1:s=1920x1080:fps=${FPS},
      eq=saturation=1.08:contrast=1.04:brightness=-0.015,
      vignette=PI/5,
      drawbox=x=105:y=735:w=1710:h=250:color=black@0.64:t=fill,
      drawbox=x=105:y=735:w=1710:h=250:color=0xff8c00@0.90:t=4,
      drawtext=fontfile='${FONT}':
        text='СВЯЗЬ ВРЕМЕННО ПРЕРВАЛАСЬ':
        fontsize=68:fontcolor=white:
        borderw=3:bordercolor=black@0.8:
        x=(w-text_w)/2:y=775,
      drawtext=fontfile='${FONT}':
        text='Автор скоро вернётся':
        fontsize=46:fontcolor=0xffc400:
        borderw=2:bordercolor=black@0.8:
        x=(w-text_w)/2:y=865,
      drawtext=fontfile='${FONT}':
        text='Спасибо, что остаётесь с нами!':
        fontsize=30:fontcolor=white@0.90:
        borderw=2:bordercolor=black@0.7:
        x=(w-text_w)/2:y=930,
      drawtext=fontfile='${FONT}':text='.':fontsize=56:fontcolor=0xffc400:
        x=1185:y=855:enable='between(mod(t,3),0,3)',
      drawtext=fontfile='${FONT}':text='.':fontsize=56:fontcolor=0xffc400:
        x=1205:y=855:enable='between(mod(t,3),1,3)',
      drawtext=fontfile='${FONT}':text='.':fontsize=56:fontcolor=0xffc400:
        x=1225:y=855:enable='between(mod(t,3),2,3)',
      format=yuv420p[v]
  " \
  -map "[v]" -map 1:a:0 \
  -c:v libx264 \
  -preset medium \
  -profile:v high \
  -level 4.1 \
  -pix_fmt yuv420p \
  -r "$FPS" \
  -g 60 \
  -keyint_min 60 \
  -sc_threshold 0 \
  -b:v 4500k \
  -maxrate 4500k \
  -bufsize 9000k \
  -c:a aac \
  -b:a 128k \
  -ar 48000 \
  -movflags +faststart \
  -shortest \
  "$OUTPUT"

ffprobe -v error \
  -show_entries format=duration:stream=codec_name,width,height,r_frame_rate,sample_rate \
  -of default=noprint_wrappers=1 \
  "$OUTPUT"

echo
echo "Created: $(realpath "$OUTPUT")"
