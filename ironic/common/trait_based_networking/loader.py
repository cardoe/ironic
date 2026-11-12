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

from ironic.common.i18n import _
from ironic.common.trait_based_networking import base
from ironic.common.trait_based_networking.config_file import ConfigFile
from ironic.conf import CONF

from oslo_log import log

import importlib.resources
import os
import threading


LOG = log.getLogger(__name__)

_LOADER_LOCK = threading.Lock()
_CACHED_CONFIG_LOADER = None

BUNDLED_CONFIG_PACKAGE = 'ironic.common.trait_based_networking'
BUNDLED_CONFIG_FILE = 'default_config.yaml'


def bundled_config():
    """Return the TBN configuration bundled with Ironic.

    :returns: An importlib.resources Traversable for the bundled
        configuration file.
    """
    return importlib.resources.files(BUNDLED_CONFIG_PACKAGE).joinpath(
        BUNDLED_CONFIG_FILE)


def _config_source():
    """The configured TBN file path, or the bundled config if unset."""
    return (CONF.conductor.trait_based_networking_config_file
            or bundled_config())


def tbn_config_file_traits():
    """Get TBN traits from the configured YAML file.

    Thread-safe way to retrieve the configured and parsed TBN traits.
    """
    global _CACHED_CONFIG_LOADER
    with _LOADER_LOCK:
        if _CACHED_CONFIG_LOADER is None:
            _CACHED_CONFIG_LOADER = ConfigLoader()
        _CACHED_CONFIG_LOADER.refresh()
        return _CACHED_CONFIG_LOADER.traits


def is_config_valid():
    with _LOADER_LOCK:
        if _CACHED_CONFIG_LOADER is None:
            return False
        return _CACHED_CONFIG_LOADER.valid


def _warn_deprecated_sort_keys(traits, source):
    """Log a warning for each trait action using a deprecated sort key."""
    for trait in traits:
        for action in trait.actions:
            for key in action.sort or ():
                if key in base.DEPRECATED_SORT_KEYS:
                    LOG.warning('Trait Based Networking trait %(trait)s in '
                                'configuration %(file)s uses the deprecated '
                                'sort key %(key)s. It will be removed in a '
                                'future release.',
                                {'trait': trait.name, 'file': source,
                                 'key': key})


class ConfigLoader(object):
    """Extends ConfigFile and provides automatic config file change detection

    Not intended for consumption outside of this module. Use the module level
    tbn_config_file_traits() function to retrieve configured and parsed traits.
    """
    def __init__(self):
        self._last_mtime = None
        self._last_path = None
        self._checked = False
        self._config_file = None
        self._valid = False
        self.refresh()

    def _has_file_changed(self):
        """Returns True if the underlying config file has changed.

        A change is either a different configured file or a change in the
        configured file's mtime. The bundled configuration ships with Ironic
        and is only loaded once.
        """
        path = CONF.conductor.trait_based_networking_config_file
        new_mtime = os.path.getmtime(path) if path else None

        if (self._checked and path == self._last_path
                and new_mtime == self._last_mtime):
            return False

        self._checked = True
        self._last_path = path
        self._last_mtime = new_mtime
        return True

    def refresh(self):
        if self._has_file_changed():
            self._load_tbn_config()

    @property
    def valid(self):
        return self._valid

    @property
    def traits(self):
        if self._config_file is None:
            return []
        return self._config_file.traits()

    def _load_tbn_config(self):
        """Load Trait Based Networking configuration file for later use"""
        if not CONF.conductor.enable_trait_based_networking:
            LOG.debug('Trait Based Networking not enabled, skipping loading '
                      'configuration file.')
            return

        source = _config_source()
        LOG.info(('Loading Trait Based Networking configuration located at '
                  '%(file_location)s'), {'file_location': source})
        try:
            self._config_file = ConfigFile(source)
        except OSError as err:
            self._valid = False
            LOG.error(('Failed to load Trait Based Networking configuration '
                       'file located at \'%(file)s\', error: %(err)s'), {
                           'file': source, 'err': err})
            return

        valid, reasons = self._config_file.validate()

        if not valid:
            self._valid = False
            LOG.error(('Configuration file for Trait Based Networking '
                       'located at \'%(file)s\' is invalid. Reasons '
                       'follow:'), {'file': source})
            for reason in reasons:
                LOG.error(reason)

            return

        # NOTE(clif) If we made it here the configuration should parse.
        self._config_file.parse()
        _warn_deprecated_sort_keys(self._config_file.traits(), source)

        self._valid = True
        LOG.info(_('Successfully loaded and parsed configuration for '
                   'Trait Based Networking.'))
