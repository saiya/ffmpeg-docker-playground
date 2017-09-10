#!/bin/sh
docker run -v /home/saiya/sample_mov:/mnt/sample_mov ffmpeg \
       ffprobe -h
