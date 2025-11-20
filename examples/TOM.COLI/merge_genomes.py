#!/usr/bin/env python3
"""
Merge genome input files into a single file with genome identifiers.

This script reads all input files in a directory (or specified files),
prepends the genome identifier (filename without extension) as the first
column, and creates a single merged output file.

Usage:
    python merge_genomes.py input_dir output_file
    python merge_genomes.py --files file1.txt file2.txt --output merged.txt
"""

import argparse
import os
import sys
from pathlib import Path

def merge_genome_files(input_files, output_file):
    """
    Merge multiple genome files into one with genome IDs as first column.
    
    Args:
        input_files: List of input file paths
        output_file: Path to output merged file
    """
    total_lines = 0
    genome_counts = {}
    
    print(f"Merging {len(input_files)} files into {output_file}")
    
    with open(output_file, 'w', encoding='utf-8') as outf:
        for input_file in sorted(input_files):
            # Extract genome ID from filename (without extension)
            genome_id = Path(input_file).stem
            line_count = 0
            
            try:
                with open(input_file, 'r', encoding='utf-8') as inf:
                    for line in inf:
                        line = line.strip()
                        if line:  # Skip empty lines
                            # Write genome_id as first column, then original line
                            outf.write(f"{genome_id}\t{line}\n")
                            line_count += 1
                            total_lines += 1
                
                genome_counts[genome_id] = line_count
                print(f"  {genome_id}: {line_count} genes")
                
            except Exception as e:
                print(f"Error processing {input_file}: {e}", file=sys.stderr)
                continue
    
    print(f"\nTotal genes merged: {total_lines}")
    print(f"Total genomes: {len(genome_counts)}")
    print(f"Output written to: {output_file}")
    
    # Write a summary file
    summary_file = output_file + ".summary"
    with open(summary_file, 'w') as sf:
        sf.write(f"Total lines: {total_lines}\n")
        sf.write(f"Total genomes: {len(genome_counts)}\n\n")
        sf.write("Genome ID\tGene Count\n")
        for genome_id, count in sorted(genome_counts.items()):
            sf.write(f"{genome_id}\t{count}\n")
    
    print(f"Summary written to: {summary_file}")

def main():
    parser = argparse.ArgumentParser(
        description="Merge genome input files with genome identifiers as first column"
    )
    
    # Two modes: directory or explicit file list
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('input_dir', nargs='?', 
                      help='Directory containing input files (*.txt)')
    group.add_argument('--files', nargs='+', 
                      help='List of specific input files to merge')
    
    parser.add_argument('output_file', nargs='?', default='merged_genomes.txt',
                       help='Output file path (default: merged_genomes.txt)')
    parser.add_argument('--output', dest='output_alt',
                       help='Alternative way to specify output file')
    parser.add_argument('--pattern', default='*.txt',
                       help='File pattern to match in directory (default: *.txt)')
    
    args = parser.parse_args()
    
    # Determine output file
    output_file = args.output_alt or args.output_file or 'merged_genomes.txt'
    
    # Collect input files
    if args.files:
        input_files = args.files
    else:
        # Scan directory for files matching pattern
        input_dir = Path(args.input_dir)
        if not input_dir.exists():
            print(f"Error: Directory {input_dir} does not exist", file=sys.stderr)
            return 1
        
        if not input_dir.is_dir():
            print(f"Error: {input_dir} is not a directory", file=sys.stderr)
            return 1
        
        input_files = list(input_dir.glob(args.pattern))
        input_files = [str(f) for f in input_files if f.is_file()]
        
        if not input_files:
            print(f"Error: No files matching {args.pattern} found in {input_dir}", 
                  file=sys.stderr)
            return 1
    
    merge_genome_files(input_files, output_file)
    return 0

if __name__ == '__main__':
    sys.exit(main())

