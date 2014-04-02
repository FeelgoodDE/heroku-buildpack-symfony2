#!/usr/bin/env bash

echo "Booting nginx"
export XCACHE_TEST=1   # Hide X-Cache warnings on CLI

# Symfony2 database detection
if [ -r /app/app/config/parameters_prod.yml.erb ]; then
	erb /app/app/config/parameters_prod.yml.erb > /app/app/config/parameters.yml
fi

# Landing page detection
if [ -r /app/app/config/build_time ]; then
	timestamp=\`cat /app/app/config/build_time\`
else
	timestamp=\$(date +%s)
fi
if [ -r /app/web/landingPage.html ]; then
	echo "Found landingPage - patching CDN into assets ..."
	sed --regexp-extended --in-place -e "s/(https?:\/\/[^\/]*)?\/assets\//https:\/\/\${CDN_BASE_URL_HTTPS_STATIC}\/assets\//" /app/web/landingPage.html
	sed --regexp-extended --in-place -e "s/\{cachebuster\}|c=[0-9]+/c=\${timestamp}/" /app/web/landingPage.html
fi
if [ -r /app/web/landingPage.html ]; then
	echo "Found individualized landingPages - patching CDN into assets ..."
	sed --regexp-extended --in-place -e "s/(https?:\/\/[^\/]*)?\/assets\//https:\/\/\${CDN_BASE_URL_HTTPS_STATIC}\/assets\//" /app/web/lp*.html
	sed --regexp-extended --in-place -e "s/\{cachebuster\}|c=[0-9]+/c=\${timestamp}/" /app/web/lp/*.html
fi

# Override config files if provided in app.
if [ -d /app/conf ]; then

	mkdir -p /app/conf/nginx.d

	if [ -d /app/conf/etc.d ]; then
		cp -f /app/conf/etc.d/* /app/vendor/php/etc.d/
	fi

	if [ -r /app/conf/php-fpm.conf ]; then
		cp -f /app/conf/php-fpm.conf /app/vendor/php/etc/php-fpm.conf
	fi

	if [ -r /app/conf/php.ini ]; then
		cp -f /app/conf/php.ini /app/vendor/php/php.ini
	fi

	if [ -r /app/conf/nginx.conf.erb ]; then
		cp -f /app/conf/nginx.conf.erb /app/vendor/nginx/conf/nginx.conf.erb
	fi

fi

# Set correct port variable.
erb /app/vendor/nginx/conf/nginx.conf.erb > /app/vendor/nginx/conf/nginx.conf

if [ -d /app/conf/nginx.d ]; then
	# Parse .erb into .conf.
	for f in /app/conf/nginx.d/*.erb
	do
		if [ -r "\${f}" ];
		then
			erb "\${f}" > "\${f}.conf"
		fi
	done
fi

# Set NEWRELIC key
if [ "\${NEW_RELIC_LICENSE_KEY}" ]; then
	if [ -w "/app/vendor/php/etc.d/04_newrelic.ini" ]; then
		echo "Setting NEWRELIC license from ENV (\${NEW_RELIC_LICENSE_KEY}) ... "
		sed -i "s|REPLACE_WITH_REAL_KEY|\${NEW_RELIC_LICENSE_KEY}|g" /app/vendor/php/etc.d/04_newrelic.ini
	else
		echo "No writable 04_newrelic.ini config file found. Skipping new relic key from ENV ..."
	fi
else
	if [ -r /app/vendor/php/etc.d/04_newrelic.ini ]; then
		echo "No new Relic license found, disabling New Relic extension ..."
		echo "-->   Please set NEW_RELIC_LICENSE_KEY config variable   <--"
		rm /app/vendor/php/etc.d/04_newrelic.ini
	fi
fi

# Preserve current php-fpm.conf so that env list does
# not go out of hand across restarts.
if [ -r /app/vendor/php/etc/php-fpm.conf.current ]; then
	cp -f /app/vendor/php/etc/php-fpm.conf.current /app/vendor/php/etc/php-fpm.conf
else
	cp -f /app/vendor/php/etc/php-fpm.conf /app/vendor/php/etc/php-fpm.conf.current
fi

# Expose Heroku config vars to PHP-FPM processes
for var in \`env | cut -f1 -d=\`; do
	echo "env[\$var] = \\$\${var}" >> /app/vendor/php/etc/php-fpm.conf
done

# Warmup Cache again because of changing pathes between build and live systems
# Currently hardcoded to prod environment. Has to be adjusted.
php -dmemory_limit=256M app/console cache:warmup --no-debug  --no-interaction --env=prod

touch /app/vendor/nginx/logs/access.log /app/vendor/nginx/logs/error.log /app/vendor/php/var/log/php-fpm.log /app/vendor/php/var/log/php-errors.log /app/local/var/log/newrelic/newrelic-daemon.log /app/local/var/log/newrelic/php_agent.log
mkdir -p client_body_temp fastcgi_temp proxy_temp scgi_temp uwsgi_temp
(tail -f -n 0 /app/vendor/nginx/logs/*.log /app/vendor/php/var/log/*.log /app/local/var/log/newrelic/*.log &)

if [ "\${NEW_RELIC_LICENSE_KEY}" -a ! -f /app/local/NEWRELIC_VERSION ]; then
	/app/local/bin/newrelic-daemon -c /app/local/etc/newrelic.cfg -d error
fi
/app/vendor/php/sbin/php-fpm

if [[ "\${BEHAT_RUNNER}" == "1" ]]; then
    echo "This is a behat runner so we are starting nginx as a daemon..."
    nohup /app/vendor/nginx/sbin/nginx &
else
    echo "This is not a behat runner so we are starting nginx the regular way..."
    /app/vendor/nginx/sbin/nginx
fi

export PYTHONPATH=\${PYTHONPATH}:/app/vendor/setuptools/lib/python2.7/site-packages/
export PHING_HOME="$BUILD_DIR/$PHING_PATH"

if [ -z "\${BEHAT_RUNNER}" ] && [ \${BEHAT_RUNNER} == "1" ]
then
	echo "Starting Behat ..."
	cd /app
	bin/behat --name "Questionnaire" &
fi

EOF
chmod +x boot.sh

cat >>bootWorker.sh <<EOF
#!/usr/bin/env bash

echo "Booting worker"
export XCACHE_TEST=1   # Hide X-Cache warnings on CLI

# Symfony2 database detection
if [ -r /app/app/config/parameters_prod.yml.erb ]; then
	erb /app/app/config/parameters_prod.yml.erb > /app/app/config/parameters.yml
fi

if [ -r /app/vendor/php/etc.d/08_xcache.ini ]; then
	echo "Detected X-Cache config. Disabling for worker ..."
	rm /app/vendor/php/etc.d/08_xcache.ini
fi

# Warmup Cache again because of changing pathes between build and live systems
# Currently hardcoded to prod environment. Has to be adjusted.
php -dmemory_limit=256M app/console cache:warmup --no-debug  --no-interaction --env=prod

if [ -r /app/app/config/supervisord.conf ]; then
	echo "Found SupervisorD config"
	echo "Preparing logfiles ..."

	# Get all logfiles from supervisorD config
	logfiles="`cat app/config/supervisord.conf | grep '_logfile' | awk 'BEGIN { FS = "=" } ; {print \$2}'`"

	#Try to iterate over each line
	mkdir -p /app/log/supervisor
	for logfile in \$logfiles
	do
