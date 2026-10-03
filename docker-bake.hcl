# Matrix comes from matrix.gen.hcl, rendered from matrix.json by
# scripts/gen_matrix.py. Never edit matrix.gen.hcl by hand.
#
# Both files have to be passed: bake only auto-loads docker-bake.hcl, and TARGETS
# and BASE_IMAGE live in the generated one.
#
#   docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl php-8_5-fpm
#   docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl pr

variable "PUSH" { default = false }

# Empty by default so a local build neither reads from nor writes to a registry
# it has no credentials for -- and so the default `docker` driver, which cannot
# export cache at all, still works. CI sets it to ghcr.io/lotuswebagency/php.
variable "CACHE_REGISTRY" { default = "" }

# CF-47/T15-P: what the image was built FROM, not when. Fed from the
# environment by scripts/inputs-hash.sh's output (tests/build-all.sh exports
# it before every build); a label rather than a Dockerfile ARG, so a rebuild
# with an unchanged tree still hits layer cache -- an ARG would bust it on
# every invocation since the hash itself would differ run to run only if the
# tree changed, but threading it through as an ARG still forces a rebuild of
# every stage that declares it regardless. tests/smoke.sh recomputes this
# value against the working tree and compares it to what the image actually
# carries; a mismatch or a missing label means the image does not correspond
# to the tree under test.
variable "INPUTS_HASH" { default = "" }

# Both overridable by an env var of the same name (bake binds one automatically
# to a declared variable), which is how CI is meant to feed them: the commit
# SHA it built and the build's own timestamp, for a reproducible label instead
# of "whenever this got baked". Locally, with neither set, REVISION falls back
# to a plain "unknown" and CREATED to the moment bake evaluates this file --
# a sensible default, not a real provenance claim.
variable "REVISION" { default = "" }
variable "CREATED" { default = "" }

# Cache-ref disambiguators, fed from the environment the same way. Every one is
# needed to keep a registry cache ref (mode=max, a full replace of that ref's
# manifest on every export, not an additive merge) from being written by more
# than one concurrent job:
#   - ARCH: build's matrix crosses target x {amd64, arm64} -- two native
#     runners building the same php/uarch pair would otherwise fight over one
#     ref and the loser's cache silently vanishes.
#   - CACHE_WEEK: the weekly cron rebuilds the same base digest with the same
#     runtime-packages.txt, so an unrotated cache ref would just replay last
#     week's Debian packages forever and Trivy would fail every run on
#     fixable HIGHs with nothing new to fix. An ISO week suffix means the
#     first build each week starts that scope cache-empty and picks up
#     whatever apt-get install resolves to that day.
variable "ARCH" { default = "" }

