# Ruby jemalloc

## Adding jemalloc via `LD_PRELOAD`

```dockerfile
FROM ruby:3.2-slim

RUN apt-get update ; \\
    apt-get install -y --no-install-recommends
      libjemalloc2 ; \\
    rm -rf /var/lib/apt/lists/*

# TODO: figure out how to LD_PRELOAD on arbitrary architectures dynamically
# /usr/lib/x86_64-linux-gnu/libjemalloc.so.2
# /usr/lib/aarch64-linux-gnu/libjemalloc.so.2
# /usr/lib/arm-linux-gnueabihf/libjemalloc.so.2
# /usr/lib/i386-linux-gnu/libjemalloc.so.2
# /usr/lib/powerpc64le-linux-gnu/libjemalloc.so.2
# /usr/lib/s390x-linux-gnu/libjemalloc.so.2
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
```

## Adding jemalloc at ruby compile time

```console
$ apt-get install -y --no-install-recommends libjemalloc-dev libjemalloc2
$ RUBY_CONFIGURE_OPTS="--with-jemalloc" rbenv install 3.2
```

## Patching Ruby binary to use jemalloc

```dockerfile
FROM ruby:3.2-slim
RUN apt-get update  && \\
  apt-get upgrade -y && \\
  apt-get install libjemalloc2 patchelf && \\
  patchelf --add-needed libjemalloc.so.2 /usr/local/bin/ruby && \\
  apt-get purge patchelf -y
```

## Detecting if jemalloc is being used

```console
$ MALLOC_CONF=stats_print:true /opt/rbenv/shims/ruby -e "exit" 2>&1 | grep "jemalloc statistics"
```
