# -*- coding: utf-8 -*-
#
# Copyright 2014 Red Hat, Inc.
# All Rights Reserved.
# Copyright (c) 2017-2021 Dell Inc. or its subsidiaries.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

"""
DRAC management interface
"""

from oslo_log import log as logging

from ironic.common import boot_devices
from ironic.common import exception
from ironic.common.i18n import _
from ironic.common import metrics_utils
from ironic.common import states
from ironic.drivers import base
from ironic.drivers.modules.drac import utils as drac_utils
from ironic.drivers.modules.redfish import management as redfish_management
from ironic.drivers.modules.redfish import utils as redfish_utils


LOG = logging.getLogger(__name__)

METRICS = metrics_utils.get_metrics_logger(__name__)

# This dictionary is used to map boot device names between two (2) name
# spaces. The name spaces are:
#
#     1) ironic boot devices
#     2) iDRAC boot sources
#
# Mapping can be performed in both directions.
#
# The keys are ironic boot device types. Each value is a list of strings
# that appear in the identifiers of iDRAC boot sources.
#
# The iDRAC represents boot sources with class DCIM_BootSourceSetting
# [1]. Each instance of that class contains a unique identifier, which
# is called an instance identifier, InstanceID,
#
# An InstanceID contains the Fully Qualified Device Descriptor (FQDD) of
# the physical device that hosts the boot source [2].
#
# [1] "Dell EMC BIOS and Boot Management Profile", Version 4.0.0, July
#     10, 2017, Section 7.2 "Boot Management", pp. 44-47 --
#     http://en.community.dell.com/techcenter/extras/m/white_papers/20444495/download
# [2] "Lifecycle Controller Version 3.15.15.15 User's Guide", Dell EMC,
#     2017, Table 13, "Easy-to-use Names of System Components", pp. 71-74 --
#     http://topics-cdn.dell.com/pdf/idrac9-lifecycle-controller-v3.15.15.15_users-guide2_en-us.pdf
_BOOT_DEVICES_MAP = {
    boot_devices.DISK: ['AHCI', 'Disk', 'RAID'],
    boot_devices.PXE: ['NIC'],
    boot_devices.CDROM: ['Optical'],
}

_DRAC_BOOT_MODES = ['Bios', 'Uefi']

# BootMode constant
_NON_PERSISTENT_BOOT_MODE = 'OneTime'

# Clear job id's constant
_CLEAR_JOB_IDS = 'JID_CLEARALL'

# Clean steps constant
_CLEAR_JOBS_CLEAN_STEPS = ['clear_job_queue', 'known_good_state']

# iDRAC supports up to three NTP servers and two static IPv4 DNS servers.
_MAX_NTP_SERVERS = 3
_MAX_DNS_SERVERS = 2

_SET_NTP_ARGSINFO = {
    'ntp_servers': {
        'description': (
            'A list of up to three NTP server addresses to configure on the '
            'iDRAC. The first three entries are used, extras are ignored.'),
        'required': True,
    },
    'enable_ntp': {
        'description': (
            'Whether to enable NTP time synchronisation. Defaults to True.'),
        'required': False,
    },
    'timezone': {
        'description': (
            'Optional iDRAC timezone string, e.g. "US/Central".'),
        'required': False,
    },
    'extra_attributes': {
        'description': (
            'Optional dict of raw Dell OEM attribute name/value pairs '
            'merged into the PATCH, for iDRAC firmware whose attribute '
            'names differ.'),
        'required': False,
    },
}

_SET_DNS_ARGSINFO = {
    'dns_servers': {
        'description': (
            'A list of up to two static IPv4 DNS server addresses to '
            'configure on the iDRAC. The first two entries are used.'),
        'required': True,
    },
    'dns_domain_name': {
        'description': (
            'Optional DNS domain name to set on the iDRAC.'),
        'required': False,
    },
    'extra_attributes': {
        'description': (
            'Optional dict of raw Dell OEM attribute name/value pairs '
            'merged into the PATCH, for iDRAC firmware whose attribute '
            'names differ.'),
        'required': False,
    },
}

_SET_OIDC_ARGSINFO = {
    'discovery_url': {
        'description': (
            'The OpenID Connect provider discovery URL '
            '(.well-known/openid-configuration).'),
        'required': False,
    },
    'client_id': {
        'description': 'The OpenID Connect client (application) ID.',
        'required': False,
    },
    'client_secret': {
        'description': (
            'The OpenID Connect client secret. Not logged.'),
        'required': False,
    },
    'name': {
        'description': (
            'A display name for the OpenID Connect provider entry.'),
        'required': False,
    },
    'enable_oidc': {
        'description': (
            'Whether to enable this OpenID Connect provider. Defaults to '
            'True.'),
        'required': False,
    },
    'provider_index': {
        'description': (
            'Which iDRAC OpenIDConnectServer slot to program (1-based). '
            'Defaults to 1.'),
        'required': False,
    },
    'extra_attributes': {
        'description': (
            'Optional dict of raw Dell OEM attribute name/value pairs '
            'merged into the PATCH, for iDRAC firmware whose attribute '
            'names differ.'),
        'required': False,
    },
}


