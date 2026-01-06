#!/usr/bin/env python3
"""
Analyze vLLM logs across all nodes to extract engine metrics.

Usage: python3 analyze_backend_requests.py <log_dir>

Parses engine metric lines like:
Engine 000: Avg prompt throughput: X tokens/s, Avg generation throughput: Y tokens/s, Running: N reqs, Waiting: M reqs
"""

import os
import sys
import re
from collections import defaultdict
from pathlib import Path


def analyze_vllm_log(log_path: str) -> dict:
    """Analyze a single vLLM log file for engine metrics."""
    stats = {
        'max_running': 0,
        'max_waiting': 0,
        'max_combined': 0,
        'avg_gen_throughput': 0,
        'peak_gen_throughput': 0,
        'metric_samples': 0,
        'total_running_sum': 0,
        'total_waiting_sum': 0,
    }
    
    try:
        with open(log_path, 'r', errors='ignore') as f:
            content = f.read()
        
        # Pattern: Engine 000: Avg prompt throughput: X tokens/s, Avg generation throughput: Y tokens/s, Running: N reqs, Waiting: M reqs
        pattern = r'Running:\s*(\d+)\s*reqs,\s*Waiting:\s*(\d+)\s*reqs'
        gen_pattern = r'Avg generation throughput:\s*([\d.]+)\s*tokens/s'
        
        running_matches = re.findall(pattern, content)
        gen_matches = re.findall(gen_pattern, content)
        
        if running_matches:
            stats['metric_samples'] = len(running_matches)
            for running, waiting in running_matches:
                running = int(running)
                waiting = int(waiting)
                stats['max_running'] = max(stats['max_running'], running)
                stats['max_waiting'] = max(stats['max_waiting'], waiting)
                stats['max_combined'] = max(stats['max_combined'], running + waiting)
                stats['total_running_sum'] += running
                stats['total_waiting_sum'] += waiting
            
            stats['avg_running'] = stats['total_running_sum'] / len(running_matches)
            stats['avg_waiting'] = stats['total_waiting_sum'] / len(running_matches)
        
        if gen_matches:
            gen_values = [float(g) for g in gen_matches]
            stats['peak_gen_throughput'] = max(gen_values)
            stats['avg_gen_throughput'] = sum(gen_values) / len(gen_values)
        
    except Exception as e:
        stats['read_error'] = str(e)
    
    return stats


def analyze_log_directory(log_dir: str):
    """Analyze all vLLM logs in a directory."""
    log_path = Path(log_dir)
    
    if not log_path.exists():
        print(f"Error: Directory {log_dir} does not exist")
        return
    
    # Find all node directories
    node_dirs = sorted([d for d in log_path.iterdir() if d.is_dir() and 'hsn' in d.name])
    
    print(f"{'='*100}")
    print(f"BACKEND ENGINE METRICS ANALYSIS")
    print(f"{'='*100}")
    print(f"Log directory: {log_dir}")
    print(f"Nodes found: {len(node_dirs)}")
    print()
    
    all_stats = {}
    node_totals = {}
    
    for node_dir in node_dirs:
        node_name = node_dir.name.split('.')[0]  # Get short hostname
        
        # Find vLLM logs
        vllm_logs = sorted(node_dir.glob('vllm_*.log'))
        
        node_stats = {}
        node_max_waiting = 0
        node_max_combined = 0
        
        for log_file in vllm_logs:
            backend_num = log_file.stem.split('_')[1]
            port = 8000 + int(backend_num)
            stats = analyze_vllm_log(str(log_file))
            node_stats[port] = stats
            all_stats[f"{node_name}:{port}"] = stats
            node_max_waiting = max(node_max_waiting, stats.get('max_waiting', 0))
            node_max_combined = max(node_max_combined, stats.get('max_combined', 0))
        
        node_totals[node_name] = {'max_waiting': node_max_waiting, 'max_combined': node_max_combined}
        
        if node_stats:
            print(f"\n{node_name}: (max queue: {node_max_waiting}, max combined: {node_max_combined})")
            for port in sorted(node_stats.keys()):
                s = node_stats[port]
                max_run = s.get('max_running', 0)
                max_wait = s.get('max_waiting', 0)
                max_comb = s.get('max_combined', 0)
                peak_gen = s.get('peak_gen_throughput', 0)
                avg_gen = s.get('avg_gen_throughput', 0)
                print(f"  :{port} - max_running: {max_run:3d}, max_waiting: {max_wait:3d}, "
                      f"max_total: {max_comb:3d}, peak_gen: {peak_gen:.1f} tok/s")
    
    # Summary statistics
    print()
    print(f"{'='*100}")
    print("SUMMARY: QUEUE DEPTH ANALYSIS")
    print(f"{'='*100}")
    
    max_waiting_values = [s.get('max_waiting', 0) for s in all_stats.values()]
    max_combined_values = [s.get('max_combined', 0) for s in all_stats.values()]
    peak_gens = [s.get('peak_gen_throughput', 0) for s in all_stats.values()]
    
    if max_waiting_values:
        print(f"Total backends: {len(all_stats)}")
        print(f"Max waiting queue (any backend): {max(max_waiting_values)}")
        print(f"Avg max waiting queue: {sum(max_waiting_values)/len(max_waiting_values):.1f}")
        print(f"Max combined (running+waiting): {max(max_combined_values)}")
        print(f"Peak generation throughput: {max(peak_gens):.1f} tok/s")
        
        # Identify backends that had very high queue depths
        high_queue = [(k, v.get('max_waiting', 0), v.get('max_combined', 0)) 
                      for k, v in all_stats.items() if v.get('max_waiting', 0) > 50]
        
        if high_queue:
            print()
            print("BACKENDS WITH HIGH QUEUE DEPTH (waiting > 50):")
            for backend, waiting, combined in sorted(high_queue, key=lambda x: x[1], reverse=True):
                print(f"  {backend}: max_waiting={waiting}, max_combined={combined}")
        
        # Identify backends that had very low queue depths (might not be receiving requests)
        low_queue = [(k, v.get('max_waiting', 0), v.get('max_combined', 0), v.get('metric_samples', 0)) 
                     for k, v in all_stats.items() if v.get('max_combined', 0) < 5 and v.get('metric_samples', 0) > 0]
        
        if low_queue:
            print()
            print("BACKENDS WITH LOW QUEUE DEPTH (max_combined < 5):")
            for backend, waiting, combined, samples in sorted(low_queue, key=lambda x: x[2]):
                print(f"  {backend}: max_combined={combined}")
    
    # Node-level comparison
    print()
    print(f"{'='*100}")
    print("NODE-LEVEL COMPARISON (max queue per node):")
    print(f"{'='*100}")
    for node, totals in sorted(node_totals.items(), key=lambda x: x[1]['max_waiting'], reverse=True):
        print(f"  {node}: max_waiting={totals['max_waiting']}, max_combined={totals['max_combined']}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <log_directory>")
        print(f"Example: {sys.argv[0]} ./logs/8236484_16nodes")
        sys.exit(1)
    
    log_dir = sys.argv[1]
    analyze_log_directory(log_dir)


if __name__ == "__main__":
    main()
