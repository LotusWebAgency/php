# The matrix comes from matrix.gen.hcl, rendered from matrix.json by
# scripts/gen_matrix.py; never edit it by hand. Pass both files: bake only
# auto-loads docker-bake.hcl, and TARGETS and BASE_IMAGE live in the generated one.
#
#   docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl php-8_5-fpm
#   docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl pr

variable "PUSH" { default = false }

# Empty by default so a local build touches no registry and the default `docker`
# driver, which cannot export cache, still works. CI sets it to the cache
# repository: every php target reads the layers of the compile toolchain,
# ImageMagick and the deps stages from it, and the deps-cache target writes them.
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

# Registry cache scope: ARCH and CACHE_WEEK complete the ref (php version, uarch,
# arch, week) so concurrent writers never share one. CACHE_WEEK is the
# TOOLCHAIN_EPOCH week label without its optional ".N" suffix, which keeps the
# ref in the form .github/workflows/dev-prune.yml prunes by.
variable "ARCH" { default = "" }

# false makes CACHE_REGISTRY read-only (cache-from stays, cache-to is dropped).
variable "CACHE_PUSH" { default = true }
variable "CACHE_WEEK" { default = "" }
# Busts only the runtime apk layers when Wolfi's package index changes (see the
# Dockerfile's runtime-base stage); ci/wolfi-index-state.sh computes it.
variable "WOLFI_INDEX_STATE" { default = "" }
# Keys the compile toolchain (the Dockerfile's toolchain-base stage) and so
# everything built on it; ci/toolchain-epoch.sh prints it. Changes weekly, not with
# the Wolfi index, so the registry cache keeps hitting.
variable "TOOLCHAIN_EPOCH" { default = "" }

target "_common" {
  dockerfile = "Dockerfile"
  context    = "."
  args = {
    BASE_IMAGE        = BASE_IMAGE
    WOLFI_INDEX_STATE = WOLFI_INDEX_STATE
    TOOLCHAIN_EPOCH   = TOOLCHAIN_EPOCH
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
    # The base's repository and pinned digest, both split from BASE_IMAGE
    # (repo:tag@sha256:...) so they cannot drift from what the build used. The
    # name drops the @digest, then a :tag only when it follows the last "/" (a
    # registry port, host:5000/x, is not a tag); a digest-less override gets "".
    "org.opencontainers.image.base.name"      = regex_replace(split("@", BASE_IMAGE)[0], ":[^:/]*$", "")
    "org.opencontainers.image.base.digest"    = try(split("@", BASE_IMAGE)[1], "")
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
    # full (every flavor but the -slim ones) or slim: which root filesystem the
    # Dockerfile's runtime-base stage builds on (a global ARG, used only in FROM, so
    # php-build and the payload stages are shared by every flavor).
    RUNTIME_OS  = item.runtime_os
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
    "com.lotuswebagency.runtime-os"  = item.runtime_os
    "org.opencontainers.image.title" = "lotuswebagency/php ${item.php}-${item.flavor}"
    # The slim flavors say what they drop: the description is what registries show.
    "org.opencontainers.image.description" = item.support == "end-of-life" ? format(
      "PHP %s (%s) compiled from source with profile-guided optimization, hardened, on Wolfi.%s PHP %s reached end of life on %s and receives no upstream security fixes -- see the README for supported versions.",
      item.php, item.flavor, item.runtime_os == "slim" ? " Slim runtime: no package manager, curl or database client tools." : "", item.php, item.eol_date
    ) : format(
      "PHP %s (%s) compiled from source with profile-guided optimization, hardened, on Wolfi.%s",
      item.php, item.flavor, item.runtime_os == "slim" ? " Slim runtime: no package manager, curl or database client tools." : ""
    )
  }
  tags       = item.tags
  platforms  = item.platforms
  # Read-only: only deps-cache below exports. The ref is keyed on php+uarch+arch+week
  # because the layers it holds (toolchain, ImageMagick, deps) do not depend on the flavor.
  cache-from = CACHE_REGISTRY != "" ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${ARCH}-${CACHE_WEEK}"] : []
  output     = [PUSH ? "type=registry" : "type=docker"]
}

group "default" {
  targets = ["php"]
}

# Exports the registry cache: the `deps` stage (toolchain, ImageMagick, deps) of
# each fpm target, built to nothing but the cache. One target per php+uarch, since
# every flavor of a version shares those layers. mode=max with image-manifest and
# OCI media types stores the cache as an image manifest that registries accept.
# The export is best-effort (ignore-error=true): a registry error while writing the
# cache must not fail a build whose images are fine.
# Exports only when CACHE_REGISTRY is set and CACHE_PUSH is true; otherwise it
# builds the stage and writes no cache. No attestations: the output is no image.
target "deps-cache" {
  inherits = ["_common"]
  name     = "deps-cache-${item.name}"
  matrix   = { item = [for t in TARGETS : t if t.flavor == "fpm"] }
  target   = "deps"
  args = {
    PHP_VERSION     = item.php
    PHP_ERA         = item.era
    COMPILER        = item.compiler
    CXX_COMPILER    = item.compiler == "gcc" ? "g++" : "clang++"
    AR_COMPILER     = item.compiler == "gcc" ? "ar" : "llvm-ar"
    RANLIB_COMPILER = item.compiler == "gcc" ? "ranlib" : "llvm-ranlib"
    NM_COMPILER     = item.compiler == "gcc" ? "nm" : "llvm-nm"
  }
  attest     = []
  platforms  = item.platforms
  cache-from = CACHE_REGISTRY != "" ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${ARCH}-${CACHE_WEEK}"] : []
  cache-to   = CACHE_REGISTRY != "" && CACHE_PUSH ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${ARCH}-${CACHE_WEEK},mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true"] : []
  output     = ["type=cacheonly"]
}

group "deps-cache" {
  targets = [for t in TARGETS : "deps-cache-${t.name}" if t.flavor == "fpm"]
}

# The PR subset: both ends of the range, where breakage concentrates, one
# mid-range version, the heaviest flavor, cli plus ext-builder (one CI leg, so one
# php-build), and the slim flavors on the ends (a slim rides its host's leg).
# Mirrors PR_SUBSET in scripts/gen_matrix.py, which
# tests/preflight.sh cross-checks.
group "pr" {
  targets = ["php-7_0-fpm", "php-8_2-fpm", "php-8_5-fpm", "php-8_5-cli-builder", "php-8_5-cli", "php-8_5-ext-builder", "php-8_5-fpm-slim", "php-8_5-cli-slim", "php-7_0-fpm-slim"]
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
