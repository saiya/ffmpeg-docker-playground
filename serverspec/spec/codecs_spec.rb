require 'spec_helper'

describe 'codecs' do
  subject{ command 'ffmpeg -codecs' }
  
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
    h264: 'DEV.LS',
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
  }.each do |name, flags|
    it("should support #{name} (#{flags})"){
      expect(subject.stdout).to match /#{flags.gsub('.', '\\.')} #{name} / 
    }
  end

  %w(libx264 libx264rgb libx265 libfdk_aac libmp3lame libopus libvorbis).each do |encoder|
    it("should support encoder \"#{encoder}\""){
      expect(subject.stdout).to match /\(encoders:[^)]*#{encoder}[^)]*\)/
    }
  end
  %w(h264 hevc aac aac_fixed mp3 opus vorbis).each do |decoder|
    it("should support decoder \"#{decoder}\""){
      expect(subject.stdout).to match /\(decoders:[^)]*#{decoder}[^)]*\)/
    }
  end
end
