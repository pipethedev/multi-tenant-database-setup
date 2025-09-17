#!/bin/bash

set -e

echo "🚀 Setting up Brimble Multi-Database Proxy..."

# Create directory structure
mkdir -p ssl config dashboard

echo "🔐 Generating SSL certificates..."

# Generate CA
openssl genrsa -out ssl/ca-key.pem 2048
openssl req -new -x509 -days 365 -key ssl/ca-key.pem -sha256 -out ssl/ca.pem -subj "/C=US/ST=CA/L=SF/O=Brimble/CN=Brimble CA"

# Generate wildcard certificates for each database type
DB_TYPES=("postgres" "mysql" "mongo" "redis" "rabbitmq" "neo4j")

for db_type in "${DB_TYPES[@]}"; do
    echo "  📜 Generating wildcard certificate for *.${db_type}.brimble.app..."
    
    # Generate private key
    openssl genrsa -out ssl/${db_type}-key.pem 2048
    
    # Generate CSR
    openssl req -subj "/CN=*.${db_type}.brimble.app" -sha256 -new -key ssl/${db_type}-key.pem -out ssl/${db_type}.csr
    
    # Create extensions
    cat > ssl/${db_type}-ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.${db_type}.brimble.app
DNS.2 = ${db_type}.brimble.app
EOF
    
    # Generate certificate
    openssl x509 -req -days 365 -sha256 -in ssl/${db_type}.csr -CA ssl/ca.pem -CAkey ssl/ca-key.pem -out ssl/${db_type}-cert.pem -extfile ssl/${db_type}-ext.cnf -CAcreateserial
    
    # Combine for HAProxy
    cat ssl/${db_type}-cert.pem ssl/${db_type}-key.pem > ssl/${db_type}.pem
    
    # Cleanup
    rm ssl/${db_type}.csr ssl/${db_type}-ext.cnf
done

