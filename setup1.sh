
#!/bin/bash
set -euo pipefail

LOGFILE="setup-log.txt"
ELASTIC_PASSWORD="MySecurePassword123"   # Consider reading from env/secret
EMAIL="suhas4341@gmail.com"
DOMAIN="subhajjisuhas.me"

log() { echo -e "\n\033[1;34m[INFO]\033[0m $1\n" | tee -a "$LOGFILE"; }

export DEBIAN_FRONTEND=noninteractive

log "Updating system (non-interactive)..."
sudo apt-get update -y

log "Installing base dependencies..."
sudo apt-get install -y ufw curl gnupg apt-transport-https ca-certificates software-properties-common lsb-release

log "Installing Java 17 (required by Elasticsearch)..."
sudo apt-get install -y openjdk-17-jdk
java -version | tee -a "$LOGFILE"

log "Setting vm.max_map_count for Elasticsearch (persists via sysctl.d)..."
echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elasticsearch.conf >/dev/null
sudo sysctl --system

log "Creating a 2G swapfile (helps avoid OOM on 2GB RAM)..."
if ! sudo swapon --show | grep -q 'swapfile'; then
  sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
fi
sudo sysctl vm.swappiness=10

log "Adding Elastic GPG key and repo (keyring-based, no apt-key)..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /etc/apt/keyrings/elastic.gpg
sudo chmod a+r /etc/apt/keyrings/elastic.gpg
echo "deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/elastic-8.x.list >/dev/null
sudo apt-get update -y

log "Installing Elasticsearch..."
sudo apt-get install -y elasticsearch

log "Configuring Elasticsearch for single-node & low-memory..."
sudo bash -c 'cat >/etc/elasticsearch/elasticsearch.yml' <<'EOF'
cluster.name: single-node-cluster
node.name: node-1
discovery.type: single-node
network.host: 0.0.0.0
http.host: 0.0.0.0

# Security is enabled by default in 8.x, keep it but avoid heavy features
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true

# Disable ML to save memory
xpack.ml.enabled: false

# Reduce background overhead
xpack.monitoring.collection.enabled: false

# Limit fielddata/ingest footprints (optional tuning knobs)
indices.query.bool.max_clause_count: 1024
EOF

# Set JVM heap small (512m). Use systemd override so package updates don't clobber it.
log "Setting Elasticsearch JVM heap to 512m (via systemd override)..."
sudo mkdir -p /etc/systemd/system/elasticsearch.service.d
sudo bash -c 'cat >/etc/systemd/system/elasticsearch.service.d/override.conf' <<'EOF'
[Service]
Environment="ES_JAVA_OPTS=-Xms512m -Xmx512m -XX:+AlwaysPreTouch -XX:+UseG1GC"
LimitMEMLOCK=infinity
EOF

log "Installing Kibana..."
sudo apt-get install -y kibana

log "Configuring Kibana (lean, behind NGINX)..."
sudo bash -c "cat >>/etc/kibana/kibana.yml" <<EOF
server.publicBaseUrl: "https://$DOMAIN"
xpack.encryptedSavedObjects.encryptionKey: "uq4nDHKoCjqwv9Rpo4Jh3j9IAtPAEDwCphGHg2FYk8Y="
# Trim features to save memory
xpack.reporting.enabled: false
xpack.apm.enabled: false
EOF

# Limit Kibana Node.js heap (384–512MB). 384MB is tight; 512MB safer if available.
log "Limiting Kibana Node.js heap to 512MB (via systemd override)..."
sudo mkdir -p /etc/systemd/system/kibana.service.d
sudo bash -c 'cat >/etc/systemd/system/kibana.service.d/override.conf' <<'EOF'
[Service]
Environment="NODE_OPTIONS=--max-old-space-size=512"
EOF

log "Installing and configuring NGINX..."
sudo apt-get install -y nginx
sudo ufw allow OpenSSH
sudo ufw allow "Nginx Full"
sudo ufw --force enable

sudo bash -c "cat >/etc/nginx/sites-available/default" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:5601;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_buffers 16 16k;
        proxy_busy_buffers_size 64k;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

log "Enabling services at boot..."
sudo systemctl daemon-reload
sudo systemctl enable elasticsearch
sudo systemctl enable kibana

log "Starting Elasticsearch (first start may take 30–90s)..."
sudo systemctl start elasticsearch

log "Waiting for Elasticsearch to respond..."
# Simple wait loop
for i in {1..60}; do
  if curl -s --cacert /etc/elasticsearch/certs/http_ca.crt https://localhost:9200 >/dev/null 2>&1; then
    echo "Elasticsearch is up."
    break
  fi
  sleep 2
done

log "Installing Certbot and issuing Let's Encrypt cert..."
sudo apt-get install -y certbot python3-certbot-nginx
sleep 3
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect

log "Enable auto-renewal with nginx reload..."
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" | sudo tee /etc/cron.d/certbot-auto >/dev/null

log "Starting Kibana..."
sudo systemctl start kibana

log "Set recommended index defaults for single-node (1 shard, 0 replicas)..."
curl -s -k --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:$ELASTIC_PASSWORD" \
  -H "Content-Type: application/json" \
  -X PUT "https://localhost:9200/_cluster/settings" \
  -d '{
    "persistent": {
      "cluster.routing.allocation.disk.watermark.low": "85%",
      "cluster.routing.allocation.disk.watermark.high": "90%",
      "cluster.routing.allocation.disk.watermark.flood_stage": "95%",
      "indices.lifecycle.history_index_enabled": false
    }
  }' || true

curl -s -k --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u "elastic:$ELASTIC_PASSWORD" \
  -H "Content-Type: application/json" \
  -X PUT "https://localhost:9200/_template/_default" \
  -d '{
    "index_patterns": ["*"],
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "refresh_interval": "30s"
      }
    }
  }' || true

log "Setup complete. Access Kibana at https://$DOMAIN"

log "Enrollment Token (for Kibana pairing with ES)"
sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana || true

echo ""
echo "-------------------------------------------"
echo "ℹ️  You may need the Kibana verification code next:"
echo "sudo /usr/share/kibana/bin/kibana-verification-code"
echo "-------------------------------------------"

