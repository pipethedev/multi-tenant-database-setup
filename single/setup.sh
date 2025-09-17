#!/bin/bash

set -e

echo "Setting up simple PostgreSQL SNI proxy..."

# Create SSL directory
mkdir -p ssl

# Generate SSL certificates
echo "Generating SSL certificates..."

# CA certificate
openssl genrsa -out ssl/ca-key.pem 2048
openssl req -new -x509 -days 365 -key ssl/ca-key.pem -sha256 -out ssl/ca.pem -subj "/C=US/ST=CA/L=SF/O=Test/CN=Test CA"

# Wildcard certificate for *.postgres.brimble.app
openssl genrsa -out ssl/postgres-key.pem 2048
openssl req -subj "/CN=*.postgres.brimble.app" -sha256 -new -key ssl/postgres-key.pem -out ssl/postgres.csr

cat > ssl/postgres-ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.postgres.brimble.app
DNS.2 = postgres.brimble.app
EOF

openssl x509 -req -days 365 -sha256 -in ssl/postgres.csr -CA ssl/ca.pem -CAkey ssl/ca-key.pem -out ssl/postgres-cert.pem -extfile ssl/postgres-ext.cnf -CAcreateserial

# Combine cert and key for HAProxy
cat ssl/postgres-cert.pem ssl/postgres-key.pem > ssl/postgres.pem

# Set permissions
chmod 644 ssl/*.pem

# Cleanup
rm ssl/postgres.csr ssl/postgres-ext.cnf

echo "Creating HAProxy configuration..."

cat > haproxy.cfg <<'EOF'
global
    daemon
    log stdout local0 info

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5s
    timeout client 300s
    timeout server 300s
    retries 3

backend tenant_a_postgres
    mode tcp
    server postgres-a postgres-tenant-a:5432 check

backend tenant_b_postgres
    mode tcp
    server postgres-b postgres-tenant-b:5432 check

frontend postgres_sni_frontend
    bind *:5432
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    acl is_tenant_a req.ssl_sni -i tenant-a.postgres.brimble.app
    acl is_tenant_b req.ssl_sni -i tenant-b.postgres.brimble.app

    use_backend tenant_a_postgres if is_tenant_a
    use_backend tenant_b_postgres if is_tenant_b

    default_backend tenant_a_postgres # Optional: a default backend for non-SNI traffic
    
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF

echo "Setting up DNS entries..."

# Add DNS entries to /etc/hosts
sudo sh -c 'cat >> /etc/hosts << EOL

# PostgreSQL SNI Test
127.0.0.1 tenant-a.postgres.brimble.app
127.0.0.1 tenant-b.postgres.brimble.app
EOL'

# Test script
cat > test-sni.sh <<'EOF'
#!/bin/bash

echo "Testing PostgreSQL SNI routing..."
echo ""

echo "Waiting for services to start..."
sleep 10

echo "Testing Tenant A..."
PGPASSWORD="secure_password_a" timeout 10s psql -h tenant-a.postgres.brimble.app -p 5432 -U tenant_a_user -d tenant_a_db -c "SELECT 'Connected to Tenant A via SNI' as message, current_database();" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✓ Tenant A: SNI routing working"
else
    echo "✗ Tenant A: Connection failed"
fi

echo ""
echo "Testing Tenant B..."
PGPASSWORD="secure_password_b" timeout 10s psql -h tenant-b.postgres.brimble.app -p 5432 -U tenant_b_user -d tenant_b_db -c "SELECT 'Connected to Tenant B via SNI' as message, current_database();" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✓ Tenant B: SNI routing working"
else
    echo "✗ Tenant B: Connection failed"
fi

echo ""
echo "HAProxy Stats: http://localhost:8404/stats"
EOF

chmod +x test-sni.sh

echo ""
echo "Setup complete!"
echo ""
echo "Run these commands:"
echo "1. docker-compose up -d"
echo "2. ./test-sni.sh"
echo ""
echo "This tests if SNI routing works properly between two PostgreSQL databases."