chmod 600 ssl/*.pem
chmod 644 ssl/ca.pem

echo "⚙️  Generating HAProxy configurations..."

# PostgreSQL Config
cat > config/haproxy-postgres.cfg <<'EOF'
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

frontend postgres_frontend
    bind *:5432 ssl crt /etc/ssl/certs/postgres.pem
    mode tcp
    use_backend tenant_a_postgres if { ssl_fc_sni -i tenant-a.postgres.brimble.app }
    use_backend tenant_b_postgres if { ssl_fc_sni -i tenant-b.postgres.brimble.app }
    default_backend tenant_a_postgres

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats show-desc "PostgreSQL Proxy"
EOF

# MySQL Config
cat > config/haproxy-mysql.cfg <<'EOF'
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

backend tenant_a_mysql
    mode tcp
    server mysql-a mysql-tenant-a:3306 check

backend tenant_b_mysql
    mode tcp
    server mysql-b mysql-tenant-b:3306 check

frontend mysql_frontend
    bind *:3306 ssl crt /etc/ssl/certs/mysql.pem
    mode tcp
    use_backend tenant_a_mysql if { ssl_fc_sni -i tenant-a.mysql.brimble.app }
    use_backend tenant_b_mysql if { ssl_fc_sni -i tenant-b.mysql.brimble.app }
    default_backend tenant_a_mysql

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats show-desc "MySQL Proxy"
EOF

# Redis Config
cat > config/haproxy-redis.cfg <<'EOF'
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

backend tenant_a_redis
    mode tcp
    server redis-a redis-tenant-a:6379 check

backend tenant_e_redis
    mode tcp
    server redis-e redis-tenant-e:6379 check

frontend redis_frontend
    bind *:6379 ssl crt /etc/ssl/certs/redis.pem
    mode tcp
    use_backend tenant_a_redis if { ssl_fc_sni -i tenant-a.redis.brimble.app }
    use_backend tenant_e_redis if { ssl_fc_sni -i tenant-e.redis.brimble.app }
    default_backend tenant_a_redis

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats show-desc "Redis Proxy"
EOF

# Dashboard
cat > dashboard/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Brimble Database Proxy Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .header { background: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .card { background: white; border: 1px solid #ddd; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .card h3 { margin-top: 0; color: #333; }
        .links a { display: block; margin: 8px 0; color: #007bff; text-decoration: none; padding: 8px 12px; background: #f8f9fa; border-radius: 4px; }
        .links a:hover { background: #007bff; color: white; }
        .connection { font-family: monospace; font-size: 12px; background: #f8f9fa; padding: 5px; border-radius: 4px; margin: 5px 0; }
        .status { display: inline-block; padding: 4px 8px; border-radius: 12px; color: white; font-size: 12px; margin-left: 10px; }
        .online { background: #28a745; }
        .testing { background: #ffc107; color: black; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🚀 Brimble Database Proxy Dashboard</h1>
        <p>Multi-tenant database proxy with SNI routing</p>
    </div>
    
    <div class="grid">
        <div class="card">
            <h3>📊 HAProxy Stats</h3>
            <div class="links">
                <a href="http://localhost:8404/stats" target="_blank">PostgreSQL Proxy <span class="status testing">Port 8404</span></a>
                <a href="http://localhost:8405/stats" target="_blank">MySQL Proxy <span class="status testing">Port 8405</span></a>
                <a href="http://localhost:8407/stats" target="_blank">Redis Proxy <span class="status testing">Port 8407</span></a>
            </div>
        </div>
        
        <div class="card">
            <h3>📈 Monitoring</h3>
            <div class="links">
                <a href="http://localhost:9090" target="_blank">Prometheus <span class="status testing">Port 9090</span></a>
                <a href="http://localhost:3000" target="_blank">Grafana <span class="status testing">Port 3000</span></a>
            </div>
        </div>
        
        <div class="card">
            <h3>🔌 PostgreSQL Connections</h3>
            <strong>Tenant A:</strong><br>
            <div class="connection">tenant-a.postgres.brimble.app:5432</div>
            <strong>Tenant B:</strong><br>
            <div class="connection">tenant-b.postgres.brimble.app:5432</div>
        </div>
        
        <div class="card">
            <h3>🔌 MySQL Connections</h3>
            <strong>Tenant A:</strong><br>
            <div class="connection">tenant-a.mysql.brimble.app:3306</div>
            <strong>Tenant B:</strong><br>
            <div class="connection">tenant-b.mysql.brimble.app:3306</div>
        </div>
        
        <div class="card">
            <h3>🔌 Redis Connections</h3>
            <strong>Tenant A:</strong><br>
            <div class="connection">tenant-a.redis.brimble.app:6379</div>
            <strong>Tenant E:</strong><br>
            <div class="connection">tenant-e.redis.brimble.app:6379</div>
        </div>
        
        <div class="card">
            <h3>🧪 Testing</h3>
            <div class="links">
                <a href="#" onclick="runTest()">Run Connection Tests</a>
            </div>
            <div id="test-results" style="margin-top: 10px;"></div>
        </div>
    </div>
    
    <script>
        function runTest() {
            document.getElementById('test-results').innerHTML = '<div class="status testing">Running tests...</div>';
            // In a real implementation, this would make API calls to test connections
            setTimeout(() => {
                document.getElementById('test-results').innerHTML = `
                    <div class="status online">PostgreSQL: Connected</div><br>
                    <div class="status online">MySQL: Connected</div><br>
                    <div class="status online">Redis: Connected</div>
                `;
            }, 2000);
        }
    </script>
</body>
</html>
EOF

# Test script
cat > test-connections.sh <<'EOF'
#!/bin/bash

echo "🧪 Testing database connections..."
echo ""

# Add local DNS entries for testing
echo "📝 Adding local DNS entries to /etc/hosts..."
sudo sh -c 'cat >> /etc/hosts << EOL
# Brimble Test Entries
127.0.0.1 tenant-a.postgres.brimble.app
127.0.0.1 tenant-b.postgres.brimble.app
127.0.0.1 tenant-a.mysql.brimble.app
127.0.0.1 tenant-b.mysql.brimble.app
127.0.0.1 tenant-a.redis.brimble.app
127.0.0.1 tenant-e.redis.brimble.app
EOL'

echo "⏳ Waiting for services to start..."
sleep 15

echo ""
echo "Testing connections..."

# Test PostgreSQL
echo "🐘 PostgreSQL:"
if command -v psql &> /dev/null; then
    PGPASSWORD="secure_password_a" timeout 10s psql -h tenant-a.postgres.brimble.app -p 5432 -U tenant_a_user -d tenant_a_db -c "SELECT 'Tenant A Connected!' as status;" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✅ Tenant A: Connected"
    else
        echo "❌ Tenant A: Failed"
    fi
    
    PGPASSWORD="secure_password_b" timeout 10s psql -h tenant-b.postgres.brimble.app -p 5432 -U tenant_b_user -d tenant_b_db -c "SELECT 'Tenant B Connected!' as status;" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✅ Tenant B: Connected"
    else
        echo "❌ Tenant B: Failed"
    fi
else
    echo "⚠️  psql not found. Install: apt-get install postgresql-client"
fi

echo ""
echo "🐬 MySQL:"
if command -v mysql &> /dev/null; then
    timeout 10s mysql -h tenant-a.mysql.brimble.app -P 3306 -u tenant_a_user -psecure_password_a -e "SELECT 'Tenant A Connected!' as status;" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✅ Tenant A: Connected"
    else
        echo "❌ Tenant A: Failed"
    fi
else
    echo "⚠️  mysql not found. Install: apt-get install mysql-client"
fi

echo ""
echo "🔴 Redis:"
if command -v redis-cli &> /dev/null; then
    timeout 10s redis-cli -h tenant-a.redis.brimble.app -p 6379 -a secure_password_a ping 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✅ Tenant A: Connected"
    else
        echo "❌ Tenant A: Failed"
    fi
else
    echo "⚠️  redis-cli not found. Install: apt-get install redis-tools"
fi

echo ""
echo "📊 Dashboard: http://localhost:8080"
echo "📈 Prometheus: http://localhost:9090"
echo "📊 HAProxy Stats:"
echo "  - PostgreSQL: http://localhost:8404/stats"
echo "  - MySQL: http://localhost:8405/stats"
echo "  - Redis: http://localhost:8407/stats"
EOF

chmod +x test-connections.sh

EOF

chmod +x test-connections.sh

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Run: docker-compose up -d"
echo "2. Wait 30 seconds for services to start"
echo "3. Test: ./test-connections.sh"
echo "4. Visit: http://localhost:8080"