# `ffmpeg` custom build dockerfile recipe

Encapsulate `ffmpeg` stuff into Docker image.

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