# false makes CACHE_REGISTRY read-only: cache-from stays, cache-to is dropped.
# CI's verify job (PR and develop builds that never publish) sets it so that
# only the publishing build job on main ever writes a cache ref -- a mode=max
# export is a full replace of the ref, and a second writer on the same scope is
# exactly the clobber ARCH exists to prevent.
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
  # first rather than appending, which would silently drop the SBOM. Only on a
  # push -- attestations describe a published artifact, and the docker exporter
  # a local build uses does not always carry them.
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
    # The Dockerfile's toolchain stage cannot derive clang++/g++ (etc.) from
    # COMPILER by string manipulation, so bake resolves the other three
    # binary names here, once, from the same item.compiler every tag already
    # carries. Plain ar/ranlib/nm for gcc, not the gcc-ar/gcc-ranlib/gcc-nm
    # LTO-plugin wrappers: task 37a's gcc path never produces LTO bytecode
    # (task 33b -- GCC's LTRANS pass rejects zend_jit_vm_helpers.c's global
    # register variable), so there is nothing for the plugin-aware wrappers to
    # read, and task 35's gcc16 build already verified plain ar/ranlib/nm
    # against this exact toolchain.
    CXX_COMPILER    = item.compiler == "gcc" ? "g++" : "clang++"
    AR_COMPILER     = item.compiler == "gcc" ? "ar" : "llvm-ar"
    RANLIB_COMPILER = item.compiler == "gcc" ? "ranlib" : "llvm-ranlib"
    NM_COMPILER     = item.compiler == "gcc" ? "nm" : "llvm-nm"
    PGO         = item.pgo
    ICU_VERSION = item.icu
  }
  # The PGO training corpus for this version's tier (task 16), mounted by the
  # Dockerfile's php-build stage. item.corpus comes from scripts/gen_matrix.py,
  # which derives it from scripts/pgo_tiers.py -- a version maps to the tier
  # with the greatest floor at or below it, so adding PHP 8.6 to matrix.json
  # picks up the 8.2 corpus with no edit here.
  #
  # Not a registry pull in a local build: with the default `docker` driver
  # buildx resolves docker-image:// contexts against the daemon's own image
  # store, which is where ./tests/build-corpus.sh leaves them. Nothing in this
  # repo pushes a corpus.
  contexts = {
    corpus = "docker-image://${item.corpus}"
  }
  # Task 37b: tests/smoke.sh's VM-kind expectation is keyed on compiler, not on
  # PHP version (gcc -> HYBRID, clang -> TAILCALL), so the image has to say
  # which one built it -- reading it back from matrix.json alone would only
  # prove the *intent*, not that this build actually used it. Merges with
  # _common's labels (a child target's `labels` map unions with, rather than
  # replaces, the parent's -- verified with `bake --print`), so the OCI labels
  # above still apply.
  #
  # support/eol-date come straight from matrix.json (via
  # scripts/gen_matrix.py, validated there) -- never hand-set per version here.
  # For an end-of-life version, the same facts get folded into the OCI
  # description too, so the warning shows up wherever a registry surfaces that
  # field and not just in a label a human has to know to look for.
  labels = {
    "com.lotuswebagency.compiler"    = item.compiler
    "com.lotuswebagency.support"     = item.support
    "com.lotuswebagency.eol-date"    = item.eol_date
    "org.opencontainers.image.title" = "lotuswebagency/php ${item.php}-${item.flavor}"
    "org.opencontainers.image.description" = item.support == "end-of-life" ? format(
      "PHP %s (%s) compiled from source with profile-guided optimisation, hardened, on debian:trixie-slim. PHP %s reached end of life on %s and receives no upstream security fixes -- see the README for supported versions.",
      item.php, item.flavor, item.php, item.eol_date
    ) : "PHP ${item.php} (${item.flavor}) compiled from source with profile-guided optimisation, hardened, on debian:trixie-slim."
  }
  tags       = item.tags
  platforms  = item.platforms
  # Keyed on php+uarch+flavor+arch(+week): the first three vary what actually
  # gets built (php-build/final-stage layers differ per flavor too, since
  # `target = item.flavor` picks a different Dockerfile stage), and ARCH/
  # CACHE_WEEK are pure cache disambiguators (see the variables above) with no
  # effect on the image itself. A local build leaves ARCH/CACHE_WEEK empty, so
  # the ref degrades to the same php-uarch-flavor-- CI always sets both.
  #
  # item.cache_flavor is the flavor whose scope a target shares: ext-builder
  # is built in the same bake invocation as cli (scripts/gen_matrix.py's
  # RIDES_WITH), so it reads cli's scope and exports none of its own -- a second
  # mode=max export of the same php-build layers, written concurrently into a
  # ref of its own, would only cost registry storage.
  cache-from = CACHE_REGISTRY != "" ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${item.cache_flavor}-${ARCH}-${CACHE_WEEK}"] : []
  cache-to   = CACHE_REGISTRY != "" && CACHE_PUSH && item.cache_flavor == item.flavor ? ["type=registry,ref=${CACHE_REGISTRY}/cache:${item.php}-${item.uarch}-${item.flavor}-${ARCH}-${CACHE_WEEK},mode=max"] : []
  output     = [PUSH ? "type=registry" : "type=docker"]
}

group "default" {
  targets = ["php"]
}

# The PR subset: oldest and newest ends where breakage concentrates,
# one mid-range version, the heaviest flavor, and cli plus ext-builder (one CI
# leg, one bake invocation, so one php-build; it also runs
# tests/test-ext-builder.sh against that version's fpm and cli). Mirrors
# scripts/gen_matrix.py's PR_SUBSET, which tests/preflight.sh cross-checks.
group "pr" {
  targets = ["php-7_0-fpm", "php-8_2-fpm", "php-8_5-fpm", "php-8_5-cli-builder", "php-8_5-cli", "php-8_5-ext-builder"]
}

# ------------------------------------------------------------------ bootstrap
# Task 37c: from a daemon with no lotuswebagency/php* images and no corpus images,
# nothing can build at all -- a tier's corpus (tests/build-corpus.sh,
# php/pgo/Dockerfile.corpus) is built from that tier floor's cli-builder
# image, and every php target (including a cli-builder) mounts a corpus. The
# two targets below break that cycle. Neither is part of group "default" or
# group "pr" -- tests/build-corpus.sh reaches for one only when both the real
# cli-builder and the bootstrap tag are missing (see its own comment), and
# nothing else in this repo ever should.
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
    # Always false: a bootstrap image trains no PGO profile, it only exists to
    # build the real corpus that a real, PGO=true release build then mounts.
    # This is the one place PGO=false is hardcoded rather than read off
    # matrix.json's per-version flag -- the release rule (every published
    # image is PGO-built against a real corpus) stays matrix.json's alone.
    PGO         = "false"
    ICU_VERSION = item.icu
  }
  # The placeholder from the target above, never a real per-tier corpus --
  # that is the whole point of a bootstrap build. Referencing it by target
  # name (rather than a tag + docker-image://) makes bake build it first
  # automatically, so one `bake php-cli-builder-bootstrap` invocation is
  # enough from a truly empty daemon.
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
