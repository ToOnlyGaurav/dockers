#!/usr/bin/env python3
"""
Aerospike Multi-Site Strong Consistency Cluster Visualizer
==========================================================

A live terminal dashboard that polls all 7 Aerospike nodes and renders
a rich, color-coded view of the cluster topology, health, and metrics.

Requirements:
    pip install rich

Usage:
    python3 scripts/cluster-visualizer.py              # default 2s refresh
    python3 scripts/cluster-visualizer.py --interval 5 # 5s refresh
    python3 scripts/cluster-visualizer.py --once        # single snapshot, no loop

The script uses `docker exec` + `asinfo` to query each node, so it must
be run on the Docker host where the containers are running.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

try:
    from rich.align import Align
    from rich.columns import Columns
    from rich.console import Console, Group
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:
    print("ERROR: 'rich' library is required. Install it with:")
    print("  pip install rich")
    sys.exit(1)

# =============================================================================
# Cluster topology definition
# =============================================================================

NAMESPACE = "mynamespace"

NODES = [
    {"container": "site1-node1", "ip": "172.28.0.11", "node_id": "A1", "rack_id": 1, "site": "Site 1", "dc": "DC1"},
    {"container": "site1-node2", "ip": "172.28.0.12", "node_id": "A2", "rack_id": 1, "site": "Site 1", "dc": "DC1"},
    {"container": "site1-node3", "ip": "172.28.0.13", "node_id": "A3", "rack_id": 1, "site": "Site 1", "dc": "DC1"},
    {"container": "site2-node1", "ip": "172.28.0.21", "node_id": "B1", "rack_id": 2, "site": "Site 2", "dc": "DC2"},
    {"container": "site2-node2", "ip": "172.28.0.22", "node_id": "B2", "rack_id": 2, "site": "Site 2", "dc": "DC2"},
    {"container": "site2-node3", "ip": "172.28.0.23", "node_id": "B3", "rack_id": 2, "site": "Site 2", "dc": "DC2"},
    {"container": "quorum-node", "ip": "172.28.0.31", "node_id": "C1", "rack_id": 3, "site": "Quorum", "dc": "DC1"},
]


@dataclass
class NodeStatus:
    """Holds the polled status of a single Aerospike node."""
    container: str
    ip: str
    node_id: str
    rack_id: int
    site: str
    dc: str = ""

    # Docker state
    docker_running: bool = False
    docker_health: str = "unknown"  # healthy, unhealthy, starting, unknown

    # Aerospike state (only populated if docker is running + reachable)
    reachable: bool = False
    cluster_size: int = 0
    cluster_key: str = ""
    uptime: int = 0  # seconds
    objects: int = 0
    master_objects: int = 0
    prole_objects: int = 0
    used_bytes_memory: int = 0
    used_bytes_disk: int = 0
    avail_pct: int = 0
    stop_writes: bool = False
    unavailable_partitions: int = 0
    dead_partitions: int = 0
    migrate_tx_remaining: int = 0
    migrate_rx_remaining: int = 0
    strong_consistency: bool = False
    roster_set: bool = False
    principal: bool = False
    # Partition details
    partitions_master: int = 0
    partitions_replica1: int = 0
    partitions_replica2: int = 0
    partitions_absent: int = 0
    partitions_total_owned: int = 0  # master + all replicas on this node
    effective_replication_factor: int = 0
    active_rack: int = 0  # 0 means not set
    quiesced: bool = False
    # Additional
    client_connections: int = 0
    cpu_pct: int = 0
    free_mem_pct: int = 0
    error: str = ""


@dataclass
class ClusterState:
    """Aggregated cluster state."""
    nodes: list = field(default_factory=list)
    poll_time: float = 0.0
    poll_duration_ms: float = 0.0
    roster_nodes: str = ""
    observed_nodes: str = ""
    replication_factor: int = 0
    active_rack: int = 0


# =============================================================================
# Data collection
# =============================================================================

def run_cmd(cmd: list[str], timeout: int = 5) -> Optional[str]:
    """Run a command and return stdout, or None on failure."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


