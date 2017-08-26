# `ffmpeg` custom build dockerfile recipe

Encapsulate `ffmpeg` stuff into Docker image.

## Usage

```
docker build . -t ffmpeg
# ... take a coffee break ...

# To run serverspec, ruby and `gem install bundler` required
pushd serverspec
bundle install
bundle exec rspec   # Run serverspec with 'ffmpeg' image
popd
```

## Update libraries

Modify version number `ARG`s in `Dockerfile`, then run `docker build` and `rspec` (serverspec) again.

## Set apt sources

- This `Dockerfile` loads `ubuntu/xenial/sources.list.ap-northeast-1.ec2`, should change to other `sources.list` file for other environment (or just comment out `ADD` line to use Ubuntu default `sources.list`)
