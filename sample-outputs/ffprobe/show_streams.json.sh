#!/bin/sh
docker run -v /home/saiya/sample_mov:/mnt/sample_mov ffmpeg \
       ffprobe -v quiet -of json -show_streams /mnt/sample_mov/IMG_6059.MOV
