describe command 'ffmpeg -codecs' do
  let(:disable_sudo) { true }
  
  subject{ stdout }

  let(:codecs){
    # D..... = Decoding supported
    # .E.... = Encoding supported
    # ..V... = Video codec
    # ..A... = Audio codec
    # ..S... = Subtitle codec
    # ...I.. = Intra frame-only codec
    # ....L. = Lossy compression
    # .....S = Lossless compression
    {
      flv1: 'DEV.L.',
      # encoders: libx264 libx264rgb h264_nvenc nvenc nvenc_h264
      # decoders: h264 h264_cuvid 
      h264: 'DEV.LS',
      # decoders: hevc hevc_cuvid
      # encoders: libx265 nvenc_hevc hevc_nvenc
      hevc: 'DEV.L.',  # H.265 / HEVC
      mpeg1video: 'DEV.L.',
      mpeg2video: 'DEV.L.',
      mpeg4: 'DEV.L.',
      theora: 'DEV.L.',
      vp8: 'DEV.L.',
      vp9: 'DEV.L.',
      wmv1: 'DEV.L.',
      wmv2: 'DEV.L.',
      wmv3: 'D.V.L.',

      # (decoders: aac aac_fixed libfdk_aac ) (encoders: aac libfdk_aac )
      aac: 'DEA.L.',
      alac: 'DEA..S',  # Apple Lossless
      amr_nb: 'D.A.L.',
      amr_wb: 'D.A.L.',
      ape: 'D.A..S',
      flac: 'DEA..S',
      # (decoders: mp3 mp3float ) (encoders: libmp3lame )
      mp3: 'DEA.L.',
      # (decoders: opus libopus ) (encoders: opus libopus )
      opus: 'DEA.L.',
      # (decoders: vorbis libvorbis ) (encoders: vorbis libvorbis )
      vorbis: 'DEA.L.',
      wmapro: 'D.A.L.',
      wmav1: 'DEA.L.',
      wmav2: 'DEA.L.',
    }
  }
  it{
    is_expected.to match /x264/
  }
end

describe command 'pkg-config libavformat --modversion' do
  it{ expect(exit_status).to eq 0 }
  it{ expect(stderr).to be_empty }
end
