#!/bin/sh
docker run -v /home/saiya/sample_mov:/mnt/sample_mov ffmpeg \
       ffprobe -v quiet -of xml -show_frames /mnt/sample_mov/IMG_6059.MOV
