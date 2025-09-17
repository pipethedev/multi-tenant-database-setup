#!/bin/bash

set -e

echo "🚀 Setting up Brimble Multi-Database Proxy POC..."

mkdir -p ssl config prometheus grafana dashboard

DB_TYPES=("postgres" "mysql" "mongo" "redis" "rabbitmq" "neo4j")
TENANTS=("a" "b" "c" "d" "e")

# =============================================================================
# SSL CERTIFICATE GENERATION
# =============================================================================

echo "🔐 Generating SSL certificates for multi-database SNI routing..."

openssl genrsa -out ssl/ca-key.pem 4096
openssl req -new -x509 -days 365 -key ssl/ca-key.pem -sha256 -out ssl/ca.pem -subj "/C=US/ST=CA/L=SF/O=Brimble/CN=Brimble CA"

# Function to generate certificates for each database type and tenant
generate_db_tenant_cert() {
    local db_type=$1
    local tenant=$2
    local domain="tenant-${tenant}.${db_type}.brimble.app"
    
    echo "  📜 Generating certificate for ${domain}..."
    
    openssl genrsa -out ssl/${db_type}-${tenant}-key.pem 4096
    
    openssl req -subj "/CN=${domain}" -sha256 -new -key ssl/${db_type}-${tenant}-key.pem -out ssl/${db_type}-${tenant}.csr
    
    cat > ssl/${db_type}-${tenant}-ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${db_type}.brimble.app
EOF
    
    # Generate certificate
    openssl x509 -req -days 365 -sha256 -in ssl/${db_type}-${tenant}.csr -CA ssl/ca.pem -CAkey ssl/ca-key.pem -out ssl/${db_type}-${tenant}-cert.pem -extfile ssl/${db_type}-${tenant}-ext.cnf -CAcreateserial
    
    # Create combined certificate file for HAProxy
    cat ssl/${db_type}-${tenant}-cert.pem ssl/${db_type}-${tenant}-key.pem > ssl/${db_type}-${tenant}.pem
    
    # Cleanup
    rm ssl/${db_type}-${tenant}.csr ssl/${db_type}-${tenant}-ext.cnf
}

# Generate wildcard certificate for each database type
generate_wildcard_cert() {
    local db_type=$1
    local domain="*.${db_type}.brimble.app"
    
    echo "  🌟 Generating wildcard certificate for ${domain}..."
    
    openssl genrsa -out ssl/${db_type}-wildcard-key.pem 4096
    openssl req -subj "/CN=${domain}" -sha256 -new -key ssl/${db_type}-wildcard-key.pem -out ssl/${db_type}-wildcard.csr
    
    cat > ssl/${db_type}-wildcard-ext.cnf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${domain}
DNS.2 = ${db_type}.brimble.app
EOF
    
    openssl x509 -req -days 365 -sha256 -in ssl/${db_type}-wildcard.csr -CA ssl/ca.pem -CAkey ssl/ca-key.pem -out ssl/${db_type}-wildcard-cert.pem -extfile ssl/${db_type}-wildcard-ext.cnf -CAcreateserial
    cat ssl/${db_type}-wildcard-cert.pem ssl/${db_type}-wildcard-key.pem > ssl/${db_type}.pem
    
    rm ssl/${db_type}-wildcard.csr ssl/${db_type}-wildcard-ext.cnf
}

# Generate wildcard certificates for each database type
for db_type in "${DB_TYPES[@]}"; do
    generate_wildcard_cert "$db_type"
done

