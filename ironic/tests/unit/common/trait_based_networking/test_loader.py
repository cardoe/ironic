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

from ironic.common.trait_based_networking import base as tbn_base
from ironic.common.trait_based_networking import defaults
from ironic.common.trait_based_networking import loader
from ironic.common.trait_based_networking.loader import ConfigLoader
from ironic.conf import CONF

from ironic.tests import base

import os
import tempfile
import time
from unittest import mock


class TraitBasedNetworkingConfigLoaderTestCase(base.TestCase):
    def test_config_loader(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        contents = ("CUSTOM_TRAIT_NAME:\n"
                    "  actions:\n"
                    "    - action: bond_ports\n"
                    "      filter: port.vendor == 'vendor_string'\n"
                    "      min_count: 2\n")
        with tempfile.NamedTemporaryFile(
                mode='w',
                dir=self.tmpdir.name,
                delete=False) as tmpfile:
            tmpfile.write(contents)
            tmpfile.close()

            self.config(trait_based_networking_config_file=tmpfile.name,
                        group='conductor')
            self.config(enable_trait_based_networking=True, group='conductor')

            cl = ConfigLoader()
            self.assertEqual(len(cl.traits), 1)

    def test_config_loader_refresh(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        contents = ("CUSTOM_TRAIT_NAME:\n"
                    "  actions:\n"
                    "    - action: bond_ports\n"
                    "      filter: port.vendor == 'vendor_string'\n"
                    "      min_count: 2\n")
        with tempfile.NamedTemporaryFile(
                mode='w',
                dir=self.tmpdir.name,
                delete=False) as tmpfile:
            tmpfile.write(contents)
            tmpfile.close()

            self.config(trait_based_networking_config_file=tmpfile.name,
                        group='conductor')
            self.config(enable_trait_based_networking=True, group='conductor')

            cl = ConfigLoader()
            self.assertEqual(len(cl.traits), 1)
            self.assertEqual(cl.traits[0].name, "CUSTOM_TRAIT_NAME")

            # Refresh, nothing should change.
            old_mtime = cl._last_mtime
            cl.refresh()
            self.assertEqual(old_mtime, cl._last_mtime)
            self.assertEqual(len(cl.traits), 1)
            self.assertEqual(cl.traits[0].name, "CUSTOM_TRAIT_NAME")

            # Try to guarantee the mtime will change.
            time.sleep(1)

            with open(tmpfile.name, mode='w') as newfile:
                contents = ("CUSTOM_TRAIT_NAME_CHANGED:\n"
                            "  actions:\n"
                            "    - action: bond_ports\n"
                            "      filter: port.vendor == 'vendor_string'\n"
                            "      min_count: 2\n")
                newfile.write(contents)
                newfile.close()

                cl.refresh()
                self.assertNotEqual(old_mtime, cl._last_mtime)
                self.assertEqual(len(cl.traits), 1)
                self.assertEqual(cl.traits[0].name,
                                 "CUSTOM_TRAIT_NAME_CHANGED")

    def test_bundled_config_exists(self):
        self.assertTrue(loader.bundled_config().is_file())

    def test_config_loader_uses_bundled_config(self):
        self.config(enable_trait_based_networking=True, group='conductor')
        self.assertIsNone(CONF.conductor.trait_based_networking_config_file)

        cl = ConfigLoader()
        self.assertTrue(cl.valid)
        self.assertEqual(1, len(cl.traits))
        trait = cl.traits[0]
        self.assertEqual(defaults.DEFAULT_TRAIT_NAME, trait.name)
        self.assertEqual(2, len(trait.actions))
        pg_action, port_action = trait.actions
        self.assertEqual(tbn_base.Actions.ATTACH_PORTGROUP, pg_action.action)
        self.assertEqual(1, pg_action.max_count)
        self.assertEqual(("port.physical_network",), pg_action.sort)
        self.assertEqual(tbn_base.Actions.ATTACH_PORT, port_action.action)
        self.assertEqual(1, port_action.max_count)
        self.assertEqual(("port.physical_network", "port.pxe_enabled"),
                         port_action.sort)

    def test_config_loader_bundled_config_loaded_once(self):
        self.config(enable_trait_based_networking=True, group='conductor')
        cl = ConfigLoader()
        with mock.patch.object(cl, '_load_tbn_config',
                               autospec=True) as mock_load:
            cl.refresh()
            mock_load.assert_not_called()

    def test_config_loader_switch_from_bundled_to_file(self):
        self.config(enable_trait_based_networking=True, group='conductor')
        cl = ConfigLoader()
        self.assertEqual(defaults.DEFAULT_TRAIT_NAME, cl.traits[0].name)

        contents = ("CUSTOM_TRAIT_NAME:\n"
                    "  actions:\n"
                    "    - action: attach_port\n"
                    "      filter: port.vendor == 'vendor_string'\n")
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, 'tbn.yaml')
            with open(path, 'w') as f:
                f.write(contents)
            self.config(trait_based_networking_config_file=path,
                        group='conductor')
            cl.refresh()

        self.assertEqual(1, len(cl.traits))
        self.assertEqual("CUSTOM_TRAIT_NAME", cl.traits[0].name)

    @mock.patch.object(loader, 'LOG', autospec=True)
    def test_config_loader_warns_deprecated_sort_key_bundled(self, mock_log):
        self.config(enable_trait_based_networking=True, group='conductor')
        ConfigLoader()
        mock_log.warning.assert_called_once_with(
            mock.ANY, {'trait': defaults.DEFAULT_TRAIT_NAME,
                       'file': loader.bundled_config(),
                       'key': 'port.pxe_enabled'})

    @mock.patch.object(loader, 'LOG', autospec=True)
    def test_config_loader_no_deprecated_sort_key(self, mock_log):
        contents = ("CUSTOM_TRAIT_NAME:\n"
                    "  actions:\n"
                    "    - action: attach_port\n"
                    "      filter: port.is_port\n"
                    "      sort:\n"
                    "        - port.physical_network\n")
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, 'tbn.yaml')
            with open(path, 'w') as f:
                f.write(contents)
            self.config(trait_based_networking_config_file=path,
                        group='conductor')
            self.config(enable_trait_based_networking=True,
                        group='conductor')
            cl = ConfigLoader()

        self.assertTrue(cl.valid)
        mock_log.warning.assert_not_called()
