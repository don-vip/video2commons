$consumer_key = 'REDACTED'
$consumer_secret = 'REDACTED'
$redis_pw = 'REDACTED'
$redis_host = 'video-redis-buster.video.eqiad1.wikimedia.cloud'
$http_host = 'v2c.wmflabs.org'

## BASIC INSTANCE SETUP

# include role::labs::lvm::srv

include cron

package { [
    'build-essential',
    'python3-dev',
    'python3-full',
    'python3-pip',
    'python3-setuptools',
]:
    ensure => present,
}

package { [
    'git',
    'wget'
]:
    ensure => present,
}

package { [
    'ffmpeg',
#    'ffmpeg2theora',
    'gstreamer1.0-plugins-good',
    'gstreamer1.0-plugins-ugly',
    'gstreamer1.0-plugins-bad',
]:
    ensure => latest,
}

package { 'nginx':
    ensure => present,
}

service { 'nginx':
    ensure  => running,
    enable  => true,
    require => Package['nginx']
}

## V2C BACKEND SETUP

exec { 'check-srv-mounted':
    command => '/bin/mount | /bin/grep /srv',
}

exec { 'git-clone-v2c':
    command => '/usr/bin/git clone https://github.com/toolforge/video2commons.git /srv/v2c',
    creates => '/srv/v2c/.git/config',
    require => [
        Package['git'],
        Exec['check-srv-mounted'],
    ],
}

exec { 'create-venv':
    command => '/usr/bin/python3 -m venv /srv/v2c/venv',
    creates => '/srv/v2c/venv',
    require => [
        Exec['git-clone-v2c'],
        Package['python3-full'],
    ],
}

file { [
    '/srv/v2c/output',
    '/srv/v2c/apicache',
]:
    ensure  => directory,
    owner   => 'tools.video2commons',
    group   => 'tools.video2commons',
    require => Exec['git-clone-v2c'],
    before  => Service['v2ccelery'],
}

file { '/srv/v2c/ssu':
    ensure  => link,
    target  => '/data/scratch/video2commons/ssu/',
    require => Exec['git-clone-v2c'],
    before  => Service['v2ccelery'],
}

file { '/srv/v2c/throttle.ctrl':
    ensure  => present, # content managed by pywikibot
    owner   => 'tools.video2commons',
    group   => 'tools.video2commons',
    require => Exec['git-clone-v2c'],
    before  => Service['v2ccelery'],
}

$config_json_template = '{
"consumer_key": "<%= @consumer_key %>",
"consumer_secret": "<%= @consumer_secret %>",
"api_url": "https://commons.wikimedia.org/w/index.php",
"redis_pw": "<%= @redis_pw %>",
"redis_host": "<%= @redis_host %>",
"http_host": "video2commons.toolforge.org/static/ssu",
"webfrontend_uri": "//video2commons.toolforge.org/",
"socketio_uri": "//video2commons-socketio.toolforge.org/socket.io"
}
'

file { '/srv/v2c/config.json':
    ensure  => file,
    content => inline_template($config_json_template),
    require => Exec['git-clone-v2c'],
    notify  => Service['v2ccelery'],
}

package { 'default-libmysqlclient-dev': # wanted by some pip packages
    ensure => present,
}

exec { 'git-pull-v2c':
    command => '/usr/bin/git --git-dir=/srv/v2c/.git --work-tree=/srv/v2c pull',
    require => [
        Exec['git-clone-v2c'],
    ],
    before  => Service['v2ccelery'],
}

exec { 'pip-install-requirements':
    command => '/srv/v2c/venv/bin/pip3 install -Ur /srv/v2c/video2commons/backend/requirements.txt',
    require => [
        Exec['git-pull-v2c'],
        Package['python3-dev'],
        Package['python3-pip'],
        Package['build-essential'],
        Package['default-libmysqlclient-dev'],
    ],
    before  => Service['v2ccelery'],
}

# lint:ignore:single_quote_string_with_variables
$celeryd_service = '# THIS FILE IS MANAGED BY MANUAL PUPPET
[Unit]
Description=v2c celery Service
After=network.target

