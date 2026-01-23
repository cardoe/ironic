"""Type stubs for task_manager module.

This file provides type hints for Python LSPs without modifying runtime behavior.
"""

from typing import Any, Callable, Optional, overload, Protocol, TypeVar
from ironic.common import driver_factory
from ironic.common import state_machine
from ironic import objects
from ironic.conductor import notification_utils
import futurist

_T = TypeVar('_T')
_CallableT = TypeVar('_CallableT', bound=Callable[..., Any])


def require_exclusive_lock(f: _CallableT) -> _CallableT: ...


class _TaskManagerLocked(Protocol):
    """Protocol representing TaskManager within a context manager.

    When TaskManager is used within a 'with' statement, the node property
    is guaranteed to be non-None until release_resources() is called.
    """
    context: Any
    node: objects.Node  # Non-optional within context
    ports: list[objects.Port]
    portgroups: list[objects.Portgroup]
    volume_connectors: list[objects.VolumeConnector]
    volume_targets: list[objects.VolumeTarget]
    driver: Optional[driver_factory.CompositeDriver]
    shared: bool
    fsm: state_machine.StateMachine

    def ensure_node(self) -> objects.Node: ...
    def upgrade_lock(self, purpose: Optional[str] = None, retry: Optional[bool] = None) -> None: ...
    def spawn_after(self, _spawn_method: Callable[..., Any], *args: Any, **kwargs: Any) -> None: ...
    def set_spawn_error_hook(self, _on_error_method: Callable[..., Any], *args: Any, **kwargs: Any) -> None: ...
    def downgrade_lock(self) -> None: ...
    def release_resources(self) -> None: ...
    def process_event(
        self,
        event: str,
        callback: Optional[Callable[..., Any]] = None,
        call_args: Optional[tuple[Any, ...]] = None,
        call_kwargs: Optional[dict[str, Any]] = None,
        err_handler: Optional[Callable[..., Any]] = None,
        target_state: Optional[str] = None,
        last_error: Optional[str] = None,
    ) -> None: ...
    def resume_cleaning(self) -> None: ...


class TaskManager:
    """Context manager for tasks.

    Note on typing: The 'node' property is Optional[Node] at the class level,
    but within the context manager (after __enter__, before __exit__), it is
    guaranteed to be non-None. LSPs should treat task.node as non-None when
    used within a 'with task_manager.acquire()' block.
    """

    context: Any
    node_id: str | int
    shared: bool
    fsm: Optional[state_machine.StateMachine]
    driver: Optional[driver_factory.CompositeDriver]

    def __init__(
        self,
        context: Any,
        node_id: str | int,
        shared: bool = False,
        purpose: str = 'unspecified action',
        retry: bool = True,
        patient: bool = False,
        load_driver: bool = True,
    ) -> None: ...

    @property
    def node(self) -> Optional[objects.Node]: ...

    @node.setter
    def node(self, node: Optional[objects.Node]) -> None: ...

    @property
    def ports(self) -> Optional[list[objects.Port]]: ...

    @ports.setter
    def ports(self, ports: Optional[list[objects.Port]]) -> None: ...

    @property
    def portgroups(self) -> Optional[list[objects.Portgroup]]: ...

    @portgroups.setter
    def portgroups(self, portgroups: Optional[list[objects.Portgroup]]) -> None: ...

    @property
    def volume_connectors(self) -> Optional[list[objects.VolumeConnector]]: ...

    @volume_connectors.setter
    def volume_connectors(self, volume_connectors: Optional[list[objects.VolumeConnector]]) -> None: ...

    @property
    def volume_targets(self) -> Optional[list[objects.VolumeTarget]]: ...

    @volume_targets.setter
    def volume_targets(self, volume_targets: Optional[list[objects.VolumeTarget]]) -> None: ...

    def ensure_node(self) -> objects.Node: ...

    def load_driver(self) -> None: ...

    def upgrade_lock(self, purpose: Optional[str] = None, retry: Optional[bool] = None) -> None: ...

    def spawn_after(self, _spawn_method: Callable[..., Any], *args: Any, **kwargs: Any) -> None: ...

    def set_spawn_error_hook(self, _on_error_method: Callable[..., Any], *args: Any, **kwargs: Any) -> None: ...

    def downgrade_lock(self) -> None: ...

    def release_resources(self) -> None: ...

    def process_event(
        self,
        event: str,
        callback: Optional[Callable[..., Any]] = None,
        call_args: Optional[tuple[Any, ...]] = None,
        call_kwargs: Optional[dict[str, Any]] = None,
        err_handler: Optional[Callable[..., Any]] = None,
        target_state: Optional[str] = None,
        last_error: Optional[str] = None,
    ) -> None: ...

    def resume_cleaning(self) -> None: ...

    # Type stub shows that __enter__ returns a TaskManager where node is guaranteed non-None
    def __enter__(self) -> _TaskManagerLocked: ...

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None: ...


@overload
def acquire(
    context: Any,
    node_id: str | int,
    shared: bool = False,
    purpose: str = 'unspecified action',
    retry: bool = True,
    patient: bool = False,
    load_driver: bool = True,
) -> TaskManager: ...
