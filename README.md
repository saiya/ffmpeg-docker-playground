# `ffmpeg` custom build dockerfile recipe

Encapsulate `ffmpeg` stuff into Docker image.

This repository provides [Dockerfile](./Dockerfile) so that you can build docker image contains `ffmpeg` binary easily.

Caution: should not redistribute resulted container image unless you are sure licence terms of ALL libraries used in this build.

## Usage

```
docker build . -t ffmpeg    # take a coffee break

# To run command in generated container, just use `docker run`
# Some examples are placed at sample-outputs/*/*.sh
```

## Testing

```
# To run serverspec, ruby and `gem install bundler` required
pushd serverspec
bundle install
bundle exec rspec   # Run serverspec with 'ffmpeg' image
popd
```

## Update libraries

Modify version number `ARG`s in `Dockerfile`, then run `docker build` and `rspec` (serverspec) again.
