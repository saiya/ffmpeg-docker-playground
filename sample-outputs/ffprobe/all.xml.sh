#!/bin/sh
docker run -v /home/saiya/sample_mov:/mnt/sample_mov ffmpeg \
       ffprobe -v quiet -of xml \
       -show_error -show_format -show_frames -show_log 100 -show_programs -show_streams \
       /mnt/sample_mov/IMG_6059.MOV

# Omitted: -show_data(_hash) -show_packets -show_chapters
