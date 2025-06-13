import sys, os
import argparse
import time
import concurrent.futures
from openai import OpenAI
from openai.types.chat import ChatCompletion
from datetime import datetime

def print_with_timestamp(message):
    """Helper function to print messages with timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}")

parser = argparse.ArgumentParser(description='''

This script processes gene IDs from a specified file and queries a vLLM server running a large language model. It performs the following operations:

1. Reads gene IDs from a specified input file
2. Constructs prompts for each gene ID
3. Processes prompts in configurable batch sizes
4. Sends batches to the vLLM server via API calls
5. Handles responses and saves results

''')

parser.add_argument('file', help='File containing gene IDs')
parser.add_argument('host', help='Hostname of the vLLM server')
parser.add_argument('--batch-size', type=int, default=1, help='Number of prompts to send in a batch (default: 1)')
parser.add_argument('--timeout', type=int, default=60, help='Timeout in seconds for API calls (default: 60)')
parser.add_argument('--model', default='meta-llama/Llama-3.1-70B-Instruct', help='Model name to use (default: meta-llama/Llama-3.1-70B-Instruct)')
parser.add_argument('--port', default='8000', help='Port number for the vLLM server (default: 8000)')
parser.add_argument('--key', default='EMPTY', help='API key for authentication (default: EMPTY)')

args = parser.parse_args()

file_path = args.file
host = args.host
batch_size = args.batch_size
timeout = args.timeout
model = args.model
port = args.port
key = args.key

openai_api_base = f"http://{host}:{port}/v1"

client = OpenAI(
    api_key=key,
    base_url=openai_api_base,
)

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
            return None

    print_with_timestamp(f"Sending {len(prompts)} prompts to the model {model}...")
    with concurrent.futures.ThreadPoolExecutor() as executor:
        # Submit all prompts to be processed in parallel
        future_to_prompt = {executor.submit(process_single_prompt, prompt): prompt for prompt in prompts}
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

# Read gene IDs and query locally
with open(file_path, "r", encoding="utf-8") as file:
    for line in file:
        line = line.strip()
        gene_id = line
        prompt = (
            "Please tell me (using the knowledge you have been trained on) what you know about this bacterial gene whose various IDs are given here, though they all refer to the same gene: "
            + line
            + ". In particular, we want to know the following information: Is this gene well studied or is it hypothetical with unknown function? "
            "Is the gene essential for survival? Is the gene or gene product a good antibacterial drug target? What other genes does this gene interact with? "
            "Is this gene part of an operon (cluster of genes on the chromosome that work together to carry out complex functions)? "
            "Is this gene involved in transcriptional regulation? Is it known what gene regulates this gene's expression? "
            "Does this gene also occur in other bacteria? If you were starting out as a research microbiologist, what might be a hypothesis you could explore related to this protein that would have significant scientific impact? "
            "Where possible, give concise answers to these questions as well as describe the function of the gene more generally if it is known."
        )
        all_prompts.append(prompt)
        all_gene_ids.append(gene_id)

# Process prompts in batches
for i in range(0, len(all_prompts), batch_size):
    batch_prompts = all_prompts[i:i+batch_size]
    batch_gene_ids = all_gene_ids[i:i+batch_size]
    
    print_with_timestamp(f"\nProcessing batch {i//batch_size + 1} of {(len(all_prompts) + batch_size - 1)//batch_size}")
    print_with_timestamp(f"Sending {len(batch_prompts)} prompts to the model...")
    
    # Call the model with the batch of prompts
    # responses = call_model_with_timeout(batch_prompts, timeout)
    responses = call_model(batch_prompts)
    for response in responses:
        print_with_timestamp(f"{response.choices[0].message.content}")
        print_with_timestamp("\n" + "-" * 80 + "\n")

print_with_timestamp(f"Processed {len(all_prompts)} prompts in {(len(all_prompts) + batch_size - 1)//batch_size} batches")
