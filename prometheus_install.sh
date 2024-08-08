version="<%=customOptions.prom_version%>"
release=$(echo "$version" | sed 's/^v//')
prometheus_pass="<%=customOptions.prom_password%>"
rabbit_nodes="<%=customOptions.rabbit_nodes%>"

#Install brcypt utilities (required for Prometheus password)
if command -v apt &> /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get install -y apache2-utils > /dev/null
    echo "apache2-utils installed"

elif command -v yum &> /dev/null; then
    sudo yum install -y httpd-tools > /dev/null
    echo "httpd-tools installed"


else
    echo "Unsupported package manager. Please install ."
    exit 1
fi

#Convert the prometheus_pass to bcrypt
prometheus_password_bcrypt=$(htpasswd -nbBC 12 test $prometheus_pass | cut -d: -f2)


groupadd --system prometheus > /dev/null
echo "Added group prometheus"

useradd -s /sbin/nologin --system -g prometheus prometheus > /dev/null
echo "Added user prometheus"

mkdir /var/lib/prometheus > /dev/null
echo "Created directory /var/lib/prometheus"

for i in rules rules.d files_sd; do
    sudo mkdir -p /etc/prometheus/${i}; > /dev/null
done



prometheus_url="https://github.com/prometheus/prometheus/releases/download/$version/prometheus-$release.linux-amd64.tar.gz"

if wget -q --spider "$prometheus_url"; then
    wget -q "$prometheus_url"
    tar -xzvf prometheus-$release.linux-amd64.tar.gz > /dev/null
    cd prometheus-$release.linux-amd64
    cp prometheus promtool /usr/local/bin/
    echo "added promtool to /usr/local/bin/"
    cp -r prometheus.yml consoles/ console_libraries/ /etc/prometheus/
    echo "Moved files/directories to /etc/prometheus"
else
    echo "Error: URL is not reachable: $prometheus_url"
    echo "You will need to ensure $prometheus_url is reachable from this node"
    exit 1
fi

#wget https://github.com/prometheus/prometheus/releases/download/$version/prometheus-$release.linux-amd64.tar.gz
#tar -xzvf prometheus-$release.linux-amd64.tar.gz



# Create Prometheus Service
cat <<EOF | sudo tee /etc/systemd/system/prometheus.service > /dev/null
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --storage.tsdb.retention.time=30d \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.console.libraries=/etc/prometheus/console_libraries \\
  --web.listen-address=0.0.0.0:9090 \\
  --web.external-url= \\
  --web.enable-remote-write-receiver \\
  --web.config.file=/etc/prometheus/web.yml

SyslogIdentifier=prometheus
Restart=always

[Install]
WantedBy=multi-user.target
EOF

chown -R prometheus:prometheus /etc/prometheus > /dev/null
chmod -R 775 /etc/prometheus/ > /dev/null
chown -R prometheus:prometheus /var/lib/prometheus/ > /dev/null

echo "Prometheus Service Created"

# Create Cert directory
sudo mkdir -p /etc/prometheus/certs > /dev/null

# Generate private key
sudo openssl genrsa -out /etc/prometheus/certs/prometheus.key 2048 > /dev/null 2>&1

# Generate Cert
sudo openssl req -new -key /etc/prometheus/certs/prometheus.key -out /etc/prometheus/certs/prometheus.csr -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$fqdn" > /dev/null 2>&1

# Self Sign the Cert with the private key
sudo openssl x509 -req -days 1825 -in /etc/prometheus/certs/prometheus.csr -signkey /etc/prometheus/certs/prometheus.key -out /etc/prometheus/certs/prometheus.crt > /dev/null 2>&1

# Set permissions on the files
sudo chown prometheus:prometheus /etc/prometheus/certs/prometheus.crt > /dev/null
sudo chown prometheus:prometheus /etc/prometheus/certs/prometheus.key > /dev/null
sudo chmod 400 /etc/prometheus/certs/prometheus.key /etc/prometheus/certs/prometheus.crt > /dev/null

cat <<EOF | sudo tee /etc/prometheus/web.yml > /dev/null
basic_auth_users:
  admin: $prometheus_password_bcrypt
tls_server_config:
  cert_file: /etc/prometheus/certs/prometheus.crt
  key_file: /etc/prometheus/certs/prometheus.key
EOF

cat <<EOF | sudo tee -a /etc/prometheus/prometheus.yml > /dev/null
    scheme: https
    tls_config:
      insecure_skip_verify: true
    basic_auth:
     username: admin
     password: $prometheus_pass
EOF

echo "TLS and basic authentication setup for Prometheus completed"

# Add config to scrape rabbit nodes
IFS=',' read -r -a nodes <<< "$rabbit_nodes"

index=1
for node in "${nodes[@]}"; do
    cat <<EOF | sudo tee -a /etc/prometheus/prometheus.yml > /dev/null

  - job_name: rabbit_node${index}
    static_configs:
      - targets: ['${node}:15692']
EOF
    index=$((index + 1))
done

echo "Rabbit Nodes Scrape added to Prometheus Config"

systemctl daemon-reload > /dev/null 2>&1
systemctl start prometheus > /dev/null 2>&1
systemctl enable prometheus > /dev/null 2>&1

echo "Prometheus install and setup complete"