def parse_kv(text: str, sep: str = ";") -> dict:
    """Parse 'key=value<sep>key=value...' into a dict."""
    result = {}
    if not text:
        return result
    for part in text.split(sep):
        if "=" in part:
            k, v = part.split("=", 1)
            result[k.strip()] = v.strip()
    return result


def get_docker_state(container: str) -> tuple[bool, str]:
    """Return (running, health) for a container."""
    out = run_cmd([
        "docker", "inspect", "--format",
        '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',
        container,
    ])
    if out is None:
        return False, "unknown"
    parts = out.split("|")
    running = parts[0].lower() == "true"
    health = parts[1] if len(parts) > 1 else "unknown"
    return running, health


def parse_partition_info(raw: str) -> dict:
    """
    Parse the output of 'asinfo -v partition-info:namespace=...' and return
    a dict with counts: master, replica1, replica2, absent, total_owned.

    The output is semicolon-delimited records; each record has colon-delimited
    fields. The first record is the header row. Key fields:
      - state: S (sync/owned) or A (absent)
      - replica: 0 (master), 1 (replica-1), 2 (replica-2), -1 (absent)
    """
    counts = {"master": 0, "replica1": 0, "replica2": 0, "absent": 0}
    if not raw:
        return counts

    records = raw.split(";")
    if len(records) < 2:
        return counts

    # Parse header to find field indices
    header_fields = records[0].split(":")
    try:
        state_idx = header_fields.index("state")
        replica_idx = header_fields.index("replica")
    except ValueError:
        return counts

    for rec in records[1:]:
        fields = rec.split(":")
        if len(fields) <= max(state_idx, replica_idx):
            continue
        state = fields[state_idx]
        replica = fields[replica_idx]

        if state == "S":
            if replica == "0":
                counts["master"] += 1
            elif replica == "1":
                counts["replica1"] += 1
            elif replica == "2":
                counts["replica2"] += 1
        else:
            counts["absent"] += 1

    return counts


def poll_node(node_def: dict) -> NodeStatus:
    """Poll a single node and return its status."""
    ns = NodeStatus(
        container=node_def["container"],
        ip=node_def["ip"],
        node_id=node_def["node_id"],
        rack_id=node_def["rack_id"],
        site=node_def["site"],
        dc=node_def.get("dc", ""),
    )

    # Docker state
    ns.docker_running, ns.docker_health = get_docker_state(ns.container)
    if not ns.docker_running:
        ns.error = "container stopped"
        return ns

    # Aerospike statistics
    stats_raw = run_cmd([
        "docker", "exec", ns.container,
        "asinfo", "-v", "statistics", "-h", ns.ip, "-p", "3000",
    ])
    if stats_raw is None:
        ns.error = "asinfo unreachable"
        return ns

    ns.reachable = True
    stats = parse_kv(stats_raw)
    ns.cluster_size = int(stats.get("cluster_size", 0))
    ns.cluster_key = stats.get("cluster_key", "")
    ns.uptime = int(stats.get("uptime", 0))
    ns.client_connections = int(stats.get("client_connections", 0))

    # Check if this node is the principal
    principal_raw = run_cmd([
        "docker", "exec", ns.container,
        "asinfo", "-v", "cluster-principal", "-h", ns.ip, "-p", "3000",
    ])
    if principal_raw:
        # principal_raw returns the node hex ID of the principal
        # We check if recluster works to determine principal, but simpler:
        # just compare to self node's hex ID from statistics
        self_node = stats.get("paxos_principal", "")
        node_name = stats.get("node", "")
        if self_node and node_name and self_node == node_name:
            ns.principal = True

    # Namespace stats
    ns_raw = run_cmd([
        "docker", "exec", ns.container,
        "asinfo", "-v", f"namespace/{NAMESPACE}", "-h", ns.ip, "-p", "3000",
    ])
    if ns_raw:
        ns_stats = parse_kv(ns_raw)
        ns.objects = int(ns_stats.get("objects", 0))
        ns.master_objects = int(ns_stats.get("master_objects", 0))
        ns.prole_objects = int(ns_stats.get("prole_objects", 0))
        ns.used_bytes_disk = int(ns_stats.get("data_used_bytes", ns_stats.get("device_used_bytes", ns_stats.get("used_bytes_disk", 0))))
        ns.avail_pct = int(ns_stats.get("data_avail_pct", ns_stats.get("device_available_pct", ns_stats.get("avail_pct", 0))))
        ns.stop_writes = ns_stats.get("stop_writes", "false") == "true"
        ns.unavailable_partitions = int(ns_stats.get("unavailable_partitions", 0))
        ns.dead_partitions = int(ns_stats.get("dead_partitions", 0))
        ns.migrate_tx_remaining = int(ns_stats.get("migrate_tx_partitions_remaining", 0))
        ns.migrate_rx_remaining = int(ns_stats.get("migrate_rx_partitions_remaining", 0))
        ns.strong_consistency = ns_stats.get("strong-consistency", "false") == "true"
        ns.effective_replication_factor = int(ns_stats.get("effective_replication_factor", 0))
        ns.active_rack = int(ns_stats.get("active-rack", 0))
        ns.quiesced = ns_stats.get("effective_is_quiesced", "false") == "true"

    # Partition details
    part_raw = run_cmd([
        "docker", "exec", ns.container,
        "asinfo", "-v", f"partition-info:namespace={NAMESPACE}", "-h", ns.ip, "-p", "3000",
    ], timeout=10)
    if part_raw:
        pcounts = parse_partition_info(part_raw)
        ns.partitions_master = pcounts["master"]
        ns.partitions_replica1 = pcounts["replica1"]
        ns.partitions_replica2 = pcounts["replica2"]
        ns.partitions_absent = pcounts["absent"]
        ns.partitions_total_owned = pcounts["master"] + pcounts["replica1"] + pcounts["replica2"]

    return ns


