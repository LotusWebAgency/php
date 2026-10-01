<?php

return [
    // Where the php container reaches its own vhost: the compose service.
    'self_url' => env('APPTEST_SELF_URL', 'http://web'),

    // The set's php-min (X.Y): the PHP the goldens are recorded on. Anything a
    // newer PHP of the same set has and this one lacks must stay out of them.
    'php_min' => env('APPTEST_PHP_MIN'),
];
