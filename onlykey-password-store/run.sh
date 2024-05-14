#!/bin/bash
PORT=59827
BASE_DIR=./passwords php -S localhost:$PORT passwordStore.php &
echo "Server started on http://localhost: $PORT";
echo "You can kill the running instance with:";
echo "    killall passwordStore";
sleep 1
php -r '$ch = curl_init("http://localhost:59827");curl_exec($ch);'
