#!/bin/bash

set -e

echo "🚀 Setting up Traefik PostgreSQL Proxy..."

mkdir -p traefik certs
chmod 600 certs

if [ ! -f "traefik/traefik.yml" ]; then
    cat > traefik/traefik.yml << 'EOF'
global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: true

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /etc/traefik
    watch: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
  postgres:
    address: ":5432"

certificatesResolvers:
  letsencrypt:
    acme:
      tlsChallenge: {}
      email: hello@brimble.app
      storage: /certs/acme.json

log:
  level: INFO

accessLog: {}
EOF
fi

touch certs/acme.json
chmod 600 certs/acme.json

echo "📝 Adding local DNS entries..."
if ! grep -q "x.brimble.app" /etc/hosts; then
    echo "127.0.0.1 x.brimble.app" | sudo tee -a /etc/hosts
fi
if ! grep -q "y.brimble.app" /etc/hosts; then
    echo "127.0.0.1 y.brimble.app" | sudo tee -a /etc/hosts
fi
if ! grep -q "z.brimble.app" /etc/hosts; then
    echo "127.0.0.1 z.brimble.app" | sudo tee -a /etc/hosts
fi

echo "Starting Traefik containers..."
docker-compose up -d

echo "Waiting for services to be ready..."
sleep 10

echo "Checking Traefik container status..."
docker-compose ps

echo ""
echo "Setup complete!"
echo ""
echo "📊 Traefik Dashboard: http://localhost:8080"
echo ""
echo " Test connections:"
echo "   PostgreSQL A: psql -h x.brimble.app -p 5432 -U postgres -d testdb_a"
echo "   PostgreSQL B: psql -h y.brimble.app -p 5432 -U postgres -d testdb_b"
echo "   PostgreSQL C: psql -h z.brimble.app -p 5432 -U postgres -d testdb_c"
echo ""
echo "Password for all databases: password123"