[Service]
Type=forking
User=tools.video2commons
Group=tools.video2commons
EnvironmentFile=-/etc/default/v2ccelery
WorkingDirectory=/srv/v2c
Restart=on-failure
ExecStart=/bin/sh -c \'${CELERY_BIN} multi start $CELERYD_NODES \
    -A $CELERY_APP --logfile=${CELERYD_LOG_FILE} \
    --pidfile=${CELERYD_PID_FILE} $CELERYD_OPTS\'
ExecStop=/bin/sh -c \'${CELERY_BIN} multi stopwait $CELERYD_NODES \
    --pidfile=${CELERYD_PID_FILE}\'
ExecReload=/bin/sh -c \'${CELERY_BIN} multi restart $CELERYD_NODES \
    -A $CELERY_APP --pidfile=${CELERYD_PID_FILE} --logfile=${CELERYD_LOG_FILE} \
    --loglevel="${CELERYD_LOG_LEVEL}" $CELERYD_OPTS\'

[Install]
WantedBy=multi-user.target
'
# lint:endignore

file { '/lib/systemd/system/v2ccelery.service':
    ensure  => file,
    content => $celeryd_service,
    require => File['/etc/default/v2ccelery'],
    notify  => Service['v2ccelery'],
}

$celeryd_config = '# THIS FILE IS MANAGED BY MANUAL PUPPET
CELERYD_NODES=2
CELERY_BIN="/srv/v2c/venv/bin/celery"
CELERY_APP="video2commons.backend.worker"
CELERYD_MULTI="multi"
CELERYD_LOG_FILE="/var/log/v2ccelery/%N%I.log"
CELERYD_PID_FILE="/var/run/v2ccelery/%N.pid"
CELERYD_USER="tools.video2commons"
CELERYD_GROUP="tools.video2commons"
CELERY_CREATE_DIRS=1
'

file { '/etc/default/v2ccelery':
    ensure  => file,
    content => $celeryd_config,
    require => [
        File['/var/run/v2ccelery'],
        File['/var/log/v2ccelery'],
    ],
    notify  => Service['v2ccelery'],
}

$tmpfiles_config = '# THIS FILE IS MANAGED BY MANUAL PUPPET
d /var/run/v2ccelery 1777 root root -
d /var/log/v2ccelery 1777 root root -'

file { '/usr/lib/tmpfiles.d/v2ccelery.conf':
    ensure  => file,
    content => $tmpfiles_config,
}

file { [
    '/var/run/v2ccelery',
    '/var/log/v2ccelery',
]:
    ensure  => directory,
    owner   => 'tools.video2commons',
    group   => 'tools.video2commons',
    before  => Service['v2ccelery'],
    require => File['/usr/lib/tmpfiles.d/v2ccelery.conf'],
}

service { 'v2ccelery':
    ensure  => running,
    enable  => true,
    require => Package['ffmpeg'],
}

$logrotate_config = '# THIS FILE IS MANAGED BY MANUAL PUPPET
/var/log/v2ccelery/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    su tools.video2commons tools.video2commons
}
'

file { '/etc/logrotate.d/v2ccelery':
    ensure  => file,
    content => $logrotate_config,
    require => Service['v2ccelery'],
}

$nginx_config_template = '# THIS FILE IS MANAGED BY MANUAL PUPPET
server {
    listen 80;
    listen [::]:80;

    root /srv/v2c/ssu;

    server_name <%= @http_host %>;

    location / {
        try_files $uri $uri/ =404;
    }

    location = / {
        return 302 https://video2commons.toolforge.org/;
    }
}
'

file { '/etc/nginx/sites-available/video2commons':
    ensure  => file,
    content => inline_template($nginx_config_template),
    require => Service['v2ccelery'],
}

file { '/etc/nginx/sites-enabled/video2commons':
    ensure  => link,
    target  => '/etc/nginx/sites-available/video2commons',
    require => File['/etc/nginx/sites-available/video2commons'],
    notify  => Service['nginx'],
}

cron::job { 'v2ccleanup':
    command => '/bin/sh /srv/v2c/video2commons/backend/cleanup.sh',
    user    => 'tools.video2commons',
    minute  => '48',
    require => Service['v2ccelery'],
}
