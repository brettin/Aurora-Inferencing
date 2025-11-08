
while(<>){
	print "$1\t$2\n" if /Avg prompt throughput: (\d+\.\d+) tokens\/s, Avg generation throughput: (\d+\.\d+) tokens\/s, Running: (\d+) reqs, Waiting: (\d+) reqs, GPU KV cache usage: (\d+\.\d+)\%, Prefix cache hit rate: (\d+\.\d+)\%/;
}
