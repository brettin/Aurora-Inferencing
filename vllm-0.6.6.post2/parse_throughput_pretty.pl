#!/usr/bin/env perl

# Print header
printf "%-20s %-25s %-15s %-15s %-20s %-20s\n", 
       "Prompt Throughput", 
       "Generation Throughput", 
       "Running Reqs", 
       "Waiting Reqs",
       "GPU KV Cache",
       "Prefix Cache Hit";
printf "%-20s %-25s %-15s %-15s %-20s %-20s\n", 
       "(tokens/s)", 
       "(tokens/s)", 
       "", 
       "",
       "(%)",
       "(%)";
print "-" x 120 . "\n";

# Process input
while(<>){
    if (/Avg prompt throughput: (\d+\.\d+) tokens\/s, Avg generation throughput: (\d+\.\d+) tokens\/s, Running: (\d+) reqs, Waiting: (\d+) reqs, GPU KV cache usage: (\d+\.\d+)\%, Prefix cache hit rate: (\d+\.\d+)\%/) {
        printf "%-20.2f %-25.2f %-15d %-15d %-20.2f %-20.2f\n", 
               $1, $2, $3, $4, $5, $6;
    }
}
