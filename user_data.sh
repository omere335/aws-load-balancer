#!/bin/bash
set -e

WEB_SERVER_COUNT=${web_server_count}
BASE_PORT=8000

# Install Docker
dnf update -y
dnf install -y docker
systemctl start docker
systemctl enable docker

# Start web server containers
for i in $(seq 1 $WEB_SERVER_COUNT); do
  PORT=$((BASE_PORT + i))
  docker run -d \
    --name "webserver-$i" \
    --restart unless-stopped \
    -p "$PORT:80" \
    nginx
done

# Generate nginx load balancer config
{
  echo "events {}"
  echo "http {"
  echo "  upstream webservers {"
  for i in $(seq 1 $WEB_SERVER_COUNT); do
    PORT=$((BASE_PORT + i))
    echo "    server 127.0.0.1:$PORT;"
  done
  echo "  }"
  echo "  server {"
  echo "    listen 80;"
  echo "    location / { proxy_pass http://webservers; }"
  echo "    location /health { proxy_pass http://webservers; }"
  echo "  }"
  echo "}"
} > /tmp/nginx-lb.conf

# Start load balancer
docker run -d \
  --name loadbalancer \
  --restart unless-stopped \
  --network host \
  -v /tmp/nginx-lb.conf:/etc/nginx/nginx.conf:ro \
  nginx