def poll_roster(container: str, ip: str) -> tuple[str, str]:
    """Get the roster and observed_nodes from a reachable node."""
    raw = run_cmd([
        "docker", "exec", container,
        "asinfo", "-v", f"roster:namespace={NAMESPACE}", "-h", ip, "-p", "3000",
    ])
    roster = ""
    observed = ""
    if raw:
        kv = parse_kv(raw, sep=":")
        roster = kv.get("roster", "null")
        observed = kv.get("observed_nodes", "null")
    return roster, observed


def poll_cluster() -> ClusterState:
    """Poll all nodes in parallel and return the cluster state."""
    start = time.time()
    state = ClusterState()

    # Poll all nodes concurrently
    with ThreadPoolExecutor(max_workers=7) as executor:
        futures = {executor.submit(poll_node, node_def): node_def for node_def in NODES}
        results = {}
        for future in as_completed(futures):
            node_def = futures[future]
            results[node_def["node_id"]] = future.result()

    # Preserve the NODES ordering
    for node_def in NODES:
        state.nodes.append(results[node_def["node_id"]])

    # Get roster from the first reachable node
    for ns in state.nodes:
        if ns.reachable:
            state.roster_nodes, state.observed_nodes = poll_roster(ns.container, ns.ip)
            ns.roster_set = state.roster_nodes not in ("null", "")
            if ns.effective_replication_factor > 0:
                state.replication_factor = ns.effective_replication_factor
            if ns.active_rack > 0:
                state.active_rack = ns.active_rack
            break

    # Mark roster_set on all reachable nodes
    for ns in state.nodes:
        if ns.reachable:
            ns.roster_set = state.roster_nodes not in ("null", "")

    elapsed = time.time() - start
    state.poll_time = time.time()
    state.poll_duration_ms = elapsed * 1000
    return state


# =============================================================================
# Rendering
# =============================================================================

def format_uptime(seconds: int) -> str:
    """Format seconds to a human-readable uptime string."""
    if seconds <= 0:
        return "-"
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    mins, secs = divmod(rem, 60)
    if days > 0:
        return f"{days}d {hours}h {mins}m"
    if hours > 0:
        return f"{hours}h {mins}m {secs}s"
    if mins > 0:
        return f"{mins}m {secs}s"
    return f"{secs}s"


