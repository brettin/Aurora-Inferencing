import sys, os
import argparse
import time
from openai import OpenAI
import concurrent.futures
from datetime import datetime
import threading
import psutil
import os

def print_with_timestamp(message):
    """Helper function to print messages with timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] TEST.COLI {message}")

def get_thread_info():
    """Get information about current threads."""
    current_thread = threading.current_thread()
    active_threads = threading.active_count()
    thread_names = [t.name for t in threading.enumerate()]
    return {
        'current_thread': current_thread.name,
        'active_count': active_threads,
        'thread_names': thread_names
    }

def print_thread_info():
    """Print current thread information."""
    info = get_thread_info()
    print_with_timestamp(f"Active threads: {info['active_count']}")
    print_with_timestamp(f"Thread names: {info['thread_names']}")

print_thread_info()

parser = argparse.ArgumentParser(description='''

This script processes gene IDs from a specified file and queries a vLLM server running a large language model.

INPUT FORMAT:
The input file should have genome_id as the first column (tab-separated), followed by gene information:
    genome_id\tgene_data

For example:
    1\tb1325\tECK1321\tycjG\tL-Ala-D/L-Glu epimerase
    1\tb0787\tECK0776\tybhM\tBax1-I family protein
    2\tb2543\tECK2540\typhA\tputative inner membrane protein

OUTPUT FORMAT:
Each result line will include the genome_id to allow parsing results by genome.

Operations:
1. Reads genome_id and gene IDs from a specified input file
2. Constructs prompts for each gene ID
3. Processes prompts in configurable batch sizes
4. Sends batches to the vLLM server via API calls
5. Handles responses and saves results with genome_id

''')

parser.add_argument('file', help='File containing genome_id and gene IDs (tab-separated)')
parser.add_argument('host', help='Hostname of the vLLM server')
parser.add_argument('--batch-size', type=int, default=64, help='Number of prompts to send in a batch (default: 64)')
parser.add_argument('--timeout', type=int, default=60, help='Timeout in seconds for API calls (default: 60)')
parser.add_argument('--model', default='meta-llama/Llama-3.1-70B-Instruct', help='Model name to use (default: meta-llama/Llama-3.1-70B-Instruct)')
parser.add_argument('--port', default='8000', help='Port number for the vLLM server (default: 8000)')
parser.add_argument('--key', default='EMPTY', help='API key for authentication (default: EMPTY)')
parser.add_argument('--output', help='Output file for results (default: stdout)')
parser.add_argument('--output-format', choices=['text', 'tsv', 'json'], default='text', 
                   help='Output format: text (default), tsv, or json')

args = parser.parse_args()

file_path = args.file
host = args.host
batch_size = args.batch_size
timeout = args.timeout
model = args.model
port = args.port
key = args.key
output_file = args.output
output_format = args.output_format

openai_api_base = f"http://{host}:{port}/v1"

client = OpenAI(
    api_key=key,
    base_url=openai_api_base,
)

# Open output file if specified
output_handle = None
if output_file:
    output_handle = open(output_file, 'w', encoding='utf-8')
    print_with_timestamp(f"Writing output to {output_file}")

def write_output(message):
    """Write to output file or stdout."""
    if output_handle:
        output_handle.write(message + "\n")
        output_handle.flush()
    else:
        print(message)

def call_model(prompts):
    """Call the model with a list of prompts without timeout."""
    def process_single_prompt(prompt):
        try:
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.0,
                max_tokens=1024,
                stream=False
            )
            return response
        except Exception as e:
            print_with_timestamp(f"Error calling model for prompt: {e}")
            # Try one more time before giving up
            try:
                print_with_timestamp(f"Retrying prompt...")
                response = client.chat.completions.create(
                    model=model,
                    messages=[{"role": "user", "content": prompt}],
                    temperature=0.0,
                    max_tokens=1024,
                    stream=False
                )
                return response
            except Exception as e2:
                print_with_timestamp(f"Error on retry attempt: {e2}")
                return None

    print_with_timestamp(f"Sending {len(prompts)} prompts to the model {model}...")
    with concurrent.futures.ThreadPoolExecutor() as executor:
        # Submit all prompts to be processed in parallel
        future_to_prompt = {executor.submit(process_single_prompt, prompt): prompt for prompt in prompts}
        info = get_thread_info()
        print(f"Active threads after call to executor: {info['active_count']} threads")
        responses = []
        for future in concurrent.futures.as_completed(future_to_prompt):
            response = future.result()
            responses.append(response)
    
    print_with_timestamp(f'Received {len(responses)} responses')
    return responses

def call_model_with_timeout(prompts, timeout_seconds):
    # Implementation of call_model_with_timeout function
    pass

# Collect all prompts from files
all_prompts = []
all_gene_ids = []
all_genome_ids = []

# Read gene IDs with genome identifiers
print_with_timestamp(f"Reading input file: {file_path}")
line_count = 0
with open(file_path, "r", encoding="utf-8") as file:
    for line in file:
        line = line.strip()
        if not line:
            continue
        
        line_count += 1
        # Split line into genome_id and gene data
        parts = line.split('\t', 1)
        if len(parts) < 2:
            print_with_timestamp(f"Warning: Line {line_count} does not have genome_id separator, skipping: {line[:50]}...")
            continue
        
        genome_id = parts[0]
        gene_data = parts[1]
        
        # Construct prompt
        prompt = (
            "Please tell me (using the knowledge you have been trained on) what you know about this bacterial gene whose various IDs are given here, though they all refer to the same gene: "
            + gene_data
            + ". In particular, we want to know the following information: Is this gene well studied or is it hypothetical with unknown function? "
            "Is the gene essential for survival? Is the gene or gene product a good antibacterial drug target? What other genes does this gene interact with? "
            "Is this gene part of an operon (cluster of genes on the chromosome that work together to carry out complex functions)? "
            "Is this gene involved in transcriptional regulation? Is it known what gene regulates this gene's expression? "
            "Does this gene also occur in other bacteria? If you were starting out as a research microbiologist, what might be a hypothesis you could explore related to this protein that would have significant scientific impact? "
            "Where possible, give concise answers to these questions as well as describe the function of the gene more generally if it is known."
        )
        all_prompts.append(prompt)
        all_gene_ids.append(gene_data)
        all_genome_ids.append(genome_id)

print_with_timestamp(f"Loaded {len(all_prompts)} prompts from {line_count} lines")

# Write header for TSV format
if output_format == 'tsv':
    write_output("genome_id\tgene_id\tresponse\tstatus")

# Process prompts in batches
for i in range(0, len(all_prompts), batch_size):
    batch_prompts = all_prompts[i:i+batch_size]
    batch_gene_ids = all_gene_ids[i:i+batch_size]
    batch_genome_ids = all_genome_ids[i:i+batch_size]
    
    print_with_timestamp(f"Processing batch {i//batch_size + 1} of {(len(all_prompts) + batch_size - 1)//batch_size}")
    
    # Call the model with the batch of prompts
    responses = call_model(batch_prompts)
    
    for j, response in enumerate(responses):
        genome_id = batch_genome_ids[j]
        gene_id = batch_gene_ids[j]
        
        if response is None:
            print_with_timestamp(f"ERROR: Return Type is None for Genome: {genome_id}, Gene ID: {gene_id}")
            if output_format == 'tsv':
                write_output(f"{genome_id}\t{gene_id}\t\tERROR")
            elif output_format == 'json':
                import json
                write_output(json.dumps({
                    'genome_id': genome_id,
                    'gene_id': gene_id,
                    'response': None,
                    'status': 'ERROR'
                }))
            else:
                write_output(f"[GENOME: {genome_id}] [GENE: {gene_id}] ERROR: No response")
        else:
            response_text = response.choices[0].message.content
            
            if output_format == 'tsv':
                # Escape tabs and newlines in response text for TSV
                response_text_escaped = response_text.replace('\t', ' ').replace('\n', ' ')
                write_output(f"{genome_id}\t{gene_id}\t{response_text_escaped}\tSUCCESS")
            elif output_format == 'json':
                import json
                write_output(json.dumps({
                    'genome_id': genome_id,
                    'gene_id': gene_id,
                    'response': response_text,
                    'status': 'SUCCESS'
                }))
            else:
                write_output(f"[GENOME: {genome_id}] [GENE: {gene_id}]")
                write_output(response_text)
                write_output("\n" + "-" * 80 + "\n")

print_with_timestamp(f"Processed {len(all_prompts)} prompts in {(len(all_prompts) + batch_size - 1)//batch_size} batches")

if output_handle:
    output_handle.close()
    print_with_timestamp(f"Output written to {output_file}")

