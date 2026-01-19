#!/bin/bash

LOGFILE="setup-log.txt"
ELASTIC_PASSWORD="MySecurePassword123"
EMAIL="suhas4341@gmail.com"
DOMAIN="subhajjisuhas.me"

log() {
  echo -e "\n\033[1;34m[INFO]\033[0m $1\n" | tee -a "$LOGFILE"
}

set -e

log "Updating system without interactive prompts..."
export DEBIAN_FRONTEND=noninteractive
sudo apt update


log "Installing dependencies..."
sudo apt install -y ufw curl gnupg apt-transport-https software-properties-common software-properties-common

log "Installing Java 17..."
sudo apt install -y openjdk-17-jdk
java -version | tee -a "$LOGFILE"

log "Adding Elastic GPG key and repo..."
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
echo "deb https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list
sudo apt update

log "Installing Elasticsearch..."
sudo apt install -y elasticsearch
sudo systemctl enable elasticsearch
sudo systemctl start elasticsearch

log "Installing Kibana..."
sudo apt install -y kibana
sudo systemctl enable kibana
sudo systemctl start kibana

log "Configuring Kibana..."
cat <<EOF | sudo tee -a /etc/kibana/kibana.yml > /dev/null
xpack.encryptedSavedObjects.encryptionKey: "uq4nDHKoCjqwv9Rpo4Jh3j9IAtPAEDwCphGHg2FYk8Y="
server.publicBaseUrl: "https://$DOMAIN"
EOF

log "Installing and configuring NGINX..."
sudo apt install -y nginx
sudo ufw allow OpenSSH
sudo ufw allow "Nginx Full"
sudo ufw --force enable

cat <<EOF | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5601;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

log "Installing Certbot and setting up HTTPS..."
sudo apt install -y certbot python3-certbot-nginx
sleep 5
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect

log "Enabling auto-renewal cron job..."
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" | sudo tee /etc/cron.d/certbot-auto > /dev/null

log "Adding 'mah' user as superuser (if not already exists)..."
if ! sudo grep -q "^mah:" /etc/elasticsearch/users; then
  sudo /usr/share/elasticsearch/bin/elasticsearch-users useradd mah -p ELK@123 -r superuser
  log "'mah' user created with superuser role."
else
  log "'mah' user already exists â skipping creation."
fi


log "Restarting services..."
sudo systemctl restart elasticsearch
sudo systemctl restart kibana
sudo systemctl reload nginx

log "Setup complete. Access Kibana at https://$DOMAIN"

log "Enrollment Token Below"
sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana

echo ""
echo "-------------------------------------------"
echo "â ï¸  Now run the following command manually:"
echo "sudo /usr/share/kibana/bin/kibana-verification-code"
echo "-------------------------------------------"
