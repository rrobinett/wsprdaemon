# Create a virtual environment in your project directory
cd ~/wsprdaemon
python3 -m venv venv

# Activate the virtual environment
source venv/bin/activate

# Now install the packages
pip3 install requests clickhouse-connect numpy