def format_bytes(num_bytes: int) -> str:
    """Format bytes to human-readable."""
    if num_bytes <= 0:
        return "0 B"
    b = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(b) < 1024:
            return f"{b:.1f} {unit}" if unit != "B" else f"{int(b)} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def node_status_icon(ns: NodeStatus) -> Text:
    """Return a colored status indicator for a node."""
    if not ns.docker_running:
        return Text("  DOWN  ", style="bold white on red")
    if ns.docker_health == "starting":
        return Text(" START  ", style="bold black on yellow")
    if not ns.reachable:
        return Text(" UNREACH", style="bold white on red")
    if ns.quiesced:
        return Text("QUIESCED", style="bold white on steel_blue")
    if ns.stop_writes:
        return Text("STOPWRIT", style="bold white on dark_orange")
    if ns.unavailable_partitions > 0:
        return Text("UNAVAIL ", style="bold white on dark_orange")
    if ns.dead_partitions > 0:
        return Text(" DEAD P ", style="bold white on dark_orange")
    if ns.migrate_tx_remaining > 0 or ns.migrate_rx_remaining > 0:
        return Text("MIGRATNG", style="bold black on cyan")
    return Text("   OK   ", style="bold white on green")


def node_state_label(ns: NodeStatus) -> Text:
    """Return a colored state label describing the node's operational role."""
    if not ns.docker_running:
        return Text("DOWN", style="bold red")
    if not ns.reachable:
        return Text("UNREACHABLE", style="bold red")
    if ns.quiesced:
        mig = ns.migrate_tx_remaining + ns.migrate_rx_remaining
        if mig > 0:
            return Text("QUIESCED+MIG", style="bold steel_blue1")
        return Text("TIE-BREAKER", style="bold steel_blue1")
    if ns.stop_writes:
        return Text("STOP-WRITES", style="bold red")
    if ns.dead_partitions > 0:
        return Text("DEAD-PARTS", style="bold dark_orange")
    if ns.unavailable_partitions > 0:
        return Text("UNAVAILABLE", style="bold dark_orange")
    if ns.quiesced:
        mig = ns.migrate_tx_remaining + ns.migrate_rx_remaining
        if mig > 0:
            return Text("QUIESCED+MIG", style="bold steel_blue1")
        return Text("TIE-BREAKER", style="bold steel_blue1")
    if ns.migrate_tx_remaining > 0 or ns.migrate_rx_remaining > 0:
        return Text("MIGRATING", style="bold cyan")
    if ns.partitions_master > 0:
        return Text("ACTIVE", style="bold green")
    if ns.partitions_total_owned > 0:
        return Text("REPLICA", style="bold bright_cyan")
    return Text("IDLE", style="dim")


def render_node_card(ns: NodeStatus) -> Panel:
    """Render a compact node card (~28 wide x 8 tall)."""
    status = node_status_icon(ns)
    state = node_state_label(ns)

    lines = Text()
    lines.append_text(status)
    lines.append(" ")
    lines.append_text(state)
    lines.append("\n")

    if not ns.docker_running:
        lines.append("stopped\n", style="red")
        lines.append(f"{ns.ip}\n", style="dim")
        return Panel(
            lines,
            title=f"[bold]{ns.node_id}[/bold]",
            subtitle=f"R{ns.rack_id}",
            border_style="red",
            width=28,
        )

    if not ns.reachable:
        lines.append(f"{ns.docker_health}\n", style="yellow")
        lines.append(f"{ns.error}\n", style="red")
        return Panel(
            lines,
            title=f"[bold]{ns.node_id}[/bold]",
            subtitle=f"R{ns.rack_id}",
            border_style="yellow",
            width=28,
        )

    # Healthy node
    principal_tag = " [bold magenta]*P*[/bold magenta]" if ns.principal else ""
    title = f"[bold]{ns.node_id}[/bold]{principal_tag}"

    lines.append(f"Up {format_uptime(ns.uptime)}", style="dim")
    lines.append(f" C{ns.cluster_size}")
    lines.append(f" Cn:{ns.client_connections}\n", style="dim")
    lines.append(f"Obj {ns.objects:,}")
    lines.append(f" M:{ns.master_objects:,} P:{ns.prole_objects:,}\n", style="dim")
    lines.append(f"Disk {format_bytes(ns.used_bytes_disk)}")
    lines.append(f" {ns.avail_pct}%free", style="dim")

    # Partition + migration on one line
    has_part_line = False
    if ns.partitions_total_owned > 0:
        lines.append("\n")
        lines.append(f"Pt M:{ns.partitions_master} R:{ns.partitions_replica1 + ns.partitions_replica2}", style="bright_cyan")
        has_part_line = True
    mig = ns.migrate_tx_remaining + ns.migrate_rx_remaining
    if mig > 0:
        if not has_part_line:
            lines.append("\n")
            has_part_line = True
        lines.append(f" Mig:{mig}", style="cyan")
    if ns.unavailable_partitions > 0:
        if not has_part_line:
            lines.append("\n")
            has_part_line = True
        lines.append(f" UA:{ns.unavailable_partitions}", style="red")
    if ns.dead_partitions > 0:
        if not has_part_line:
            lines.append("\n")
            has_part_line = True
        lines.append(f" D:{ns.dead_partitions}", style="red")

    border = "green"
    if ns.stop_writes:
        border = "red"
    elif ns.unavailable_partitions > 0 or ns.dead_partitions > 0:
        border = "dark_orange"
    elif ns.quiesced:
        border = "steel_blue"

    return Panel(
        lines,
        title=title,
        subtitle=f"R{ns.rack_id} {ns.ip}",
        border_style=border,
        width=28,
    )


