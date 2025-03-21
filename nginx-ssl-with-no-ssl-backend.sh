#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# Developer credit
echo -e "\nDeveloper: Abdul Satter"
echo -e "GitHub: github.com/AbdulSatterism\n"
# ─────────────────────────────────────────────────────────────────────────────

# 1. Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

# 2. Check if running in an interactive shell
if [[ ! -t 0 ]]; then
    echo "This script must be run in an interactive shell."
    exit 1
fi

# 3. Prompt for domain
read -p "Enter your domain (e.g., example.com): " DOMAIN

if [[ -z "$DOMAIN" ]]; then
  echo "Invalid input. Please provide a valid domain."
  exit 1
fi

# 4. Ensure Nginx is installed
if ! command -v nginx &> /dev/null; then
  echo "Nginx not found, installing..."
  apt update && apt install -y nginx
fi

# 5. Ask if backend is available
read -p "Is your backend available? (y/n): " BACKEND_AVAILABLE

# 6. If backend is available, ask for the backend port
if [[ "$BACKEND_AVAILABLE" =~ ^[Yy]$ ]]; then
  read -p "Enter the port number your backend listens on (e.g., 3002): " BACKEND_PORT

  if [[ -z "$BACKEND_PORT" ]] || ! [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]]; then
    echo "Invalid input. Please provide a valid backend port."
    exit 1
  fi
else
  echo "Backend not available. Exiting script."
  exit 1
fi

# 7. Ask for SSL setup
read -p "Do you want to set up SSL with Let's Encrypt? (y/n): " SSL_CHOICE

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP: Remove default and old configs for this domain
# ─────────────────────────────────────────────────────────────────────────────
if [ -f "/etc/nginx/sites-enabled/default" ]; then
  echo "Removing default Nginx configuration..."
  rm -f /etc/nginx/sites-enabled/default
fi

if [ -f "/etc/nginx/sites-enabled/$DOMAIN" ]; then
  echo "Removing old Nginx config for $DOMAIN from sites-enabled..."
  rm -f "/etc/nginx/sites-enabled/$DOMAIN"
fi

if [ -f "/etc/nginx/sites-available/$DOMAIN" ]; then
  echo "Removing old Nginx config for $DOMAIN from sites-available..."
  rm -f "/etc/nginx/sites-available/$DOMAIN"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Ensure directory exists for ACME challenges
# ─────────────────────────────────────────────────────────────────────────────
ACME_DIR="/var/www/certbot"
mkdir -p "$ACME_DIR"
chown -R www-data:www-data "$ACME_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Create temporary HTTP-only Nginx config with ACME challenge exception
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN"

cat > "$CONFIG_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    # Serve ACME challenge files from a static directory
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR;
        default_type "text/plain";
        try_files \$uri =404;
    }

    # Proxy all other traffic to the backend
    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf "$CONFIG_PATH" "/etc/nginx/sites-enabled/$DOMAIN"

# 8. Test and reload Nginx with the new HTTP config
echo "Testing and reloading Nginx with HTTP-only config..."
nginx -t && systemctl reload nginx

# 9. Configure firewall (if using UFW)
if command -v ufw &> /dev/null; then
  echo "Configuring firewall with ufw..."
  ufw allow 80/tcp 2>/dev/null || true
  ufw allow $BACKEND_PORT/tcp 2>/dev/null || true
  if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then
    ufw allow 443/tcp 2>/dev/null || true
  fi
  ufw reload 2>/dev/null || true
fi

# 10. If SSL is desired, obtain certificate and update config
if [[ "$SSL_CHOICE" =~ ^[Yy]$ ]]; then

  # Install Certbot if necessary
  if ! command -v certbot &> /dev/null; then
    echo "Installing Certbot..."
    apt update && apt install -y certbot python3-certbot-nginx
  fi

  echo "Requesting SSL certificate for $DOMAIN (and www.$DOMAIN)..."
  certbot certonly --nginx \
    -d "$DOMAIN" -d "www.$DOMAIN" \
    --non-interactive --agree-tos \
    -m "admin@$DOMAIN" --redirect

  # Verify certificate generation
  if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "SSL certificate generation failed for $DOMAIN. Please check domain DNS or logs."
    exit 1
  fi

  # Overwrite config with HTTPS configuration
  cat > "$CONFIG_PATH" <<EOF
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_DIR;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;

    # Proxy to backend
    location / {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  echo "Enabling SSL in Nginx..."
  nginx -t && systemctl reload nginx

  echo "Testing Certbot auto-renewal..."
  certbot renew --dry-run

  echo -e "\n✅ Setup complete! Your domain **https://$DOMAIN** is now secured with SSL."
  exit 0

else
  echo -e "\n✅ Setup complete (HTTP only). Your domain **http://$DOMAIN** points to port $BACKEND_PORT."
  exit 0
fi