def _bool_to_idrac(value):
    """Map a Python boolean to the iDRAC 'Enabled'/'Disabled' string."""
    return 'Enabled' if value else 'Disabled'


def _is_boot_order_flexibly_programmable(persistent, bios_settings):
    return persistent and 'SetBootOrderFqdd1' in bios_settings


def _flexibly_program_boot_order(device, drac_boot_mode):
    if device == boot_devices.DISK:
        if drac_boot_mode == 'Bios':
            bios_settings = {'SetBootOrderFqdd1': 'HardDisk.List.1-1'}
        else:
            # 'Uefi'
            bios_settings = {
                'SetBootOrderFqdd1': '*.*.*',  # Disks, which are all else
                'SetBootOrderFqdd2': 'NIC.*.*',
                'SetBootOrderFqdd3': 'Optical.*.*',
                'SetBootOrderFqdd4': 'Floppy.*.*',
            }
    elif device == boot_devices.PXE:
        bios_settings = {'SetBootOrderFqdd1': 'NIC.*.*'}
    else:
        # boot_devices.CDROM
        bios_settings = {'SetBootOrderFqdd1': 'Optical.*.*'}

    return bios_settings


class DracRedfishManagement(redfish_management.RedfishManagement):
    """iDRAC Redfish interface for management-related actions."""

    @METRICS.timer('DracRedfishManagement.clear_job_queue')
    @base.verify_step(priority=0)
    @base.clean_step(priority=0, requires_ramdisk=False)
    def clear_job_queue(self, task):
        """Clear iDRAC job queue.

        :param task: a TaskManager instance containing the node to act
                     on.
        :raises: RedfishError on an error.
        """
        try:
            drac_utils.execute_oem_manager_method(
                task, 'clear job queue',
                lambda m: m.job_service.delete_jobs(job_ids=['JID_CLEARALL']))
        except exception.RedfishError as exc:
            if "Oem/Dell/DellJobService is missing" in str(exc):
                LOG.warning('iDRAC on node %(node)s does not support '
                            'clearing Lifecycle Controller job queue '
                            'using the idrac-redfish driver. '
                            'If using iDRAC9, consider upgrading firmware.',
                            {'node': task.node.uuid})
            if task.node.provision_state != states.VERIFYING:
                raise

    @METRICS.timer('DracRedfishManagement.reset_idrac')
    @base.verify_step(priority=0)
    @base.clean_step(priority=0, requires_ramdisk=False)
    def reset_idrac(self, task):
        """Reset the iDRAC.

        :param task: a TaskManager instance containing the node to act
                     on.
        :raises: RedfishError on an error.
        """
        try:
            drac_utils.execute_oem_manager_method(
                task, 'reset iDRAC', lambda m: m.reset_idrac())
            redfish_utils.wait_until_get_system_ready(task.node)
            LOG.info('Reset iDRAC for node %(node)s done',
                     {'node': task.node.uuid})
        except exception.RedfishError as exc:
            if "Oem/Dell/DelliDRACCardService is missing" in str(exc):
                LOG.warning('iDRAC on node %(node)s does not support '
                            'iDRAC reset using the idrac-redfish driver. '
                            'If using iDRAC9, consider upgrading firmware. ',
                            {'node': task.node.uuid})
            if task.node.provision_state != states.VERIFYING:
                raise

    @METRICS.timer('DracRedfishManagement.known_good_state')
    @base.verify_step(priority=0)
    @base.clean_step(priority=0, requires_ramdisk=False)
    def known_good_state(self, task):
        """Reset iDRAC to known good state.

        An iDRAC is reset to a known good state by resetting it and
        clearing its job queue.

        :param task: a TaskManager instance containing the node to act
                     on.
        :raises: RedfishError on an error.
        """
        self.reset_idrac(task)
        self.clear_job_queue(task)
        LOG.info('Reset iDRAC to known good state for node %(node)s',
                 {'node': task.node.uuid})

    @METRICS.timer('DracRedfishManagement.set_ntp_servers')
    @base.service_step(priority=0, abortable=False,
                       argsinfo=_SET_NTP_ARGSINFO, requires_ramdisk=False)
    def set_ntp_servers(self, task, ntp_servers, enable_ntp=True,
                        timezone=None, extra_attributes=None):
        """Program the iDRAC NTP server settings.

        This is an out-of-band service step, invokable from a runbook, that
        PATCHes the Dell OEM iDRAC attributes directly. No database changes
        are made and the settings apply immediately on the iDRAC.

        :param task: a TaskManager instance containing the node to act on.
        :param ntp_servers: a list of NTP server addresses (up to three are
            used by the iDRAC).
        :param enable_ntp: whether to enable NTP synchronisation. Default
            True.
        :param timezone: optional iDRAC timezone string.
        :param extra_attributes: optional dict of raw Dell OEM attributes
            merged into the PATCH.
        :raises: InvalidParameterValue if ntp_servers is not a list.
        :raises: RedfishError on an error talking to the BMC.
        """
        if not isinstance(ntp_servers, list):
            raise exception.InvalidParameterValue(
                _('ntp_servers must be a list of server addresses'))

        attributes = {'NTPConfigGroup.1.NTPEnable': _bool_to_idrac(enable_ntp)}
        for index in range(_MAX_NTP_SERVERS):
            value = ntp_servers[index] if index < len(ntp_servers) else ''
            attributes['NTPConfigGroup.1.NTP%d' % (index + 1)] = value

        if timezone:
            attributes['Time.1.Timezone'] = timezone

        if extra_attributes:
            attributes.update(extra_attributes)

        drac_utils.set_dell_attributes(task, attributes)
        LOG.info('Set NTP servers for node %(node)s', {'node': task.node.uuid})

    @METRICS.timer('DracRedfishManagement.set_dns_servers')
    @base.service_step(priority=0, abortable=False,
                       argsinfo=_SET_DNS_ARGSINFO, requires_ramdisk=False)
    def set_dns_servers(self, task, dns_servers, dns_domain_name=None,
                        extra_attributes=None):
        """Program the iDRAC DNS server settings.

        This is an out-of-band service step, invokable from a runbook, that
        PATCHes the Dell OEM iDRAC attributes directly. It configures the
        static IPv4 DNS servers and disables learning them from DHCP so the
        static values take effect.

        :param task: a TaskManager instance containing the node to act on.
        :param dns_servers: a list of DNS server addresses (up to two static
            IPv4 servers are used by the iDRAC).
        :param dns_domain_name: optional DNS domain name to set.
        :param extra_attributes: optional dict of raw Dell OEM attributes
            merged into the PATCH.
        :raises: InvalidParameterValue if dns_servers is not a list.
        :raises: RedfishError on an error talking to the BMC.
        """
        if not isinstance(dns_servers, list):
            raise exception.InvalidParameterValue(
                _('dns_servers must be a list of server addresses'))

        # Static DNS servers only take effect when the iDRAC is not told to
        # learn them from DHCP.
        attributes = {'IPv4.1.DNSFromDHCP': 'Disabled'}
        for index in range(_MAX_DNS_SERVERS):
            value = dns_servers[index] if index < len(dns_servers) else ''
            attributes['IPv4Static.1.DNS%d' % (index + 1)] = value

        if dns_domain_name is not None:
            attributes['NIC.1.DNSDomainName'] = dns_domain_name
            attributes['NIC.1.DNSDomainFromDHCP'] = 'Disabled'

        if extra_attributes:
            attributes.update(extra_attributes)

        drac_utils.set_dell_attributes(task, attributes)
        LOG.info('Set DNS servers for node %(node)s', {'node': task.node.uuid})

    @METRICS.timer('DracRedfishManagement.set_oidc_config')
    @base.service_step(priority=0, abortable=False,
                       argsinfo=_SET_OIDC_ARGSINFO, requires_ramdisk=False)
    def set_oidc_config(self, task, discovery_url=None, client_id=None,
                        client_secret=None, name=None, enable_oidc=True,
                        provider_index=1, extra_attributes=None):
        """Program the iDRAC OpenID Connect (SSO) settings.

        This is an out-of-band service step, invokable from a runbook, that
        PATCHes the Dell OEM iDRAC attributes directly to configure an
        OpenID Connect provider for single sign-on. The client secret is
        never logged.

        :param task: a TaskManager instance containing the node to act on.
        :param discovery_url: the provider discovery URL.
        :param client_id: the OpenID Connect client ID.
        :param client_secret: the OpenID Connect client secret.
        :param name: a display name for the provider entry.
        :param enable_oidc: whether to enable the provider. Default True.
        :param provider_index: which OpenIDConnectServer slot to program
            (1-based). Default 1.
        :param extra_attributes: optional dict of raw Dell OEM attributes
            merged into the PATCH.
        :raises: RedfishError on an error talking to the BMC.
        """
        prefix = 'OpenIDConnectServer.%d.' % provider_index
        attributes = {prefix + 'Enabled': _bool_to_idrac(enable_oidc)}
        if name is not None:
            attributes[prefix + 'Name'] = name
        if discovery_url is not None:
            attributes[prefix + 'DiscoveryURL'] = discovery_url
        if client_id is not None:
            attributes[prefix + 'ClientID'] = client_id
        if client_secret is not None:
            attributes[prefix + 'ClientSecret'] = client_secret

        if extra_attributes:
            attributes.update(extra_attributes)

        drac_utils.set_dell_attributes(task, attributes)
        LOG.info('Set OIDC configuration for node %(node)s',
                 {'node': task.node.uuid})
