#!/usr/bin/env python3
"""
Health Monitor for Traefik + vLLM Deployment

Polls Traefik API for backend health status and generates a summary.
Usage: python3 health_monitor.py <output_file> [poll_interval_seconds]

Runs until interrupted (SIGTERM/SIGINT), then writes summary.
"""

import sys
import time
import json
import signal
from datetime import datetime
from collections import defaultdict
from urllib.request import urlopen, Request
from urllib.error import URLError

TRAEFIK_API_URL = "http://localhost:8080/api/http/services"
DEFAULT_POLL_INTERVAL = 10  # seconds


class HealthMonitor:
    def __init__(self, output_file: str, poll_interval: int = DEFAULT_POLL_INTERVAL):
        self.output_file = output_file
        self.poll_interval = poll_interval
        self.running = True
        
        # Track state: backend_url -> list of (timestamp, status)
        self.history = defaultdict(list)
        # Current known state
        self.current_status = {}
        # Failure counts
        self.failure_events = defaultdict(int)  # backend -> count of DOWN transitions
        self.recovery_events = defaultdict(int)  # backend -> count of UP transitions after DOWN
        
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)
    
    def _handle_shutdown(self, signum, frame):
        print(f"\n[HealthMonitor] Received signal {signum}, writing summary...")
        self.running = False
    
    def fetch_status(self) -> dict:
        """Fetch current backend status from Traefik API."""
        try:
            req = Request(TRAEFIK_API_URL)
            with urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode())
                
            # Parse response: find our vllm-backends service
            for service in data:
                if "vllm-backends" in service.get("name", ""):
                    server_status = service.get("serverStatus", {})
                    # Returns dict like {"http://host:port": "UP"/"DOWN"}
                    return server_status
            return {}
        except (URLError, json.JSONDecodeError, KeyError) as e:
            print(f"[HealthMonitor] API error: {e}")
            return {}
    
    def poll(self):
        """Single poll iteration."""
        now = datetime.now().isoformat()
        status = self.fetch_status()
        
        if not status:
            return
        
        for backend, state in status.items():
            prev_state = self.current_status.get(backend, "UNKNOWN")
            
            # Record state change
            if prev_state != state:
                self.history[backend].append((now, state))
                
                if state == "DOWN" and prev_state in ("UP", "UNKNOWN"):
                    self.failure_events[backend] += 1
                    print(f"[HealthMonitor] {now} | DOWN: {backend}")
                elif state == "UP" and prev_state == "DOWN":
                    self.recovery_events[backend] += 1
                    print(f"[HealthMonitor] {now} | RECOVERED: {backend}")
                elif prev_state == "UNKNOWN":
                    print(f"[HealthMonitor] {now} | INITIAL: {backend} = {state}")
            
            self.current_status[backend] = state
    
    def run(self):
        """Main polling loop."""
        print(f"[HealthMonitor] Starting (poll interval: {self.poll_interval}s)")
        print(f"[HealthMonitor] Output will be written to: {self.output_file}")
        
        while self.running:
            self.poll()
            time.sleep(self.poll_interval)
        
        self.write_summary()
    
    def write_summary(self):
        """Write final summary to file."""
        all_backends = set(self.current_status.keys())
        total = len(all_backends)
        
        # Categorize backends
        always_healthy = []
        failed_recovered = []
        failed_stayed_down = []
        never_seen_up = []
        
        for backend in sorted(all_backends):
            failures = self.failure_events[backend]
            recoveries = self.recovery_events[backend]
            final_state = self.current_status.get(backend, "UNKNOWN")
            
            if failures == 0:
                always_healthy.append(backend)
            elif final_state == "UP":
                failed_recovered.append((backend, failures, recoveries))
            else:
                failed_stayed_down.append((backend, failures))
        
        # Write summary
        with open(self.output_file, 'w') as f:
            f.write("=" * 60 + "\n")
            f.write("BACKEND HEALTH SUMMARY\n")
            f.write("=" * 60 + "\n\n")
            
            f.write(f"Total Backends Tracked: {total}\n")
            f.write(f"Always Healthy:         {len(always_healthy)}\n")
            f.write(f"Failed (recovered):     {len(failed_recovered)}\n")
            f.write(f"Failed (stayed down):   {len(failed_stayed_down)}\n\n")
            
            if failed_recovered:
                f.write("--- Failed but Recovered ---\n")
                for backend, failures, recoveries in failed_recovered:
                    f.write(f"  {backend}: {failures} failures, {recoveries} recoveries\n")
                f.write("\n")
            
            if failed_stayed_down:
                f.write("--- Failed and Stayed Down ---\n")
                for backend, failures in failed_stayed_down:
                    f.write(f"  {backend}: {failures} failures\n")
                f.write("\n")
            
            f.write("=" * 60 + "\n")
            
            # Also write detailed history
            f.write("\nDETAILED EVENT LOG:\n")
            f.write("-" * 60 + "\n")
            
            all_events = []
            for backend, events in self.history.items():
                for ts, state in events:
                    all_events.append((ts, backend, state))
            
            for ts, backend, state in sorted(all_events):
                f.write(f"{ts} | {state:8} | {backend}\n")
        
        print(f"[HealthMonitor] Summary written to {self.output_file}")
        
        # Also print to stdout
        with open(self.output_file, 'r') as f:
            print(f.read())


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output_file> [poll_interval_seconds]")
        sys.exit(1)
    
    output_file = sys.argv[1]
    poll_interval = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_POLL_INTERVAL
    
    monitor = HealthMonitor(output_file, poll_interval)
    monitor.run()


if __name__ == "__main__":
    main()