def render_site_panel(site_name: str, nodes: list[NodeStatus], style: str, active_rack: int = 0) -> Panel:
    """Render a site as a panel containing node cards arranged horizontally."""
    cards = [render_node_card(n) for n in nodes]
    content = Columns(cards, padding=(0, 0), expand=False)
    rack_id = nodes[0].rack_id if nodes else "?"
    active_tag = " [bright_green]*ACTIVE*[/bright_green]" if rack_id == active_rack else ""
    return Panel(
        content,
        title=f"[bold]{site_name}[/bold] (R{rack_id}){active_tag}",
        border_style=style,
        padding=(0, 0),
    )


def render_dc_panel(dc_name: str, site_panels: list[Panel], style: str) -> Panel:
    """Render a DC as a panel containing site panels arranged horizontally."""
    content = Columns(site_panels, padding=(0, 1), expand=False)
    return Panel(
        content,
        title=f"[bold]{dc_name}[/bold]",
        border_style=style,
        padding=(0, 0),
    )


def render_cluster_header(state: ClusterState) -> Panel:
    """Render the top header bar with cluster-level info."""
    # Aggregate stats
    total_nodes = len(state.nodes)
    running = sum(1 for n in state.nodes if n.docker_running)
    reachable = sum(1 for n in state.nodes if n.reachable)
    total_objects = sum(n.objects for n in state.nodes if n.reachable)
    total_master = sum(n.master_objects for n in state.nodes if n.reachable)
    any_stop_writes = any(n.stop_writes and not n.quiesced for n in state.nodes if n.reachable)
    cluster_keys = set(n.cluster_key for n in state.nodes if n.reachable and n.cluster_key)
    split_brain = len(cluster_keys) > 1

    # Cluster health determination
    if reachable == 0:
        health_text = Text(" CLUSTER DOWN ", style="bold white on red")
    elif split_brain:
        health_text = Text(" SPLIT BRAIN  ", style="bold white on red")
    elif any_stop_writes:
        health_text = Text(" STOP WRITES  ", style="bold white on dark_orange")
    elif reachable < total_nodes:
        health_text = Text("  DEGRADED    ", style="bold black on yellow")
    elif any(n.dead_partitions > 0 for n in state.nodes if n.reachable):
        health_text = Text(" DEAD PARTS   ", style="bold white on dark_orange")
    elif any(n.migrate_tx_remaining + n.migrate_rx_remaining > 0 for n in state.nodes):
        health_text = Text("  MIGRATING   ", style="bold black on cyan")
    else:
        health_text = Text("   HEALTHY    ", style="bold white on green")

    # Build header as lines of text (avoids column truncation)
    timestamp = datetime.now().strftime("%H:%M:%S")

    line1 = Text()
    line1.append("  Health: ")
    line1.append_text(health_text)
    line1.append(f"    Nodes: {reachable}/{total_nodes} reachable")
    if running != total_nodes:
        line1.append(f" ({running} running)", style="yellow")
    line1.append(f"    Objects: {total_objects:,} total, {total_master:,} masters")
    line1.append(f"    Poll: {state.poll_duration_ms:.0f}ms  {timestamp}", style="dim")

    sc_on = any(n.strong_consistency for n in state.nodes if n.reachable)
    line2 = Text()
    line2.append("  Roster: ", style="bold")
    roster_style = "green" if state.roster_nodes not in ("null", "") else "red"
    roster_display = state.roster_nodes if state.roster_nodes else "null"
    line2.append(roster_display, style=roster_style)
    line2.append("    SC: ", style="bold")
    if sc_on:
        line2.append("enabled", style="green bold")
    else:
        line2.append("disabled", style="red")
    line2.append("  Namespace: ", style="bold")
    line2.append(NAMESPACE, style="cyan")
    rf = state.replication_factor
    line2.append("  RF: ", style="bold")
    if rf > 0:
        line2.append(f"{rf}", style="cyan bold")
    else:
        line2.append("?", style="yellow")
    ar = state.active_rack
    if ar > 0:
        line2.append("  Active-Rack: ", style="bold")
        line2.append(f"R{ar}", style="bright_green bold")

    # Split brain warning
    header_group_items = [line1, line2]
    if split_brain:
        warn = Text(
            f"  WARNING: Split brain detected! {len(cluster_keys)} distinct cluster keys: "
            + ", ".join(cluster_keys),
            style="bold red",
        )
        header_group_items.append(warn)

    return Panel(
        Group(*header_group_items),
        title="[bold white] AEROSPIKE MULTI-SITE SC CLUSTER [/bold white]",
        subtitle="[dim]Ctrl+C to exit[/dim]",
        border_style="bright_blue",
    )


