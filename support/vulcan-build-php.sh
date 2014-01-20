#!/bin/bash
# vulcan build -v -c "./vulcan-build-php.sh" -p /app/vendor/php -o php-${PHP_VERSION}-with-fpm-heroku.tar.gz

## EDIT
source ./set-env.sh
## END EDIT

set -e
set -o pipefail

orig_dir=$( pwd )

mkdir -p /app/vendor/php  # create php folder

mkdir -p build && pushd build

echo "+ Fetching libmcrypt libraries..."
# install mcrypt for portability.
mkdir -p /app/local
curl -L "https://${S3_BUCKET}.s3.amazonaws.com/libmcrypt-${LIBMCRYPT_VERSION}.tar.gz" -o - | tar xz -C /app/local

echo "+ Fetching libmemcached libraries..."
mkdir -p /app/local
curl -L "https://${S3_BUCKET}.s3.amazonaws.com/libmemcached-${LIBMEMCACHED_VERSION}.tar.gz" -o - | tar xz -C /app/local

echo "+ Fetching libicu libraries..."
mkdir -p /app/local
curl -L "https://${S3_BUCKET}.s3.amazonaws.com/libicu-${LIBICU_VERSION}.tar.gz" -o - | tar xz -C /app/local

echo "+ Fetching PHP sources..."
#fetch php, extract
curl -L http://us.php.net/get/php-$PHP_VERSION.tar.bz2/from/www.php.net/mirror -o - | tar xj

mkdir -p "/app/vendor/php/etc/conf.d"

install_zend_optimizer=":"

if [[ "$php_version" =~ 5.5 ]]; then
    install_zend_optimizer=$(cat << SH
    echo "zend_extension=opcache.so" >> /app/vendor/php/etc/conf.d/opcache.ini
SH
)
else
    install_zend_optimizer=$(cat <<SH
    /app/vendor/php/bin/pecl install ZendOpcache-beta \
        && echo "zend_extension=\$(/app/vendor/php/bin/php-config --extension-dir)/opcache.so" >> /app/vendor/php/etc/conf.d/opcache.ini
SH
)
fi

pushd php-$PHP_VERSION

echo "+ Configuring PHP..."
# new configure command
## WARNING: libmcrypt needs to be installed.
./configure \
--prefix=/app/vendor/php \
--with-config-file-path=/app/vendor/php \
--with-config-file-scan-dir=/app/vendor/php/etc.d \
--disable-debug \
--disable-rpath \
--enable-bcmath \
--enable-sockets \
--enable-exif \
--enable-fpm \
--enable-gd-native-ttf \
--enable-inline-optimization \
--enable-shmop \
--enable-libxml \
--enable-mbregex \
--enable-mbstring \
--enable-pcntl \
--enable-soap=shared \
--enable-zip \
--enable-intl \
--with-bz2 \
--with-curl \
--with-gd \
--with-gettext \
--with-jpeg-dir \
--with-mcrypt=/app/local \
--with-icu-dir=/app/local \
--with-iconv \
--with-mhash \
--with-mysql \
--with-mysqli \
--with-openssl \
--with-pcre-regex \
--with-pdo-mysql \
--with-pgsql \
--with-pdo-pgsql \
--with-png-dir \
--with-readline \
--with-zlib \
--enable-opcache=no

echo "+ Compiling PHP..."
# build & install it
make install

popd

# update path
export PATH=/app/vendor/php/bin:$PATH

# configure pear
pear config-set php_dir /app/vendor/php

if [[ "$php_version" =~ 5.5 ]]; then
	echo Skipping APC because of PHP 5.5
else
	echo "+ Installing APC..."
	# install apc from source
	curl -L http://pecl.php.net/get/APC-${APC_VERSION}.tgz -o - | tar xz
	pushd APC-${APC_VERSION}
	# php apc jokers didn't update the version string in 3.1.10.
	sed -i 's/PHP_APC_VERSION "3.1.9"/PHP_APC_VERSION "3.1.10"/g' php_apc.h
	phpize
	./configure --enable-apc --enable-apc-filehits --with-php-config=/app/vendor/php/bin/php-config
	make && make install
	popd
fi

echo "+ Installing memcache..."
# install memcache

set +e
set +o pipefail
yes '' | pecl install memcache-beta
# answer questions
# "You should add "extension=memcache.so" to php.ini"
set -e
set -o pipefail


echo "+ Installing memcached from source..."
# install apc from source
curl -L http://pecl.php.net/get/memcached-${MEMCACHED_VERSION}.tgz -o - | tar xz
pushd memcached-${MEMCACHED_VERSION}
# edit config.m4 line 21 so no => yes ############### IMPORTANT!!! ###############
sed -i -e '21 s/no, no/yes, yes/' ./config.m4
sed -i -e '18 s/no, no/yes, yes/' ./config.m4
phpize
./configure --with-libmemcached-dir=/app/local --with-php-config=/app/vendor/php/bin/php-config
make && make install
popd

echo "+ Installing phpredis..."
# install phpredis
git clone git://github.com/nicolasff/phpredis.git
pushd phpredis
git checkout ${PHPREDIS_VERSION}

phpize
./configure
make && make install
# add "extension=redis.so" to php.ini
popd

echo "+ Installing mongoclient from source..."
# install mongoclient
git clone https://github.com/mongodb/mongo-php-driver.git
pushd mongo-php-driver
git checkout ${MONGOCLIENT_VERSION}

phpize
./configure
make && make install
# add "extension=mongo.so" to php.ini
popd

echo "+ Installing TWIG from source..."
# install twig.so
git clone https://github.com/fabpot/Twig.git
pushd Twig
git checkout v${TWIG_VERSION}
pushd ext/twig

phpize
./configure
make && make install
# add "extension=twig.so" to php.ini
popd
popd

echo "+ Installing XCache..."
# install xcache from source
curl -L http://xcache.lighttpd.net/pub/Releases/${XCACHE_VERSION}/xcache-${XCACHE_VERSION}.tar.gz -o - | tar xz
pushd xcache-${XCACHE_VERSION}
phpize
./configure --enable-xcache --with-php-config=/app/vendor/php/bin/php-config
make && make install
popd

echo "+ Installing Imagick..."
# install imagick from source
curl -L http://pecl.php.net/get/imagick-${IMAGICK_VERSION}.tgz -o - | tar xz
pushd imagick-${IMAGICK_VERSION}
phpize
./configure --with-php-config=/app/vendor/php/bin/php-config
make && make install
popd

echo "+ Install newrelic..."
curl -L "http://download.newrelic.com/php_agent/archive/${NEWRELIC_VERSION}/newrelic-php5-${NEWRELIC_VERSION}-linux.tar.gz" | tar xz
pushd newrelic-php5-${NEWRELIC_VERSION}-linux
cp -f agent/x64/newrelic-`phpize --version | grep "Zend Module Api No" | tr -d ' ' | cut -f 2 -d ':'`.so `php-config --extension-dir`/newrelic.so
popd

echo "+ Install Zend optimizer..."
$install_zend_optimizer

echo "+ Packaging PHP..."
# package PHP
echo ${PHP_VERSION} > /app/vendor/php/VERSION

popd

echo "+ Done!"

