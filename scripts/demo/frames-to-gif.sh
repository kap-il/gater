#!/bin/sh
# frames-to-gif.sh <frames-dir> <out.gif> [fps] [width]
set -eu
fps="${3:-12}"; w="${4:-1000}"
ffmpeg -loglevel error -y -framerate 12.5 -i "$1/%05d.png" \
  -vf "fps=$fps,scale=$w:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$2"
