<?php

// Replaces the skeleton's stock api.php, which registers `api/user` as a
// closure. `artisan route:cache` refuses to serialize a closure route -- it
// fails the whole command with "Unable to prepare route [api/user] for
// serialization", so one uncached leftover route would mean the corpus trains
// the uncached bootstrap. Laravel 5.5 through 10 all ship this file and load
// it; Laravel 11+ only loads it when the app opts in, where an empty file is
// simply never read.
//
// The corpus' own JSON route lives in web.php with the rest, so nothing is
// lost by leaving this empty.
