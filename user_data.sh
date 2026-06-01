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
  cat > /tmp/nginx-ws-$i.conf << EOF
server {
  listen 80;
  location / {
    root /usr/share/nginx/html;
    index index.html;
  }
  location /health {
    return 200 "healthy - port $PORT\n";
    add_header Content-Type text/plain;
  }
}
EOF
  docker run -d \
    --name "webserver-$i" \
    --restart unless-stopped \
    -p "$PORT:80" \
    -v /tmp/nginx-ws-$i.conf:/etc/nginx/conf.d/default.conf:ro \
    nginx
done

# Generate nginx load balancer config
UPSTREAM_SERVERS=""
for i in $(seq 1 $WEB_SERVER_COUNT); do
  PORT=$((BASE_PORT + i))
  UPSTREAM_SERVERS="$UPSTREAM_SERVERS    server 127.0.0.1:$PORT;"$'\n'
done

cat > /tmp/nginx-lb.conf << EOF
events {}
http {
  upstream webservers {
$UPSTREAM_SERVERS  }
  server {
    listen 80;
    location / { proxy_pass http://webservers; }
    location /health { proxy_pass http://webservers; }
  }
}
EOF

# Start load balancer
docker run -d \
  --name loadbalancer \
  --restart unless-stopped \
  --network host \
  -v /tmp/nginx-lb.conf:/etc/nginx/nginx.conf:ro \
  nginx
