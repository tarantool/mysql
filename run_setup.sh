#!/bin/bash

set -x

docker rm -f mysql
sleep 1
docker run \
	-v /tmp:/var/run/mysqld \
	--name mysql \
	-e MYSQL_ALLOW_EMPTY_PASSWORD=true \
	-p 3306:3306 \
	-i mysql \
		--character-set-server=utf8 \
		--collation-server=utf8_unicode_ci \
		--default_authentication_plugin=mysql_native_password &
sleep 5
docker logs mysql
