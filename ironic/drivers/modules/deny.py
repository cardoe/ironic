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
Interface implementations that deny every request.

Use these to explicitly state that a feature is unavailable: validation fails
and every action raises ``UnsupportedDriverExtension``. The only exceptions
are the methods that merely refresh cached data (caching BIOS settings and
firmware components), which succeed without doing anything. For interfaces that
should accept requests and silently do nothing, see
:mod:`ironic.drivers.modules.noop`.

Conductor periodic tasks are skipped for these interfaces.
"""

from ironic.common import exception
from ironic.drivers import base


def _deny(iface, task=None, *args, **kwargs):
    driver = task.node.driver if task is not None else type(iface).__name__
    raise exception.UnsupportedDriverExtension(
        driver=driver, extension=iface.interface_type)


class DenyMixin(object):
    """Mixin making an interface fail validation and skip periodics."""

    skip_periodics = True

    def get_properties(self):
        return {}

    validate = _deny


class DenyBoot(DenyMixin, base.BootInterface):
    """Boot interface that denies all requests."""
    prepare_ramdisk = clean_up_ramdisk = _deny
    prepare_instance = clean_up_instance = _deny


class DenyConsole(DenyMixin, base.ConsoleInterface):
    """Console interface that denies all requests."""
    start_console = stop_console = get_console = _deny


class DenyDeploy(DenyMixin, base.DeployInterface):
    """Deploy interface that denies all requests."""
    deploy = tear_down = prepare = clean_up = take_over = _deny


class DenyFirmware(DenyMixin, base.FirmwareInterface):
    """Firmware interface that denies all requests."""
    update = _deny

    def cache_firmware_components(self, task):
        # NOTE: called by the conductor on a best-effort basis to refresh
        # cached data, so it must not fail.
        pass


class DenyBIOS(DenyMixin, base.BIOSInterface):
    """BIOS interface that denies all requests."""
    apply_configuration = factory_reset = _deny

    def cache_bios_settings(self, task):
        # NOTE: called by the conductor on a best-effort basis to refresh
        # cached data, so it must not fail.
        pass


class DenyInspect(DenyMixin, base.InspectInterface):
    """Inspect interface that denies all requests."""
    inspect_hardware = _deny


class DenyManagement(DenyMixin, base.ManagementInterface):
    """Management interface that denies all requests."""
    get_supported_boot_devices = set_boot_device = _deny
    get_boot_device = get_sensors_data = _deny


class DenyNetwork(DenyMixin, base.NetworkInterface):
    """Network interface that denies all requests."""
    port_changed = portgroup_changed = _deny
    vif_attach = vif_detach = vif_list = get_current_vif = _deny
    add_provisioning_network = remove_provisioning_network = _deny
    configure_tenant_networks = unconfigure_tenant_networks = _deny
    add_cleaning_network = remove_cleaning_network = _deny


class DenyPower(DenyMixin, base.PowerInterface):
    """Power interface that denies all requests."""
    get_power_state = set_power_state = reboot = _deny

    def get_supported_power_states(self, task):
        return []

    def supports_power_sync(self, task):
        return False


class DenyRAID(DenyMixin, base.RAIDInterface):
    """RAID interface that denies all requests."""
    create_configuration = delete_configuration = _deny
    validate_raid_config = _deny


class DenyRescue(DenyMixin, base.RescueInterface):
    """Rescue interface that denies all requests."""
    rescue = unrescue = _deny


class DenyStorage(DenyMixin, base.StorageInterface):
    """Storage interface that denies all requests."""
    attach_volumes = detach_volumes = should_write_image = _deny


class DenyVendor(DenyMixin, base.VendorInterface):
    """Vendor interface that denies all requests."""

    def driver_validate(self, method, **kwargs):
        raise exception.UnsupportedDriverExtension(
            driver=type(self).__name__, extension=self.interface_type)
