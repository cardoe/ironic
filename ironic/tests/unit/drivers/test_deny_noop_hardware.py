# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

from ironic.conductor import task_manager
from ironic.drivers import base as driver_base
from ironic.drivers import generic
from ironic.drivers.modules import deny
from ironic.drivers.modules import noop
from ironic.drivers import redfish
from ironic.tests.unit.db import base as db_base
from ironic.tests.unit.objects import utils as obj_utils

# Entry point name 'noop' is already used by other classes for these.
_NO_NOOP_ENTRY = {'management', 'network', 'storage'}


class SupportedInterfacesTestCase(db_base.DbTestCase):

    def _check(self, hw_type):
        for itype in driver_base.ALL_INTERFACES:
            supported = getattr(hw_type, 'supported_%s_interfaces' % itype)
            with self.subTest(hw_type=type(hw_type).__name__,
                              interface=itype):
                names = {c.__name__ for c in supported}
                self.assertIn('Deny%s' % self._cls(itype), names)
                if itype not in _NO_NOOP_ENTRY:
                    self.assertIn('Noop%s' % self._cls(itype), names)

    @staticmethod
    def _cls(itype):
        return {'bios': 'BIOS', 'raid': 'RAID'}.get(itype, itype.title())

    def test_manual_management(self):
        self._check(generic.ManualManagementHardware())

    def test_redfish(self):
        self._check(redfish.RedfishHardware())

    def test_protected_node(self):
        """A node can deny interfaces that could alter its hardware."""
        self.config(enabled_hardware_types=['manual-management'],
                    enabled_power_interfaces=['fake'],
                    enabled_management_interfaces=['fake'],
                    enabled_bios_interfaces=['no-bios', 'deny'],
                    enabled_raid_interfaces=['no-raid', 'deny'],
                    enabled_firmware_interfaces=['no-firmware', 'deny'],
                    enabled_console_interfaces=['no-console', 'noop'])
        node = obj_utils.create_test_node(
            self.context, driver='manual-management',
            bios_interface='deny', raid_interface='deny',
            firmware_interface='deny', console_interface='noop')
        with task_manager.acquire(self.context, node.uuid) as task:
            self.assertIsInstance(task.driver.bios, deny.DenyBIOS)
            self.assertIsInstance(task.driver.raid, deny.DenyRAID)
            self.assertIsInstance(task.driver.firmware, deny.DenyFirmware)
            self.assertIsInstance(task.driver.console, noop.NoopConsole)
