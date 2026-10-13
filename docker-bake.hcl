# The matrix comes from matrix.gen.hcl, rendered from matrix.json by
# scripts/gen_matrix.py; never edit it by hand. Pass both files: bake only
# auto-loads docker-bake.hcl, and TARGETS and BASE_IMAGE live in the generated one.
#
#   docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl php-8_5-fpm
#   docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl pr

variable "PUSH" { default = false }

# Empty by default so a local build touches no registry and the default `docker`
# driver, which cannot export cache, still works. CI sets ghcr.io/lotuswebagency/php.
variable "CACHE_REGISTRY" { default = "" }

# What the image was built from, not when: scripts/inputs-hash.sh's output
# (tests/build-all.sh exports it). A label rather than a Dockerfile ARG, because
# an ARG declared in a stage busts that stage's layer cache. tests/smoke.sh
# recomputes it from the working tree and fails an image whose label differs or
# is missing.
variable "INPUTS_HASH" { default = "" }

# CI feeds both through same-named environment variables: the built commit SHA
# and the build timestamp. Unset locally, REVISION is "unknown" and CREATED is
# the time bake evaluates this file.
variable "REVISION" { default = "" }
variable "CREATED" { default = "" }

# Cache-ref disambiguators, also fed from the environment. A mode=max export
# replaces the whole ref, so no ref may have two concurrent writers:
#   - ARCH: the amd64 and arm64 runners build the same php/uarch pair.
#   - CACHE_WEEK: an ISO week suffix rotates the ref weekly, so the first build
#     of each week starts cache-empty and re-resolves apt packages; a stale ref
#     would replay old Debian packages and fail Trivy on fixable HIGHs.
variable "ARCH" { default = "" }

# false makes CACHE_REGISTRY read-only (cache-from stays, cache-to is dropped).
# CI's verify job (PR and develop builds) sets it, so only the publishing job on
# main writes a cache ref.
variable "CACHE_PUSH" { default = true }
variable "CACHE_WEEK" { default = "" }

target "_common" {
  dockerfile = "Dockerfile"
  context    = "."
  args = {
    BASE_IMAGE = BASE_IMAGE
  }
  labels = {
    "org.opencontainers.image.source"        = "https://github.com/LotusWebAgency/php"
    "org.opencontainers.image.url"           = "https://hub.docker.com/r/lotuswebagency/php"
    "org.opencontainers.image.documentation" = "https://github.com/LotusWebAgency/php#readme"
    "org.opencontainers.image.licenses"      = "MIT"
    "org.opencontainers.image.vendor"        = "Lotus Web Agency"
    "org.opencontainers.image.authors"       = "Vasilii Dementev https://vasiliidementev.com"
    "org.opencontainers.image.revision"      = REVISION != "" ? REVISION : "unknown"
    "org.opencontainers.image.created"       = CREATED != "" ? CREATED : timestamp()
    "com.lotuswebagency.inputs-hash"         = INPUTS_HASH
  }
  # A list, not two --set flags: a second `--set '*.attest=...'` replaces the
  # first and would drop the SBOM. Push only: the docker exporter a local build
  # uses does not always carry attestations.
  attest = PUSH ? ["type=sbom", "type=provenance,mode=max"] : []
}

