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

from unittest import mock

import stevedore

from ironic.common import exception
from ironic.drivers import base
from ironic.drivers.modules import deny
from ironic.tests import base as test_base

# (class, interface type, [(method name, args)])
_CASES = [
    (deny.DenyBoot, 'boot', [
        ('prepare_ramdisk', ({},)), ('clean_up_ramdisk', ()),
        ('prepare_instance', ()), ('clean_up_instance', ())]),
    (deny.DenyConsole, 'console', [
        ('start_console', ()), ('stop_console', ()), ('get_console', ())]),
    (deny.DenyDeploy, 'deploy', [
        ('deploy', ()), ('tear_down', ()), ('prepare', ()),
        ('clean_up', ()), ('take_over', ())]),
    (deny.DenyFirmware, 'firmware', [
        ('update', ([],))]),
    (deny.DenyBIOS, 'bios', [
        ('apply_configuration', ([],)), ('factory_reset', ())]),
    (deny.DenyInspect, 'inspect', [('inspect_hardware', ())]),
    (deny.DenyManagement, 'management', [
        ('get_supported_boot_devices', ()), ('set_boot_device', ('pxe',)),
        ('get_boot_device', ()), ('get_sensors_data', ())]),
    (deny.DenyNetwork, 'network', [
        ('port_changed', (None,)), ('portgroup_changed', (None,)),
        ('vif_attach', ({},)), ('vif_detach', ('id',)), ('vif_list', ()),
        ('get_current_vif', (None,)), ('add_provisioning_network', ()),
        ('remove_provisioning_network', ()),
        ('configure_tenant_networks', ()),
        ('unconfigure_tenant_networks', ()), ('add_cleaning_network', ()),
        ('remove_cleaning_network', ())]),
    (deny.DenyPower, 'power', [
        ('get_power_state', ()), ('set_power_state', ('power on',)),
        ('reboot', ())]),
    (deny.DenyRAID, 'raid', [
        ('create_configuration', ()), ('delete_configuration', ()),
        ('validate_raid_config', ({},))]),
    (deny.DenyRescue, 'rescue', [('rescue', ()), ('unrescue', ())]),
    (deny.DenyStorage, 'storage', [
        ('attach_volumes', ()), ('detach_volumes', ()),
        ('should_write_image', ())]),
    (deny.DenyVendor, 'vendor', []),
]


class DenyInterfacesTestCase(test_base.TestCase):
    task = mock.Mock(node=mock.Mock(driver='fake-hw', spec=['driver']),
                     spec=['node'])

    def test_all_actions_denied(self):
        for cls, _itype, methods in _CASES:
            iface = cls()
            for name, args in methods:
                with self.subTest(cls=cls.__name__, method=name):
                    self.assertRaises(exception.UnsupportedDriverExtension,
                                      getattr(iface, name), self.task, *args)

    def test_validate_denied(self):
        for cls, _itype, _methods in _CASES:
            with self.subTest(cls=cls.__name__):
                self.assertRaises(exception.UnsupportedDriverExtension,
                                  cls().validate, self.task)

    def test_properties_empty_and_periodics_skipped(self):
        for cls, itype, _methods in _CASES:
            with self.subTest(cls=cls.__name__):
                iface = cls()
                self.assertEqual({}, iface.get_properties())
                self.assertTrue(iface.skip_periodics)
                self.assertEqual(itype, iface.interface_type)

    def test_vendor_driver_validate_denied(self):
        self.assertRaises(exception.UnsupportedDriverExtension,
                          deny.DenyVendor().driver_validate, 'method')

    def test_cache_methods_succeed(self):
        self.assertIsNone(deny.DenyBIOS().cache_bios_settings(self.task))
        self.assertIsNone(
            deny.DenyFirmware().cache_firmware_components(self.task))

    def test_power_flags(self):
        iface = deny.DenyPower()
        self.assertEqual([], iface.get_supported_power_states(self.task))
        self.assertFalse(iface.supports_power_sync(self.task))

    def test_complete_suite(self):
        self.assertEqual(base.ALL_INTERFACES,
                         {c[1] for c in _CASES})

    def test_default_flag_is_false(self):
        self.assertFalse(base.BaseInterface.skip_periodics)

    def test_entry_points(self):
        for cls, itype, _methods in _CASES:
            with self.subTest(interface=itype):
                mgr = stevedore.extension.ExtensionManager(
                    'ironic.hardware.interfaces.%s' % itype,
                    invoke_on_load=False)
                self.assertIs(cls, mgr['deny'].plugin)
