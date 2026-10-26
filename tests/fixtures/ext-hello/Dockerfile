# Test-only: tests/test-ext-builder.sh builds the fpm and cli targets from the
# context of this directory. Mirrors the multi-stage example in the README --
# ext-builder compiles, the runtime flavor of the same PHP version gets the .so.
ARG PHP_VERSION
ARG PHP_IMAGE=lotuswebagency/php
# "" or "-v3": the microarchitecture variant of all three images.
ARG TAG_SUFFIX=

FROM ${PHP_IMAGE}:${PHP_VERSION}-ext-builder${TAG_SUFFIX} AS ext
COPY . /src
RUN /src/build.sh /out

FROM ${PHP_IMAGE}:${PHP_VERSION}-fpm${TAG_SUFFIX} AS fpm
COPY --from=ext /out/ /

FROM ${PHP_IMAGE}:${PHP_VERSION}-cli${TAG_SUFFIX} AS cli
COPY --from=ext /out/ /
