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
Test class for DRAC management interface
"""

from unittest import mock

import ironic.common.boot_devices
from ironic.common import exception
from ironic.common import states
from ironic.conductor import task_manager
from ironic.drivers.modules.drac import management as drac_mgmt
from ironic.drivers.modules.drac import utils as drac_utils
from ironic.drivers.modules.redfish import utils as redfish_utils
from ironic.tests.unit.drivers.modules.drac import utils as test_utils
from ironic.tests.unit.objects import utils as obj_utils


INFO_DICT = test_utils.INFO_DICT


class DracRedfishManagementTestCase(test_utils.BaseDracTest):

    def setUp(self):
        super(DracRedfishManagementTestCase, self).setUp()
        self.node = obj_utils.create_test_node(self.context,
                                               driver='idrac',
                                               driver_info=INFO_DICT)
        self.management = drac_mgmt.DracRedfishManagement()

        self.config(enabled_hardware_types=['idrac'],
                    enabled_power_interfaces=['idrac-redfish'],
                    enabled_management_interfaces=['idrac-redfish'])

    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_clear_job_queue(self, mock_redfish_utils):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value

        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.clear_job_queue(task)
            mock_manager_oem.job_service.delete_jobs.assert_called_once_with(
                job_ids=['JID_CLEARALL'])

    @mock.patch.object(drac_mgmt, 'LOG', autospec=True)
    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_clear_job_queue_missing_attr_verify_step(self,
                                                      mock_redfish_utils,
                                                      mock_log):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value
        mock_manager_oem.job_service.delete_jobs.side_effect = (
            exception.RedfishError("Oem/Dell/DellJobService is missing"))
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.node.provision_state = states.VERIFYING
            task.driver.management.clear_job_queue(task)
            mock_log.warning.assert_called_once_with(
                'iDRAC on node %(node)s does not support '
                'clearing Lifecycle Controller job queue '
                'using the idrac-redfish driver. '
                'If using iDRAC9, consider upgrading firmware.',
                {'node': task.node.uuid})

    @mock.patch.object(drac_mgmt, 'LOG', autospec=True)
    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_clear_job_queue_missing_attr_clean_step(self,
                                                     mock_redfish_utils,
                                                     mock_log):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value
        mock_manager_oem.job_service.delete_jobs.side_effect = (
            exception.RedfishError("Oem/Dell/DellJobService is missing"))
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.node.provision_state = states.CLEANING
            self.assertRaises(ironic.common.exception.RedfishError,
                              task.driver.management.clear_job_queue, task)

    @mock.patch.object(redfish_utils, 'wait_until_get_system_ready',
                       autospec=True)
    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_reset_idrac(self, mock_redfish_utils, mock_wait_system_ready):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value

        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.reset_idrac(task)
            mock_manager_oem.reset_idrac.assert_called_once_with()

    @mock.patch.object(redfish_utils, 'wait_until_get_system_ready',
                       autospec=True)
    @mock.patch.object(drac_mgmt, 'LOG', autospec=True)
    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_reset_idrac_missing_attr_verify_step(self,
                                                  mock_redfish_utils,
                                                  mock_log,
                                                  mock_wait_system_ready):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value
        mock_manager_oem.reset_idrac.side_effect = (
            exception.RedfishError("Oem/Dell/DelliDRACCardService is missing"))
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.node.provision_state = states.VERIFYING
            task.driver.management.reset_idrac(task)
            mock_log.warning.assert_called_once_with(
                'iDRAC on node %(node)s does not support '
                'iDRAC reset using the idrac-redfish driver. '
                'If using iDRAC9, consider upgrading firmware. ',
                {'node': task.node.uuid})

    @mock.patch.object(redfish_utils, 'wait_until_get_system_ready',
                       autospec=True)
    @mock.patch.object(drac_mgmt, 'LOG', autospec=True)
    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_reset_idrac_missing_attr_clean_step(self,
                                                 mock_redfish_utils,
                                                 mock_log,
                                                 mock_wait_system_ready):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value
        mock_manager_oem.reset_idrac.side_effect = (
            exception.RedfishError("Oem/Dell/DelliDRACCardService is missing"))
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.node.provision_state = states.CLEANING
            self.assertRaises(ironic.common.exception.RedfishError,
                              task.driver.management.reset_idrac, task)

    @mock.patch.object(redfish_utils, 'wait_until_get_system_ready',
                       autospec=True)
    @mock.patch.object(drac_utils, 'redfish_utils', autospec=True)
    def test_known_good_state(self, mock_redfish_utils,
                              mock_wait_system_ready):
        mock_system = mock_redfish_utils.get_system.return_value
        mock_manager = mock.MagicMock()
        mock_system.managers = [mock_manager]
        mock_manager_oem = mock_manager.get_oem_extension.return_value

        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.known_good_state(task)
            mock_manager_oem.job_service.delete_jobs.assert_called_once_with(
                job_ids=['JID_CLEARALL'])
            mock_manager_oem.reset_idrac.assert_called_once_with()

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_ntp_servers(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.set_ntp_servers(
                task, ntp_servers=['10.0.0.1', '10.0.0.2'],
                timezone='US/Central')
        mock_set_attrs.assert_called_once_with(mock.ANY, {
            'NTPConfigGroup.1.NTPEnable': 'Enabled',
            'NTPConfigGroup.1.NTP1': '10.0.0.1',
            'NTPConfigGroup.1.NTP2': '10.0.0.2',
            'NTPConfigGroup.1.NTP3': '',
            'Time.1.Timezone': 'US/Central',
        })

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_ntp_servers_disable_and_extra(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.set_ntp_servers(
                task, ntp_servers=[], enable_ntp=False,
                extra_attributes={'NTPConfigGroup.1.NTPMaxDist': '16'})
        mock_set_attrs.assert_called_once_with(mock.ANY, {
            'NTPConfigGroup.1.NTPEnable': 'Disabled',
            'NTPConfigGroup.1.NTP1': '',
            'NTPConfigGroup.1.NTP2': '',
            'NTPConfigGroup.1.NTP3': '',
            'NTPConfigGroup.1.NTPMaxDist': '16',
        })

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_ntp_servers_invalid(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            self.assertRaises(
                exception.InvalidParameterValue,
                task.driver.management.set_ntp_servers,
                task, ntp_servers='10.0.0.1')
        self.assertFalse(mock_set_attrs.called)

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_dns_servers(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.set_dns_servers(
                task, dns_servers=['10.0.0.53'],
                dns_domain_name='example.com')
        mock_set_attrs.assert_called_once_with(mock.ANY, {
            'IPv4.1.DNSFromDHCP': 'Disabled',
            'IPv4Static.1.DNS1': '10.0.0.53',
            'IPv4Static.1.DNS2': '',
            'NIC.1.DNSDomainName': 'example.com',
            'NIC.1.DNSDomainFromDHCP': 'Disabled',
        })

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_dns_servers_invalid(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            self.assertRaises(
                exception.InvalidParameterValue,
                task.driver.management.set_dns_servers,
                task, dns_servers='10.0.0.53')
        self.assertFalse(mock_set_attrs.called)

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_oidc_config(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.set_oidc_config(
                task, discovery_url='https://idp/.well-known/'
                                    'openid-configuration',
                client_id='abc', client_secret='shhh', name='corp-sso')
        mock_set_attrs.assert_called_once_with(mock.ANY, {
            'OpenIDConnectServer.1.Enabled': 'Enabled',
            'OpenIDConnectServer.1.Name': 'corp-sso',
            'OpenIDConnectServer.1.DiscoveryURL':
                'https://idp/.well-known/openid-configuration',
            'OpenIDConnectServer.1.ClientID': 'abc',
            'OpenIDConnectServer.1.ClientSecret': 'shhh',
        })

    @mock.patch.object(drac_mgmt.drac_utils, 'set_dell_attributes',
                       autospec=True)
    def test_set_oidc_config_index_and_disable(self, mock_set_attrs):
        with task_manager.acquire(self.context, self.node.uuid,
                                  shared=False) as task:
            task.driver.management.set_oidc_config(
                task, enable_oidc=False, provider_index=2)
        mock_set_attrs.assert_called_once_with(mock.ANY, {
            'OpenIDConnectServer.2.Enabled': 'Disabled',
        })
