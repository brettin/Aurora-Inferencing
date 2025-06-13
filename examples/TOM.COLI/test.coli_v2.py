import sys, os
import argparse
import time
import concurrent.futures
from openai import OpenAI
from openai.types.chat import ChatCompletion

# This script processes gene ID files from a specified directory and queries a vLLM server running a large language model.
# It reads gene IDs from the files in that dir, constructs all the prompts, and them processes the prompts in batches as it
# sends them to the model via API calls with configurable timeout and batch size, and handles the responses.

def process_batch(batch_prompts, batch_gene_ids, model, client):
    """Process a single batch of prompts."""
    try:
        print(f"Sending {len(batch_prompts)} prompts to the model {model}...")
        # Create a single message with all prompts concatenated
        combined_prompt = "\n\n".join(batch_prompts)
        response = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": combined_prompt}],
            temperature=0.0,
            max_tokens=1024,
            n=len(batch_prompts),  # Request n completions
            stream=False
        )
        print(f'Received {len(response.choices)} choices')
        
        # Process the responses
        if response is None:
            print("Error: No responses received")
            return []
        else:
            results = []
            for j, choice in enumerate(response.choices):
                gene_id = batch_gene_ids[j]
                print("\nGene IDs: ", gene_id)
                print("\nPrompt: ", batch_prompts[j])
                print("\nResponse: ", choice.message.content)
                print("\n" + "-" * 80 + "\n")
                results.append((gene_id, choice.message.content))
            return results
    except Exception as e:
        print(f"Error processing batch: {e}")
        return []

def main():
    parser = argparse.ArgumentParser(description='''
    This script processes gene ID files and queries a vLLM server running a large language model. It performs the following operations:

    1. Reads gene ID files from a specified directory
    2. Constructs prompts for each gene ID
    3. Processes prompts in configurable batch sizes
    4. Sends batches to the vLLM server via API calls
    5. Handles responses and saves results
    ''')
    parser.add_argument('directory', help='Directory containing gene ID files')
    parser.add_argument('host', help='Hostname of the vLLM server')
    parser.add_argument('--batch-size', type=int, default=1, help='Number of prompts to send in a batch (default: 1)')
    parser.add_argument('--timeout', type=int, default=60, help='Timeout in seconds for API calls (default: 60)')
    parser.add_argument('--model', default='meta-llama/Llama-3.1-70B-Instruct', help='Model name to use (default: meta-llama/Llama-3.1-70B-Instruct)')
    parser.add_argument('--port', default='8000', help='Port number for the vLLM server (default: 8000)')
    parser.add_argument('--key', default='EMPTY', help='API key for authentication (default: EMPTY)')
    parser.add_argument('--max-workers', type=int, default=4, help='Maximum number of parallel workers (default: 4)')

    args = parser.parse_args()

    directory = args.directory
    host = args.host
    batch_size = args.batch_size
    timeout = args.timeout
    model = args.model
    port = args.port
    key = args.key
    max_workers = args.max_workers

    openai_api_base = f"http://{host}:{port}/v1"
    client = OpenAI(
        base_url=openai_api_base,
        api_key=key
    )

    # Read all gene ID files from the directory
    all_prompts = []
    all_gene_ids = []
    for filename in os.listdir(directory):
        if filename.endswith('.txt'):
            file_path = os.path.join(directory, filename)
            with open(file_path, 'r') as f:
                gene_ids = [line.strip() for line in f if line.strip()]
                for gene_id in gene_ids:
                    prompt = f"Given the gene ID {gene_id}, what is the function of this gene in E. coli?"
                    all_prompts.append(prompt)
                    all_gene_ids.append(gene_id)

    # Process prompts in batches using ThreadPoolExecutor
    all_results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        # Create batch futures
        futures = []
        for i in range(0, len(all_prompts), batch_size):
            batch_prompts = all_prompts[i:i + batch_size]
            batch_gene_ids = all_gene_ids[i:i + batch_size]
            future = executor.submit(process_batch, batch_prompts, batch_gene_ids, model, client)
            futures.append(future)
        
        # Collect results as they complete
        for future in concurrent.futures.as_completed(futures):
            batch_results = future.result()
            all_results.extend(batch_results)

    print(f"Processed {len(all_prompts)} prompts in {(len(all_prompts) + batch_size - 1)//batch_size} batches")
    print(f"Total results collected: {len(all_results)}")

if __name__ == "__main__":
    main()
