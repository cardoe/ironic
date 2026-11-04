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

from ironic.common import boot_devices
from ironic.common import states
from ironic.drivers import base
from ironic.drivers.modules import noop
from ironic.tests import base as test_base

_CLASSES = [
    (noop.NoopBoot, 'boot'), (noop.NoopConsole, 'console'),
    (noop.NoopDeploy, 'deploy'), (noop.NoopFirmware, 'firmware'),
    (noop.NoopBIOS, 'bios'), (noop.NoopInspect, 'inspect'),
    (noop.NoopManagement, 'management'), (noop.NoopNetwork, 'network'),
    (noop.NoopPower, 'power'), (noop.NoopRAID, 'raid'),
    (noop.NoopRescue, 'rescue'), (noop.NoopStorage, 'storage'),
    (noop.NoopVendor, 'vendor'),
]

# Groups where the entry point name 'noop' already maps to a legacy class.
_LEGACY_NOOP_NAMES = {'management', 'network', 'storage'}


class NoopInterfacesTestCase(test_base.TestCase):
    def setUp(self):
        super().setUp()
        self.node = mock.Mock(driver='fake-hw', power_state=None,
                              uuid='uuid')
        self.task = mock.Mock(node=self.node, spec=['node'])

    def test_common(self):
        for cls, itype in _CLASSES:
            with self.subTest(cls=cls.__name__):
                iface = cls()
                self.assertIsNone(iface.validate(self.task))
                self.assertEqual({}, iface.get_properties())
                self.assertTrue(iface.skip_periodics)
                self.assertEqual(itype, iface.interface_type)

    def test_complete_suite(self):
        self.assertEqual(base.ALL_INTERFACES, {c[1] for c in _CLASSES})

    def test_boot(self):
        iface = noop.NoopBoot()
        self.assertIsNone(iface.prepare_ramdisk(self.task, {}))
        self.assertIsNone(iface.clean_up_ramdisk(self.task))
        self.assertIsNone(iface.prepare_instance(self.task))
        self.assertIsNone(iface.clean_up_instance(self.task))

    def test_console(self):
        iface = noop.NoopConsole()
        self.assertIsNone(iface.start_console(self.task))
        self.assertIsNone(iface.stop_console(self.task))
        self.assertEqual({}, iface.get_console(self.task))

    def test_deploy(self):
        iface = noop.NoopDeploy()
        self.assertIsNone(iface.deploy(self.task))
        self.assertEqual(states.DELETED, iface.tear_down(self.task))
        self.assertIsNone(iface.prepare(self.task))
        self.assertIsNone(iface.clean_up(self.task))
        self.assertIsNone(iface.take_over(self.task))
        self.assertEqual(['deploy'], [s['step'] for s in iface.deploy_steps])

    def test_firmware_bios(self):
        fw = noop.NoopFirmware()
        self.assertIsNone(fw.update(self.task, []))
        self.assertIsNone(fw.cache_firmware_components(self.task))
        bios = noop.NoopBIOS()
        self.assertIsNone(bios.apply_configuration(self.task, []))
        self.assertIsNone(bios.factory_reset(self.task))
        self.assertIsNone(bios.cache_bios_settings(self.task))

    def test_inspect(self):
        self.assertEqual(states.MANAGEABLE,
                         noop.NoopInspect().inspect_hardware(self.task))

    def test_management(self):
        iface = noop.NoopManagement()
        self.assertEqual([boot_devices.PXE, boot_devices.DISK],
                         iface.get_supported_boot_devices(self.task))
        self.assertIsNone(iface.set_boot_device(self.task, boot_devices.PXE))
        self.assertEqual({'boot_device': boot_devices.PXE,
                          'persistent': True},
                         iface.get_boot_device(self.task))
        self.assertEqual({}, iface.get_sensors_data(self.task))

    def test_network(self):
        iface = noop.NoopNetwork()
        self.assertIsNone(iface.port_changed(self.task, None))
        self.assertIsNone(iface.portgroup_changed(self.task, None))
        self.assertIsNone(iface.vif_attach(self.task, {'id': 'x'}))
        self.assertIsNone(iface.vif_detach(self.task, 'x'))
        self.assertEqual([], iface.vif_list(self.task))
        self.assertIsNone(iface.get_current_vif(self.task, None))
        for name in ('add_provisioning_network',
                     'remove_provisioning_network',
                     'configure_tenant_networks',
                     'unconfigure_tenant_networks',
                     'add_cleaning_network', 'remove_cleaning_network'):
            self.assertIsNone(getattr(iface, name)(self.task))

    def test_power(self):
        iface = noop.NoopPower()
        self.assertEqual(states.NOSTATE, iface.get_power_state(self.task))
        self.node.power_state = states.POWER_ON
        self.assertEqual(states.POWER_ON, iface.get_power_state(self.task))
        self.assertIsNone(iface.set_power_state(self.task, states.POWER_OFF))
        self.assertIsNone(iface.reboot(self.task))
        self.assertFalse(iface.supports_power_sync(self.task))

    def test_raid(self):
        iface = noop.NoopRAID()
        self.assertIsNone(iface.create_configuration(self.task))
        self.assertIsNone(iface.delete_configuration(self.task))
        self.assertIsNone(iface.validate_raid_config(self.task, {}))

    def test_rescue(self):
        iface = noop.NoopRescue()
        self.assertEqual(states.RESCUE, iface.rescue(self.task))
        self.assertEqual(states.ACTIVE, iface.unrescue(self.task))

    def test_storage(self):
        iface = noop.NoopStorage()
        self.assertIsNone(iface.attach_volumes(self.task))
        self.assertIsNone(iface.detach_volumes(self.task))
        self.assertTrue(iface.should_write_image(self.task))

    def test_vendor(self):
        iface = noop.NoopVendor()
        self.assertIsNone(iface.validate(self.task, method='x'))
        self.assertIsNone(iface.driver_validate('x'))

    def test_deploy_legacy_name(self):
        mgr = stevedore.extension.ExtensionManager(
            'ironic.hardware.interfaces.deploy', invoke_on_load=False)
        self.assertIs(noop.NoopDeploy, mgr['noop'].plugin)

    def test_entry_points(self):
        for cls, itype in _CLASSES:
            if itype in _LEGACY_NOOP_NAMES:
                continue
            with self.subTest(interface=itype):
                mgr = stevedore.extension.ExtensionManager(
                    'ironic.hardware.interfaces.%s' % itype,
                    invoke_on_load=False)
                self.assertIs(cls, mgr['noop'].plugin)
