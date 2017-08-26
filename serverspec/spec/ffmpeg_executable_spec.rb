require 'spec_helper'

describe 'ffmpeg command' do
  describe '/usr/local/bin/ffmpeg' do
    it("is ffmpeg command location"){ expect(command('which ffmpeg').stdout.strip).to eq subject }
  end

  describe 'build options' do
    subject{ command 'ffmpeg -buildconf' }

    %w(--enable-shared --disable-debug --disable-doc --disable-ffplay --enable-gpl --enable-nonfree --enable-version3 --enable-pthreads).each do |option|
      it("should contain '#{option}'"){ expect(subject.stdout).to match option }
    end
  end
end

describe 'ffprobe command' do
  describe '/usr/local/bin/ffprobe' do
    it("is ffprobe command location"){ expect(command('which ffprobe').stdout.strip).to eq subject }
  end
end
