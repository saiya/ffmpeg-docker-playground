require 'spec_helper'

describe 'pkg-config' do
  # Enalbed by build option: filter, postproc, resample
  %w(libavcodec libavfilter libavformat libavresample libavutil libpostproc libswresample libswscale).each do |lib|
    describe lib do
      subject{ command "pkg-config #{lib} --modversion" }
      it('successfully found'){ expect(subject.exit_status).to eq 0 }
      it('no stderr output'){ expect(subject.stderr).to be_empty }
    end
  end
end

