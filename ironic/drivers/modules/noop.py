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

"""
Interface implementations that accept every request and do nothing.

Validation always passes, actions succeed without side effects, and getters
return empty or neutral values. For interfaces that should explicitly refuse
requests, see :mod:`ironic.drivers.modules.deny`.

Conductor periodic tasks are skipped for these interfaces.
"""

from oslo_log import log

from ironic.common import boot_devices
from ironic.common import states
from ironic.drivers import base

LOG = log.getLogger(__name__)


class NoopMixin(object):
    """Mixin making an interface validate successfully and skip periodics."""

    skip_periodics = True

    def get_properties(self):
        return {}

    def validate(self, task):
        pass


class NoopBoot(NoopMixin, base.BootInterface):
    """Boot interface that does nothing."""

    def prepare_ramdisk(self, task, ramdisk_params):
        pass

    def clean_up_ramdisk(self, task):
        pass

    def prepare_instance(self, task):
        pass

    def clean_up_instance(self, task):
        pass


class NoopConsole(NoopMixin, base.ConsoleInterface):
    """Console interface that does nothing."""

    def start_console(self, task):
        pass

    def stop_console(self, task):
        pass

    def get_console(self, task):
        return {}


class NoopDeploy(NoopMixin, base.DeployInterface):
    """Deploy interface that does nothing and succeeds."""

    @base.deploy_step(priority=100)
    def deploy(self, task):
        return None

    def tear_down(self, task):
        return states.DELETED

    def prepare(self, task):
        pass

    def clean_up(self, task):
        pass

    def take_over(self, task):
        pass


class NoopFirmware(NoopMixin, base.FirmwareInterface):
    """Firmware interface that does nothing."""

    def update(self, task, settings):
        pass

    def cache_firmware_components(self, task):
        pass


class NoopBIOS(NoopMixin, base.BIOSInterface):
    """BIOS interface that does nothing."""

    def apply_configuration(self, task, settings):
        pass

    def factory_reset(self, task):
        pass

    def cache_bios_settings(self, task):
        pass


class NoopInspect(NoopMixin, base.InspectInterface):
    """Inspect interface that does nothing and completes immediately."""

    def inspect_hardware(self, task):
        return states.MANAGEABLE


class NoopManagement(NoopMixin, base.ManagementInterface):
    """Management interface that does nothing.

    Assumes the boot order is preconfigured to try PXE first, then disk.
    """

    def get_supported_boot_devices(self, task):
        return [boot_devices.PXE, boot_devices.DISK]

    def set_boot_device(self, task, device, persistent=False):
        LOG.debug('Ignoring request to set boot device to %(dev)s for node '
                  '%(node)s: noop management interface',
                  {'dev': device, 'node': task.node.uuid})

    def get_boot_device(self, task):
        return {'boot_device': boot_devices.PXE, 'persistent': True}

    def get_sensors_data(self, task):
        return {}


class NoopNetwork(NoopMixin, base.NetworkInterface):
    """Network interface that does nothing."""

    def port_changed(self, task, port_obj):
        pass

    def portgroup_changed(self, task, portgroup_obj):
        pass

    def vif_attach(self, task, vif_info):
        pass

    def vif_detach(self, task, vif_id):
        pass

    def vif_list(self, task):
        return []

    def get_current_vif(self, task, p_obj):
        return None

    def add_provisioning_network(self, task):
        pass

    def remove_provisioning_network(self, task):
        pass

    def configure_tenant_networks(self, task):
        pass

    def unconfigure_tenant_networks(self, task):
        pass

    def add_cleaning_network(self, task):
        pass

    def remove_cleaning_network(self, task):
        pass


class NoopPower(NoopMixin, base.PowerInterface):
    """Power interface that does nothing.

    The power state reported is whatever the node already has recorded.
    """

    def get_power_state(self, task):
        return task.node.power_state or states.NOSTATE

    def set_power_state(self, task, power_state, timeout=None):
        pass

    def reboot(self, task, timeout=None):
        pass

    def supports_power_sync(self, task):
        return False


class NoopRAID(NoopMixin, base.RAIDInterface):
    """RAID interface that does nothing."""

    def create_configuration(self, task, create_root_volume=True,
                             create_nonroot_volumes=True,
                             delete_existing=True):
        pass

    def delete_configuration(self, task):
        pass

    def validate_raid_config(self, task, raid_config):
        pass


class NoopRescue(NoopMixin, base.RescueInterface):
    """Rescue interface that does nothing and completes immediately."""

    def rescue(self, task):
        return states.RESCUE

    def unrescue(self, task):
        return states.ACTIVE


class NoopStorage(NoopMixin, base.StorageInterface):
    """Storage interface that does nothing."""

    def attach_volumes(self, task):
        pass

    def detach_volumes(self, task):
        pass

    def should_write_image(self, task):
        return True


class NoopVendor(NoopMixin, base.VendorInterface):
    """Vendor interface that does nothing."""

    def validate(self, task, method=None, **kwargs):
        pass

    def driver_validate(self, method, **kwargs):
        pass
