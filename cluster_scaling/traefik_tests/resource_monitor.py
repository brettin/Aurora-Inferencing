#!/usr/bin/env python3
"""
Resource Monitor for Traefik + vLLM Head Node

Monitors and logs:
- CPU usage (per-core and aggregate)
- Memory usage
- Network I/O (bytes/packets)
- Process-specific stats (Traefik, vLLM)

Usage: python3 resource_monitor.py <output_file> [poll_interval_seconds]
"""

import os
import sys
import time
import signal
import subprocess
from datetime import datetime
from collections import defaultdict

DEFAULT_POLL_INTERVAL = 5  # seconds


class ResourceMonitor:
    def __init__(self, output_file: str, poll_interval: int = DEFAULT_POLL_INTERVAL):
        self.output_file = output_file
        self.poll_interval = poll_interval
        self.running = True
        self.samples = []
        
        # Track network baseline
        self.net_baseline = None
        self.last_net = None
        self.last_net_time = None
        
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)
    
    def _handle_shutdown(self, signum, frame):
        print(f"\n[ResourceMonitor] Received signal {signum}, writing summary...")
        self.running = False
    
    def get_cpu_usage(self) -> dict:
        """Get CPU usage from /proc/stat."""
        try:
            with open('/proc/stat', 'r') as f:
                lines = f.readlines()
            
            cpu_line = lines[0].split()
            # user, nice, system, idle, iowait, irq, softirq
            total = sum(int(x) for x in cpu_line[1:8])
            idle = int(cpu_line[4])
            
            return {'total': total, 'idle': idle}
        except:
            return {'total': 0, 'idle': 0}
    
    def get_memory_usage(self) -> dict:
        """Get memory usage from /proc/meminfo."""
        try:
            with open('/proc/meminfo', 'r') as f:
                lines = f.readlines()
            
            mem = {}
            for line in lines:
                parts = line.split()
                key = parts[0].rstrip(':')
                val = int(parts[1])  # kB
                mem[key] = val
            
            total_gb = mem.get('MemTotal', 0) / (1024 * 1024)
            avail_gb = mem.get('MemAvailable', 0) / (1024 * 1024)
            used_gb = total_gb - avail_gb
            used_pct = (used_gb / total_gb * 100) if total_gb > 0 else 0
            
            return {
                'total_gb': round(total_gb, 2),
                'used_gb': round(used_gb, 2),
                'avail_gb': round(avail_gb, 2),
                'used_pct': round(used_pct, 1)
            }
        except:
            return {'total_gb': 0, 'used_gb': 0, 'avail_gb': 0, 'used_pct': 0}
    
    def get_network_stats(self) -> dict:
        """Get network I/O from /proc/net/dev."""
        try:
            with open('/proc/net/dev', 'r') as f:
                lines = f.readlines()[2:]  # Skip headers
            
            rx_bytes = tx_bytes = 0
            for line in lines:
                parts = line.split()
                iface = parts[0].rstrip(':')
                if iface != 'lo':  # Skip loopback
                    rx_bytes += int(parts[1])
                    tx_bytes += int(parts[9])
            
            return {'rx_bytes': rx_bytes, 'tx_bytes': tx_bytes, 'time': time.time()}
        except:
            return {'rx_bytes': 0, 'tx_bytes': 0, 'time': time.time()}
    
    def get_process_stats(self, patterns: list) -> dict:
        """Get stats for processes matching patterns."""
        results = {}
        try:
            for pattern in patterns:
                cmd = f"pgrep -f '{pattern}' | head -5 | xargs -I{{}} ps -p {{}} -o pid,pcpu,pmem,rss --no-headers 2>/dev/null"
                output = subprocess.check_output(cmd, shell=True, text=True).strip()
                
                if output:
                    lines = output.strip().split('\n')
                    total_cpu = 0
                    total_mem_mb = 0
                    count = len(lines)
                    
                    for line in lines:
                        parts = line.split()
                        if len(parts) >= 4:
                            total_cpu += float(parts[1])
                            total_mem_mb += int(parts[3]) / 1024  # RSS in KB -> MB
                    
                    results[pattern] = {
                        'count': count,
                        'cpu_pct': round(total_cpu, 1),
                        'mem_mb': round(total_mem_mb, 1)
                    }
                else:
                    results[pattern] = {'count': 0, 'cpu_pct': 0, 'mem_mb': 0}
        except:
            pass
        return results
    
    def poll(self) -> dict:
        """Collect all metrics."""
        now = datetime.now().isoformat()
        
        # CPU (calculate delta from last sample)
        cpu = self.get_cpu_usage()
        mem = self.get_memory_usage()
        net = self.get_network_stats()
        procs = self.get_process_stats(['traefik', 'vllm'])
        
        # Calculate network throughput
        net_rx_mbps = 0
        net_tx_mbps = 0
        if self.last_net and self.last_net_time:
            elapsed = net['time'] - self.last_net_time
            if elapsed > 0:
                net_rx_mbps = (net['rx_bytes'] - self.last_net['rx_bytes']) / elapsed / (1024 * 1024)
                net_tx_mbps = (net['tx_bytes'] - self.last_net['tx_bytes']) / elapsed / (1024 * 1024)
        
        self.last_net = net
        self.last_net_time = net['time']
        
        sample = {
            'timestamp': now,
            'memory': mem,
            'network': {
                'rx_mbps': round(net_rx_mbps, 2),
                'tx_mbps': round(net_tx_mbps, 2),
            },
            'processes': procs
        }
        
        self.samples.append(sample)
        return sample
    
    def run(self):
        """Main monitoring loop."""
        print(f"[ResourceMonitor] Starting (poll interval: {self.poll_interval}s)")
        print(f"[ResourceMonitor] Output: {self.output_file}")
        
        while self.running:
            sample = self.poll()
            
            # Print condensed status every poll
            mem = sample['memory']
            net = sample['network']
            procs = sample['processes']
            
            traefik_cpu = procs.get('traefik', {}).get('cpu_pct', 0)
            vllm_cpu = procs.get('vllm', {}).get('cpu_pct', 0)
            vllm_count = procs.get('vllm', {}).get('count', 0)
            
            print(f"[Monitor] Mem: {mem['used_pct']:.0f}% | "
                  f"Net: ↓{net['rx_mbps']:.1f} ↑{net['tx_mbps']:.1f} MB/s | "
                  f"Traefik CPU: {traefik_cpu:.0f}% | "
                  f"vLLM({vllm_count}): {vllm_cpu:.0f}%")
            
            time.sleep(self.poll_interval)
        
        self.write_summary()
    
    def write_summary(self):
        """Write summary to file."""
        if not self.samples:
            return
        
        with open(self.output_file, 'w') as f:
            f.write("=" * 70 + "\n")
            f.write("RESOURCE MONITORING SUMMARY\n")
            f.write("=" * 70 + "\n\n")
            
            # Calculate peaks and averages
            max_mem = max(s['memory']['used_pct'] for s in self.samples)
            avg_mem = sum(s['memory']['used_pct'] for s in self.samples) / len(self.samples)
            
            max_rx = max(s['network']['rx_mbps'] for s in self.samples)
            max_tx = max(s['network']['tx_mbps'] for s in self.samples)
            avg_rx = sum(s['network']['rx_mbps'] for s in self.samples) / len(self.samples)
            avg_tx = sum(s['network']['tx_mbps'] for s in self.samples) / len(self.samples)
            
            traefik_cpus = [s['processes'].get('traefik', {}).get('cpu_pct', 0) for s in self.samples]
            max_traefik = max(traefik_cpus) if traefik_cpus else 0
            avg_traefik = sum(traefik_cpus) / len(traefik_cpus) if traefik_cpus else 0
            
            vllm_cpus = [s['processes'].get('vllm', {}).get('cpu_pct', 0) for s in self.samples]
            max_vllm = max(vllm_cpus) if vllm_cpus else 0
            avg_vllm = sum(vllm_cpus) / len(vllm_cpus) if vllm_cpus else 0
            
            f.write("PEAK VALUES:\n")
            f.write("-" * 70 + "\n")
            f.write(f"  Memory Usage:     {max_mem:.1f}%\n")
            f.write(f"  Network RX:       {max_rx:.2f} MB/s\n")
            f.write(f"  Network TX:       {max_tx:.2f} MB/s\n")
            f.write(f"  Traefik CPU:      {max_traefik:.1f}%\n")
            f.write(f"  vLLM CPU (total): {max_vllm:.1f}%\n\n")
            
            f.write("AVERAGE VALUES:\n")
            f.write("-" * 70 + "\n")
            f.write(f"  Memory Usage:     {avg_mem:.1f}%\n")
            f.write(f"  Network RX:       {avg_rx:.2f} MB/s\n")
            f.write(f"  Network TX:       {avg_tx:.2f} MB/s\n")
            f.write(f"  Traefik CPU:      {avg_traefik:.1f}%\n")
            f.write(f"  vLLM CPU (total): {avg_vllm:.1f}%\n\n")
            
            # Saturation warnings
            f.write("SATURATION ANALYSIS:\n")
            f.write("-" * 70 + "\n")
            warnings = []
            if max_mem > 90:
                warnings.append(f"  ⚠️  Memory peaked at {max_mem:.1f}% - may limit scaling")
            if max_tx > 1000:  # 1 GB/s
                warnings.append(f"  ⚠️  Network TX peaked at {max_tx:.1f} MB/s - approaching NIC limits")
            if max_traefik > 300:  # 3 cores
                warnings.append(f"  ⚠️  Traefik CPU peaked at {max_traefik:.1f}% - consider dedicated node")
            
            if warnings:
                f.write("\n".join(warnings) + "\n")
            else:
                f.write("  ✅ No saturation detected at current scale\n")
            
            f.write("\n" + "=" * 70 + "\n")
            
            # Raw samples
            f.write("\nDETAILED SAMPLES:\n")
            f.write("-" * 70 + "\n")
            f.write(f"{'Timestamp':<26} {'Mem%':>6} {'RX MB/s':>9} {'TX MB/s':>9} {'Traefik':>9} {'vLLM':>9}\n")
            f.write("-" * 70 + "\n")
            
            for s in self.samples:
                ts = s['timestamp'].split('T')[1][:12]
                mem = s['memory']['used_pct']
                rx = s['network']['rx_mbps']
                tx = s['network']['tx_mbps']
                traf = s['processes'].get('traefik', {}).get('cpu_pct', 0)
                vllm = s['processes'].get('vllm', {}).get('cpu_pct', 0)
                f.write(f"{ts:<26} {mem:>6.1f} {rx:>9.2f} {tx:>9.2f} {traf:>9.1f} {vllm:>9.1f}\n")
        
        print(f"[ResourceMonitor] Summary written to {self.output_file}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output_file> [poll_interval_seconds]")
        sys.exit(1)
    
    output_file = sys.argv[1]
    poll_interval = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_POLL_INTERVAL
    
    monitor = ResourceMonitor(output_file, poll_interval)
    monitor.run()


if __name__ == "__main__":
    main()