def render_topology_diagram(state: ClusterState) -> Panel:
    """Render a compact topology diagram showing DC/mesh connectivity."""
    nodes = state.nodes
    reachable_ids = {n.node_id for n in nodes if n.reachable}
    rf = state.replication_factor or "?"

    def nstyle(nid: str) -> str:
        return f"[green]{nid}[/green]" if nid in reachable_ids else f"[red]{nid}[/red]"

    # Find principal
    principal_id = None
    for n in nodes:
        if n.principal:
            principal_id = n.node_id
            break

    principal_str = f"  Principal:[bold magenta]{principal_id}[/bold magenta]" if principal_id else ""

    ar = state.active_rack
    active_rack_str = f"  active-rack:[bright_green]R{ar}(masters)[/bright_green]" if ar > 0 else ""

    lines = []
    lines.append(f"  DC1: Site1(R1)[{nstyle('A1')} {nstyle('A2')} {nstyle('A3')}] + Quorum(R3)[{nstyle('C1')}] <--> DC2: Site2(R2)[{nstyle('B1')} {nstyle('B2')} {nstyle('B3')}]")
    lines.append(f"  RF:{rf} rack-aware  Mesh:7-node  min-cluster:4{principal_str}{active_rack_str}")

    text = "\n".join(lines)
    return Panel(
        Text.from_markup(text),
        title="[bold]Topology[/bold]",
        border_style="dim",
    )


