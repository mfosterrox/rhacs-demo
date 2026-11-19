#!/bin/bash
# First-boot setup for the RHACS demo RHEL guest.
# RHACS 5.0 roxagent serves vulnerability reports over VSOCK. Sensor pulls them.
sudo dnf clean all
sudo dnf update -y
# Install additional packages for security demo (commonly flagged in vulnerability scans)
sudo dnf install -y \
  httpd curl wget openssl openssl-libs zlib libxml2 \
  ghostscript perl nginx tar gzip nmap-ncat bzip2 zip unzip \
  freetype libjpeg-turbo libtiff libpng gnutls 2>/dev/null || true
curl -L -f -o /tmp/roxagent https://mirror.openshift.com/pub/rhacs/assets/5.0.0/bin/linux/roxagent
sudo install -m 0755 /tmp/roxagent /usr/local/bin/roxagent
sudo restorecon -v /usr/local/bin/roxagent || true
sudo tee /etc/systemd/system/roxagent.service >/dev/null <<'EOF'
[Unit]
Description=RHACS roxagent
After=network-online.target

[Service]
ExecStart=/usr/local/bin/roxagent serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo rm -f /etc/cron.d/roxagent
sudo systemctl daemon-reload
sudo systemctl enable --now roxagent.service
echo "Setup complete"
