#!/usr/bin/env bash
# Runs in the app tree after the overlay is copied. The 5.5 skeleton hard-codes
# the redis client to predis; the phpredis connector is in the framework, it
# only needs the setting to follow REDIS_CLIENT like 5.7+ does.
set -euo pipefail
grep -q "'client' => 'predis'" config/database.php
sed -i "s/'client' => 'predis'/'client' => env('REDIS_CLIENT', 'predis')/" config/database.php