def render_node_table(state: ClusterState) -> Table:
    """Render a detailed table of all nodes."""
    t = Table(title="Node Details", border_style="dim", show_lines=True)
    t.add_column("Node", style="bold", min_width=6)
    t.add_column("Container", min_width=12)
    t.add_column("IP", min_width=13)
    t.add_column("Status", min_width=10, justify="center")
    t.add_column("Cluster", justify="center", min_width=8)
    t.add_column("Objects", justify="right", min_width=9)
    t.add_column("Masters", justify="right", min_width=9)
    t.add_column("Disk Used", justify="right", min_width=10)
    t.add_column("Avail%", justify="right", min_width=7)
    t.add_column("Mig", justify="right", min_width=5)
    t.add_column("Conns", justify="right", min_width=6)
    t.add_column("Uptime", justify="right", min_width=10)

    for n in state.nodes:
        status = node_status_icon(n)
        if not n.reachable:
            t.add_row(
                n.node_id, n.container, n.ip, status,
                "-", "-", "-", "-", "-", "-", "-", "-",
                style="dim",
            )
        else:
            mig = n.migrate_tx_remaining + n.migrate_rx_remaining
            mig_str = str(mig) if mig > 0 else "-"
            t.add_row(
                n.node_id,
                n.container,
                n.ip,
                status,
                str(n.cluster_size),
                f"{n.objects:,}",
                f"{n.master_objects:,}",
                format_bytes(n.used_bytes_disk),
                f"{n.avail_pct}%",
                mig_str,
                str(n.client_connections),
                format_uptime(n.uptime),
            )

    return t


def render_partition_table(state: ClusterState) -> Table:
    """Render a compact partition distribution table."""
    t = Table(title="Partition Distribution (4096)", border_style="dim", show_lines=False, pad_edge=False, padding=(0, 1))
    t.add_column("Node", style="bold", min_width=4)
    t.add_column("Rack", justify="center", min_width=3)
    t.add_column("Master", justify="right", min_width=6, style="green")
    t.add_column("Repl", justify="right", min_width=6, style="cyan")
    t.add_column("Total", justify="right", min_width=6, style="bold")
    t.add_column("Absent", justify="right", min_width=6, style="dim")
    t.add_column("M%", justify="right", min_width=5)

    total_masters = 0
    total_repl = 0
    total_owned = 0
    total_absent = 0

    for n in state.nodes:
        if not n.reachable:
            t.add_row(n.node_id, str(n.rack_id), "-", "-", "-", "-", "-", style="dim")
            continue

        repl = n.partitions_replica1 + n.partitions_replica2
        master_pct = (n.partitions_master / 4096 * 100) if n.partitions_master > 0 else 0.0
        t.add_row(
            n.node_id, str(n.rack_id),
            str(n.partitions_master), str(repl),
            str(n.partitions_total_owned), str(n.partitions_absent),
            f"{master_pct:.0f}%",
        )
        total_masters += n.partitions_master
        total_repl += repl
        total_owned += n.partitions_total_owned
        total_absent += n.partitions_absent

    t.add_row("TOT", "", str(total_masters), str(total_repl), str(total_owned), str(total_absent), "100%", style="bold")
    return t


