#!/usr/bin/env python3
"""
POAP script for Cisco Nexus 9000v switches.

This script is downloaded by the switch during Power-On Auto Provisioning.
It fetches the switch-specific configuration from the TFTP server (controller)
based on the switch serial number, and applies it.

The DHCP server maps serial numbers to hostnames, and the config files are
named <hostname>.cfg on the TFTP server.
"""
import os
import sys
import signal
import syslog

# POAP environment variables set by NX-OS
POAP_SERIAL = os.environ.get('SERIAL_NUMBER', '')
POAP_HOSTNAME = os.environ.get('HOSTNAME', '')

# TFTP server is the DHCP server (controller)
TFTP_SERVER = os.environ.get('POAP_TFTP_SERVER', '')


def poap_log(msg):
    syslog.syslog(syslog.LOG_INFO, 'POAP: %s' % msg)
    print('POAP: %s' % msg)


def sigterm_handler(signum, frame):
    poap_log('SIGTERM received. Aborting POAP.')
    sys.exit(1)


def main():
    signal.signal(signal.SIGTERM, sigterm_handler)

    poap_log('Starting POAP script')
    poap_log('Serial: %s' % POAP_SERIAL)
    poap_log('TFTP server: %s' % TFTP_SERVER)

    if not TFTP_SERVER:
        poap_log('ERROR: No TFTP server address. Check DHCP config.')
        sys.exit(1)

    # Determine config filename from serial-to-hostname mapping
    # The TFTP server has a serial_to_hostname file for lookup
    mapping_file = '/tmp/poap_serial_map'
    config_file = '/tmp/poap_config'
    startup_config = '/bootflash/poap_startup.cfg'

    # Try to download the serial-to-hostname mapping
    hostname = None
    try:
        os.system('copy tftp://%s/serial_to_hostname /tmp/poap_serial_map vrf management'
                  % TFTP_SERVER)
        if os.path.exists(mapping_file):
            with open(mapping_file) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] == POAP_SERIAL:
                        hostname = parts[1]
                        break
    except Exception as e:
        poap_log('Could not fetch serial mapping: %s' % str(e))

    if not hostname:
        # Fall back: try using the serial number directly as hostname
        poap_log('No hostname mapping found for serial %s, using serial as filename'
                 % POAP_SERIAL)
        hostname = POAP_SERIAL

    poap_log('Hostname resolved to: %s' % hostname)

    # Download the configuration file
    cfg_filename = '%s.cfg' % hostname
    poap_log('Downloading config: tftp://%s/%s' % (TFTP_SERVER, cfg_filename))

    ret = os.system('copy tftp://%s/%s %s vrf management'
                    % (TFTP_SERVER, cfg_filename, config_file))
    if ret != 0:
        poap_log('ERROR: Failed to download config file %s' % cfg_filename)
        sys.exit(1)

    # Apply the configuration
    poap_log('Applying configuration from %s' % cfg_filename)
    ret = os.system('copy %s %s' % (config_file, startup_config))
    if ret != 0:
        poap_log('ERROR: Failed to copy config to startup')
        sys.exit(1)

    # Set the startup config
    os.system('copy %s startup-config' % startup_config)

    poap_log('POAP complete. Switch will reload with new configuration.')
    sys.exit(0)


if __name__ == '__main__':
    main()
