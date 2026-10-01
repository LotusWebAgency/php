<?php

namespace App\Providers;

use App\Events\PostCreated;
use App\Models\JobLog;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Redis\Connections\PhpRedisConnection;
use Illuminate\Cache\RedisStore;
use Illuminate\Contracts\Redis\Factory as RedisFactory;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register()
    {
        // APCu store (not in the skeleton's cache.php) and a redis connection
        // that stacks igbinary + zstd under phpredis, the combination the
        // images ship those extensions for.
        $config = $this->app['config'];
        $config->set('cache.stores.apc', ['driver' => 'apc']);
        $options = [];
        if (defined('Redis::SERIALIZER_IGBINARY')) {
            $options['serializer'] = \Redis::SERIALIZER_IGBINARY;
        }
        if (defined('Redis::COMPRESSION_ZSTD')) {
            $options['compression'] = \Redis::COMPRESSION_ZSTD;
        }
        // 5.x skeletons have no separate cache connection.
        $base = $config->get('database.redis.cache') ?: $config->get('database.redis.default');
        $config->set('database.redis.igbinary', array_merge($base, [
            'database' => '2',
            'options' => $options,
        ]));
        $config->set('cache.stores.redis_igbinary', [
            'driver' => version_compare($this->app->version(), '8.0', '<') ? 'redis_igbinary' : 'redis',
            'connection' => 'igbinary',
            'lock_connection' => 'igbinary',
        ]);
        // Users are App\Models\User here; the 5.x skeletons say App\User.
        $config->set('auth.providers.users.model', \App\Models\User::class);
    }

    public function boot()
    {
        // Before 8 the redis connector ignores serializer/compression options,
        // so the store gets its own phpredis client with them set.
        if (version_compare($this->app->version(), '8.0', '<')) {
            Cache::extend('redis_igbinary', function ($app) {
                $config = $app['config']['database.redis.igbinary'];
                $client = new \Redis();
                $client->connect($config['host'], (int) $config['port']);
                $client->select((int) $config['database']);
                foreach (['serializer' => \Redis::OPT_SERIALIZER, 'compression' => \Redis::OPT_COMPRESSION] as $name => $option) {
                    if (isset($config['options'][$name])) {
                        $client->setOption($option, $config['options'][$name]);
                    }
                }
                $factory = new class(new PhpRedisConnection($client)) implements RedisFactory {
                    private $connection;

                    public function __construct($connection)
                    {
                        $this->connection = $connection;
                    }

                    public function connection($name = null)
                    {
                        return $this->connection;
                    }
                };

                return Cache::repository(new RedisStore($factory, $app['config']['cache.prefix'], 'igbinary'));
            });
        }

        Event::listen(PostCreated::class, function (PostCreated $event) {
            JobLog::record('event', 'post-'.$event->post->id, $event->post->slug);
        });

        // The scheduler's events are registered here rather than in
        // routes/console.php (Schedule:: facade, 11+) or Console\Kernel (8-10),
        // so every framework generation gets them the same way.
        if ($this->app->runningInConsole()) {
            $this->app->booted(function () {
                $schedule = $this->app->make(Schedule::class);
                $schedule->command('apptest:heartbeat scheduled-command')->everyMinute();
                $schedule->call(function () {
                    JobLog::record('heartbeat', 'scheduled-closure', 'sapi='.PHP_SAPI);
                })->name('apptest-closure')->everyMinute();
            });
        }
    }
}