def render_partition_balance(state: ClusterState) -> Panel:
    """Render a compact per-rack partition balance summary with visual bars."""
    reachable = [n for n in state.nodes if n.reachable]
    if not reachable:
        return Panel("[dim]No reachable nodes[/dim]", title="[bold]Partition Balance[/bold]", border_style="dim")

    # Group by rack
    racks: dict[int, list[NodeStatus]] = {}
    for n in reachable:
        racks.setdefault(n.rack_id, []).append(n)

    rack_labels = {1: "DC1/Site1", 2: "DC2/Site2", 3: "DC1/Quorum"}
    rack_colors = {1: "blue", 2: "magenta", 3: "yellow"}

    lines = Text()
    max_bar_width = 30
    rf = state.replication_factor or "?"

    for rack_id in sorted(racks.keys()):
        nodes = racks[rack_id]
        rack_master = sum(n.partitions_master for n in nodes)
        rack_replica = sum(n.partitions_replica1 + n.partitions_replica2 for n in nodes)
        rack_total = sum(n.partitions_total_owned for n in nodes)

        label = rack_labels.get(rack_id, f"R{rack_id}")
        color = rack_colors.get(rack_id, "white")

        if rack_total > 0:
            master_width = max(1, int(rack_master / rack_total * max_bar_width))
            replica_width = max_bar_width - master_width
        else:
            master_width = 0
            replica_width = 0

        lines.append(f" {label:<10} ", style=color)
        lines.append(f"M:{rack_master:>4} R:{rack_replica:>4} T:{rack_total:>4} ")
        lines.append("\u2588" * master_width, style="green")
        lines.append("\u2588" * replica_width, style="cyan")
        lines.append("\n")

    # Balance check
    ar = state.active_rack
    total_m = sum(n.partitions_master for n in reachable)
    total_r = sum(n.partitions_replica1 + n.partitions_replica2 for n in reachable)
    data_racks = {rid: nodes for rid, nodes in racks.items() if rid != 3}
    if ar > 0:
        # Active-rack mode: all masters should be on the active rack
        active_masters = sum(n.partitions_master for n in reachable if n.rack_id == ar)
        lines.append(f" Total M:{total_m} R:{total_r} RF={rf}  Active-Rack R{ar}: ", style="dim")
        if total_m > 0 and active_masters == total_m:
            lines.append("ALL MASTERS ON R" + str(ar), style="bold bright_green")
        elif total_m > 0:
            lines.append(f"PARTIAL {active_masters}/{total_m}", style="bold yellow")
        else:
            lines.append("NO DATA", style="dim")
    elif data_racks:
        rack_master_counts = {rid: sum(n.partitions_master for n in nodes) for rid, nodes in data_racks.items()}
        counts = list(rack_master_counts.values())
        avg = sum(counts) / len(counts)
        max_dev = max(abs(c - avg) / avg * 100 for c in counts) if avg > 0 else 0
        lines.append(f" Total M:{total_m} R:{total_r} RF={rf}  Balance:", style="dim")
        if max_dev < 10:
            lines.append("OK", style="bold green")
        elif max_dev < 25:
            lines.append("UNEVEN", style="bold yellow")
        else:
            lines.append("IMBALANCED", style="bold red")
        lines.append(f" ({max_dev:.0f}% dev)", style="dim")

    return Panel(
        lines,
        title="[bold]Partition Balance[/bold]",
        border_style="bright_blue",
    )


def build_dashboard(state: ClusterState) -> Group:
    """Assemble the full compact dashboard layout."""
    # Header
    header = render_cluster_header(state)

    # Group nodes by site
    site1 = [n for n in state.nodes if n.site == "Site 1"]
    site2 = [n for n in state.nodes if n.site == "Site 2"]
    quorum = [n for n in state.nodes if n.site == "Quorum"]

    # Site panels
    ar = state.active_rack
    site1_panel = render_site_panel("Site 1", site1, "blue", active_rack=ar)
    quorum_panel = render_site_panel("Quorum", quorum, "yellow", active_rack=ar)
    site2_panel = render_site_panel("Site 2", site2, "magenta", active_rack=ar)

    # DC panels: DC1 = Site 1 + Quorum, DC2 = Site 2
    dc1_panel = render_dc_panel("DC1", [site1_panel, quorum_panel], "bright_green")
    dc2_panel = render_dc_panel("DC2", [site2_panel], "bright_red")

    # DC row: both DCs (Columns will place side by side if terminal is wide enough)
    dc_row = Columns([dc1_panel, dc2_panel], padding=(0, 1), expand=False)

    # Topology diagram (compact)
    topo = render_topology_diagram(state)

    # Partition table + balance side by side
    part_table = render_partition_table(state)
    part_balance = render_partition_balance(state)
    partition_row = Columns([part_table, part_balance], padding=(0, 2), expand=False)

    return Group(
        header,
        dc_row,
        topo,
        partition_row,
    )


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Aerospike Multi-Site SC Cluster Visualizer",
    )
    parser.add_argument(
        "--interval", "-i", type=float, default=2.0,
        help="Refresh interval in seconds (default: 2.0)",
    )
    parser.add_argument(
        "--once", action="store_true",
        help="Print a single snapshot and exit",
    )
    args = parser.parse_args()

    console = Console()

    if args.once:
        state = poll_cluster()
        dashboard = build_dashboard(state)
        console.print(dashboard)
        return

    # Live loop
    console.clear()
    try:
        with Live(console=console, refresh_per_second=1, screen=True) as live:
            while True:
                state = poll_cluster()
                dashboard = build_dashboard(state)
                live.update(dashboard)
                time.sleep(args.interval)
    except KeyboardInterrupt:
        console.print("\n[dim]Visualizer stopped.[/dim]")


if __name__ == "__main__":
    main()
