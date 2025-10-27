# Install
sudo bash install-reflector.sh

# Edit configuration
sudo nano /etc/wsprdaemon/reflector_destinations.json

# Setup SSH keys for passwordless rsync
sudo -u wsprdaemon ssh-keygen -t rsa -N '' -f /home/wsprdaemon/.ssh/id_rsa
sudo -u wsprdaemon ssh-copy-id wsprdaemon@WD1
sudo -u wsprdaemon ssh-copy-id wsprdaemon@WD2

# Test manually
sudo -u wsprdaemon /usr/local/bin/wsprdaemon_reflector.sh /etc/wsprdaemon/reflector.conf

# Enable and start service
sudo systemctl enable wsprdaemon_reflector@reflector
sudo systemctl start wsprdaemon_reflector@reflector

# Check status
sudo systemctl status wsprdaemon_reflector@reflector

# View logs
sudo journalctl -u wsprdaemon_reflector@reflector -f
tail -f /var/log/wsprdaemon/wsprdaemon_reflector.log