target "php" {
  inherits = ["_common"]
  name     = item.name
  matrix   = { item = TARGETS }
  target   = item.flavor
  args = {
    PHP_VERSION  = item.php
    PHP_RELEASE  = item.release
    PHP_ERA      = item.era
    UARCH        = item.uarch
    COMPILER     = item.compiler
    # The Dockerfile cannot derive clang++/g++ from COMPILER, so bake supplies
    # the other binary names. Plain ar/ranlib/nm for gcc, not the gcc-ar family:
    # the gcc path never produces LTO bytecode (GCC's LTRANS rejects
    # zend_jit_vm_helpers.c's global register variable).
    CXX_COMPILER    = item.compiler == "gcc" ? "g++" : "clang++"
    AR_COMPILER     = item.compiler == "gcc" ? "ar" : "llvm-ar"
    RANLIB_COMPILER = item.compiler == "gcc" ? "ranlib" : "llvm-ranlib"
    NM_COMPILER     = item.compiler == "gcc" ? "nm" : "llvm-nm"
    PGO         = item.pgo
    ICU_VERSION = item.icu
  }
  # The PGO training corpus for this version's tier, mounted by the Dockerfile's
  # php-build stage. item.corpus comes from scripts/gen_matrix.py: a version maps
  # to the tier with the greatest floor at or below it.
  # With the default `docker` driver, buildx resolves docker-image:// contexts
  # from the daemon's image store, where tests/build-corpus.sh leaves them.
  contexts = {
    corpus = "docker-image://${item.corpus}"
  }
  # tests/smoke.sh keys its VM-kind expectation on compiler (gcc -> HYBRID,
  # clang -> TAILCALL), so the image records which compiler built it. These
  # labels merge with _common's. support/eol-date come from matrix.json via
  # scripts/gen_matrix.py; an end-of-life version also gets the warning in the
  # OCI description, where registries display it.
  labels = {
    "com.lotuswebagency.compiler"    = item.compiler
    "com.lotuswebagency.support"     = item.support
    "com.lotuswebagency.eol-date"    = item.eol_date
    "org.opencontainers.image.title" = "lotuswebagency/php ${item.php}-${item.flavor}"
    "org.opencontainers.image.description" = item.support == "end-of-life" ? format(
      "PHP %s (%s) compiled from source with profile-guided optimization, hardened, on debian:trixie-slim. PHP %s reached end of life on %s and receives no upstream security fixes -- see the README for supported versions.",
      item.php, item.flavor, item.php, item.eol_date
    ) : "PHP ${item.php} (${item.flavor}) compiled from source with profile-guided optimization, hardened, on debian:trixie-slim."
  }
  tags       = item.tags
  platforms  = item.platforms
  # Keyed on php+uarch+flavor+arch+week; ARCH and CACHE_WEEK are pure cache
  # disambiguators (see above) and are empty in a local build.
  # item.cache_flavor is the flavor whose scope a target shares: ext-builder is
  # built with cli (RIDES_WITH in scripts/gen_matrix.py), so it reads cli's scope
  # and exports none of its own.
  cache-from = CACHE_REGISTRY != "" ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${item.cache_flavor}-${ARCH}-${CACHE_WEEK}"] : []
  cache-to   = CACHE_REGISTRY != "" && CACHE_PUSH && item.cache_flavor == item.flavor ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${item.flavor}-${ARCH}-${CACHE_WEEK},mode=max"] : []
  output     = [PUSH ? "type=registry" : "type=docker"]
}

group "default" {
  targets = ["php"]
}

# The PR subset: both ends of the range, where breakage concentrates, one
# mid-range version, the heaviest flavor, and cli plus ext-builder (one CI leg,
# so one php-build). Mirrors PR_SUBSET in scripts/gen_matrix.py, which
# tests/preflight.sh cross-checks.
group "pr" {
  targets = ["php-7_0-fpm", "php-8_2-fpm", "php-8_5-fpm", "php-8_5-cli-builder", "php-8_5-cli", "php-8_5-ext-builder"]
}

# ------------------------------------------------------------------ bootstrap
# A tier's corpus (tests/build-corpus.sh, php/pgo/Dockerfile.corpus) is built from
# that floor's cli-builder, and every php target mounts a corpus. From an empty
# daemon the two targets below break that cycle. They belong to neither group
# "default" nor "pr"; tests/build-corpus.sh uses them only when no real
# cli-builder image exists.
target "bootstrap-empty-corpus" {
  dockerfile = "php/pgo/Dockerfile.bootstrap-corpus"
  context    = "."
  args = {
    BASE_IMAGE  = BASE_IMAGE
    INPUTS_HASH = INPUTS_HASH
  }
  tags   = ["lotuswebagency/php:bootstrap-empty-corpus"]
  labels = { "com.lotuswebagency.bootstrap" = "true" }
  output = ["type=docker"]
}

target "php-cli-builder-bootstrap" {
  inherits = ["_common"]
  name     = item.name
  matrix   = { item = BOOTSTRAP_TARGETS }
  target   = "cli-builder"
  args = {
    PHP_VERSION = item.php
    PHP_RELEASE = item.release
    PHP_ERA     = item.era
    UARCH       = "baseline"
    COMPILER        = item.compiler
    CXX_COMPILER    = item.compiler == "gcc" ? "g++" : "clang++"
    AR_COMPILER     = item.compiler == "gcc" ? "ar" : "llvm-ar"
    RANLIB_COMPILER = item.compiler == "gcc" ? "ranlib" : "llvm-ranlib"
    NM_COMPILER     = item.compiler == "gcc" ? "nm" : "llvm-nm"
    # Always false: a bootstrap image only exists to build the real corpus.
    PGO         = "false"
    ICU_VERSION = item.icu
  }
  # The placeholder corpus from the target above. Referencing it by target name
  # makes bake build it first, so one invocation works from an empty daemon.
  contexts = {
    corpus = "target:bootstrap-empty-corpus"
  }
  labels = {
    "com.lotuswebagency.compiler"  = item.compiler
    "com.lotuswebagency.bootstrap" = "true"
  }
  tags      = ["lotuswebagency/php:${item.php}-cli-builder-bootstrap"]
  platforms = ["linux/amd64"]
  output    = ["type=docker"]
}

group "bootstrap" {
  targets = ["php-cli-builder-bootstrap"]
}