chmod 600 ssl/*.pem
chmod 644 ssl/ca.pem

# =============================================================================
# HAPROXY CONFIGURATIONS
# =============================================================================

echo "⚙️  Generating HAProxy configurations..."

cat > config/haproxy-postgres.cfg <<'EOF'
global
    daemon
    log stdout local0 info
    stats socket /var/run/haproxy.sock mode 660 level admin
    tune.ssl.default-dh-param 2048

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000ms
    timeout client 300000ms
    timeout server 300000ms
    retries 3

backend tenant_a_postgres
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check send-binary 00000008000003
    tcp-check expect binary 4e
    server postgres-a postgres-tenant-a:5432 check

backend tenant_b_postgres
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check send-binary 00000008000003
    tcp-check expect binary 4e
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
    stats show-desc "PostgreSQL Proxy Stats"
EOF

cat > config/haproxy-mysql.cfg <<'EOF'
global
    daemon
    log stdout local0 info
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000ms
    timeout client 300000ms
    timeout server 300000ms
    retries 3

backend tenant_a_mysql
    mode tcp
    balance roundrobin
    option mysql-check user haproxy_check
    server mysql-a mysql-tenant-a:3306 check

backend tenant_b_mysql
    mode tcp
    balance roundrobin
    option mysql-check user haproxy_check
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
    stats show-desc "MySQL Proxy Stats"
EOF

cat > config/haproxy-mongodb.cfg <<'EOF'
global
    daemon
    log stdout local0 info
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000ms
    timeout client 300000ms
    timeout server 300000ms
    retries 3

backend tenant_c_mongodb
    mode tcp
    balance roundrobin
    option tcp-check
    server mongodb-c mongodb-tenant-c:27017 check

backend tenant_d_mongodb
    mode tcp
    balance roundrobin
    option tcp-check
    server mongodb-d mongodb-tenant-d:27017 check

frontend mongodb_frontend
    bind *:27017 ssl crt /etc/ssl/certs/mongo.pem
    mode tcp
    use_backend tenant_c_mongodb if { ssl_fc_sni -i tenant-c.mongo.brimble.app }
    use_backend tenant_d_mongodb if { ssl_fc_sni -i tenant-d.mongo.brimble.app }
    default_backend tenant_c_mongodb

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats show-desc "MongoDB Proxy Stats"
EOF

cat > config/haproxy-redis.cfg <<'EOF'
global
    daemon
    log stdout local0 info
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000ms
    timeout client 300000ms
    timeout server 300000ms
    retries 3

backend tenant_a_redis
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    server redis-a redis-tenant-a:6379 check

backend tenant_e_redis
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check send PING\r\n
    tcp-check expect string +PONG
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
    stats show-desc "Redis Proxy Stats"
EOF

cat > config/haproxy-rabbitmq.cfg <<'EOF'
global
    daemon
    log stdout local0 info
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000ms
    timeout client 300000ms
    timeout server 300000ms
    retries 3

backend tenant_b_rabbitmq_amqp
    mode tcp
    balance roundrobin
    option tcp-check
    server rabbitmq-b rabbitmq-tenant-b:5672 check

backend tenant_c_rabbitmq_amqp
    mode tcp
    balance roundrobin
    option tcp-check
    server rabbitmq-c rabbitmq-tenant-c:5672 check

backend tenant_b_rabbitmq_mgmt
    mode tcp
    balance roundrobin
    option tcp-check
    server rabbitmq-b rabbitmq-tenant-b:15672 check

backend tenant_c_rabbitmq_mgmt
    mode tcp
    balance roundrobin
    option tcp-check
    server rabbitmq-c rabbitmq-tenant-c:15672 check

frontend rabbitmq_amqp_frontend
    bind *:5672 ssl crt /etc/ssl/certs/rabbitmq.pem
    mode tcp
    use_backend tenant_b_rabbitmq_amqp if { ssl_fc_sni -i tenant-b.rabbitmq.brimble.app }
    use_backend tenant_c_rabbitmq_amqp if { ssl_fc_sni -i tenant-c.rabbitmq.brimble.app }
    default_backend tenant_b_rabbitmq_amqp

frontend rabbitmq_mgmt_frontend
    bind *:15672 ssl crt /etc/ssl/certs/rabbitmq.pem
    mode tcp
    use_backend tenant_b_rabbitmq_mgmt if { ssl_fc_sni -i tenant-b.rabbitmq.brimble.app }
    use_backend tenant_c_rabbitmq_mgmt if { ssl_fc_sni -i tenant-c.rabbitmq.brimble.app }
    default_backend tenant_b_rabbitmq_mgmt

frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats show-desc "RabbitMQ Proxy Stats"
EOF

cat > config/haproxy-neo4j.cfg <<'EOF'
global
    daemon
    log stdout local0 info
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000ms
    timeout client 300000ms
    timeout server 300000ms
    retries 3

backend tenant_d_neo4j_bolt
    mode tcp
    balance roundrobin
    option tcp-check
    server neo4j-d neo4j-tenant-d:7687 check

backend tenant_e_neo4j_bolt
    mode tcp
    balance roundrobin
    option tcp-check
    server neo4j-e neo4j-tenant-e:7687 check

backend tenant_d_neo4j_http
    mode tcp
    balance roundrobin
    option tcp-check
    server neo4j-d neo4j-tenant-d:7474 check

backend tenant_e_neo4j_http
    mode tcp
    balance roundrobin
    option tcp-check
    server neo4j-e neo4j-tenant-e:7474 check

frontend neo4j_bolt_frontend
    bind *:7687 ssl crt /etc/ssl/certs/neo4j.pem
    mode tcp
    use_backend tenant_d_neo4j_bolt if { ssl_fc_sni -i tenant-d.neo4j.brimble.app }
    use_backend tenant_e_neo4j_bolt if { ssl_fc_sni -i tenant-e.neo4j.brimble.app }
    default_backend tenant_d_neo4j_bolt

frontend neo4j_http_frontend
    bind *:7474 ssl crt /etc/ssl/certs/neo4j.pem
    mode tcp
    use_backend tenant_d_neo4j_http if