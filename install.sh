#!/bin/bash

# Get username
usern=$(whoami)

# Generate secret key and admin token
SECRET_KEY=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 80)
UNISALT=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24)

# Check the installed Python version
PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')

# Extract major and minor version (e.g., 3.8 from Python 3.8.5)
PYTHON_MAJOR_MINOR=$(echo $PYTHON_VERSION | cut -d. -f1,2)

echo -ne "Enter your preferred domain/DNS address: "
read wanip

# Check wanip is valid domain
if ! [[ $wanip =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
    echo -e "Invalid domain/DNS address"
    exit 1
fi

# Identify OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
    UPSTREAM_ID=${ID_LIKE,,}

    # Fallback to ID_LIKE if ID was not 'ubuntu' or 'debian'
    if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
        UPSTREAM_ID="$(echo ${ID_LIKE,,} | sed s/\"//g | cut -d' ' -f1)"
    fi

elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSE-release ]; then
    OS=SuSE
    VER=$(cat /etc/SuSE-release)
elif [ -f /etc/redhat-release ]; then
    OS=RedHat
    VER=$(cat /etc/redhat-release)
else
    OS=$(uname -s)
    VER=$(uname -r)
fi

# Output debugging info if $DEBUG set
if [ "$DEBUG" = "true" ]; then
    echo "OS: $OS"
    echo "VER: $VER"
    echo "UPSTREAM_ID: $UPSTREAM_ID"
    exit 0
fi

# Setup prerequisites for server
PREREQ="curl wget unzip tar git qrencode python$PYTHON_MAJOR_MINOR-venv"
PREREQDEB="dnsutils ufw"
PREREQRPM="bind-utils"
PREREQARCH="bind"

echo "Installing prerequisites"
if [ "${ID}" = "debian" ] || [ "$OS" = "Ubuntu" ] || [ "$OS" = "Debian" ] || [ "${UPSTREAM_ID}" = "debian" ] || [ "${UPSTREAM_ID}" = "ubuntu" ]; then
    sudo apt update -qq
    sudo apt-get install -y ${PREREQ} ${PREREQDEB}
elif [ "$OS" = "CentOS" ] || [ "$OS" = "RedHat" ] || [ "${UPSTREAM_ID}" = "rhel" ] || [ "${OS}" = "Almalinux" ] || [ "${UPSTREAM_ID}" = "Rocky*" ]; then
    sudo yum update -y
    sudo yum install -y ${PREREQ} ${PREREQRPM}
elif [ "${ID}" = "arch" ] || [ "${UPSTREAM_ID}" = "arch" ]; then
    sudo pacman -Syu
    sudo pacman -S ${PREREQ} ${PREREQARCH}
else
    echo "Unsupported OS"
    exit 1
fi

# Make folder /var/log/rustdesk-server-api/
if [ ! -d "/var/log/rustdesk-server-api" ]; then
    echo "Creating /var/log/rustdesk-server-api"
    sudo mkdir -p /var/log/rustdesk-server-api/
fi

sudo chown -R ${usern}:${usern} /var/log/rustdesk-server-api/

# Clone the InfiniteRemote RustDesk API repository
cd /opt
sudo git clone https://github.com/infiniteremote/rustdesk-api-server.git
cd rustdesk-api-server

sudo chown -R ${usern}:${usern} /opt/rustdesk-api-server/

# Create secret config
secret_config="$(
  cat <<EOF
SECRET_KEY = "${SECRET_KEY}"
SALT_CRED = "${UNISALT}"
CSRF_TRUSTED_ORIGINS = ["https://${wanip}"]
EOF
)"
echo "${secret_config}" >/opt/rustdesk-api-server/rustdesk_server_api/secret_config.py

# Setup virtual environment and install dependencies
cd /opt/rustdesk-api-server/api
python3 -m venv env
source /opt/rustdesk-api-server/api/env/bin/activate
pip install --no-cache-dir --upgrade pip
pip install --no-cache-dir setuptools wheel
pip install --no-cache-dir -r /opt/rustdesk-api-server/requirements.txt
python manage.py makemigrations
python manage.py migrate
echo "Please set your password and username for the Web UI"
python manage.py securecreatesuperuser
deactivate

# Create Gunicorn config
apiconfig="$(
  cat <<EOF
bind = "127.0.0.1:8000"
workers = 4  # Number of worker processes (adjust as needed)
timeout = 120  # Maximum request processing time
user = "${usern}"  # User to run Gunicorn as
group = "${usern}"  # Group to run Gunicorn as

wsgi_app = "rustdesk_server_api.wsgi:application"

# Logging
errorlog = "/var/log/rustdesk-server-api/error.log"
accesslog = "/var/log/rustdesk-server-api/access.log"
loglevel = "info"
EOF
)"
echo "${apiconfig}" | sudo tee /opt/rustdesk-api-server/api/api_config.py >/dev/null

# Create systemd service for RustDesk API
apiservice="$(
  cat <<EOF
[Unit]
Description=rustdesk-api-server gunicorn daemon

[Service]
User=${usern}
WorkingDirectory=/opt/rustdesk-api-server/
Environment="PATH=/opt/rustdesk-api-server/api/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/rustdesk-api-server/api/env/bin/gunicorn -c /opt/rustdesk-api-server/api/api_config.py
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
)"
echo "${apiservice}" | sudo tee /etc/systemd/system/rustdesk-api.service >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable rustdesk-api
sudo systemctl start rustdesk-api

# Install and configure nginx
echo "Installing nginx"
if [ "${ID}" = "debian" ] || [ "$OS" = "Ubuntu" ] || [ "$OS" = "Debian" ] || [ "${UPSTREAM_ID}" = "ubuntu" ] || [ "${UPSTREAM_ID}" = "debian" ]; then
    sudo apt -y install nginx
    sudo apt -y install python3-certbot-nginx
elif [ "$OS" = "CentOS" ] || [ "$OS" = "RedHat" ] || [ "${UPSTREAM_ID}" = "rhel" ] || [ "${OS}" = "Almalinux" ] || [ "${UPSTREAM_ID}" = "Rocky*" ]; then
    sudo yum -y install nginx
    sudo yum -y install python3-certbot-nginx
elif [ "${ID}" = "arch" ] || [ "${UPSTREAM_ID}" = "arch" ]; then
    sudo pacman -S install nginx
    sudo pacman -S install python3-certbot-nginx
else
    echo "Unsupported OS"
    exit 1
fi

# Configure nginx for RustDesk API
rustdesknginx="$(
  cat <<EOF
server {
  server_name ${wanip};
      location / {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
}
}
EOF
)"
echo "${rustdesknginx}" | sudo tee /etc/nginx/sites-available/rustdesk.conf >/dev/null

# Check for nginx default files
if [ -f "/etc/nginx/sites-available/default" ]; then
    sudo rm /etc/nginx/sites-available/default
fi
if [ -f "/etc/nginx/sites-enabled/default" ]; then
    sudo rm /etc/nginx/sites-enabled/default
fi

sudo ln -s /etc/nginx/sites-available/rustdesk.conf /etc/nginx/sites-enabled/rustdesk.conf

sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Configure SSL
sudo certbot --nginx --redirect -d "${wanip}"

# Final restart of nginx
sudo systemctl restart nginx

echo -e "RustDesk API setup completed. You can now access it at https://${wanip}"
