import sys, os
import argparse
import time
import concurrent.futures
from openai import OpenAI
from openai.types.chat import ChatCompletion

# This script processes gene ID files from a specified directory and queries a vLLM server running a large language model.
# It reads gene IDs from the files in that dir, constructs all the prompts, and them processes the prompts in batches as it
# sends them to the model via API calls with configurable timeout and batch size, and handles the responses.
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

args = parser.parse_args()

directory = args.directory
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
    messages_list = []
    for prompt in prompts:
        messages_list.append({"role": "user", "content": prompt})
    
    try:
        print(f"Sending {len(messages_list)} prompts to the model {model}...")
        return client.chat.completions.create(
            model=model,
            messages=messages_list,  # Send all messages in the batch
            temperature=0.0,
            max_tokens=1024,
            stream=False
        )
    except Exception as e:
        print(f"Error calling model: {e}")
        return None

def call_model_with_timeout(prompts, timeout_seconds):
    """
    Call the model with a batch of prompts with a timeout
    """
    # Create a list of messages for each prompt
    messages_list = []
    for prompt in prompts:
        messages_list.append([
            {"role": "user", "content": prompt},
        ])
    
    def api_call():
        print(f"Sending {len(messages_list)} prompts to the model {model}...")
        return client.chat.completions.create(
            model=model,
            messages=messages_list,
            temperature=0.0,
            max_tokens=2056,
        )
    
    try:
        # Use ThreadPoolExecutor to implement timeout
        with concurrent.futures.ThreadPoolExecutor() as executor:
            future = executor.submit(api_call)
            start_time = time.time()
            chat_responses = future.result(timeout=timeout_seconds)
            elapsed_time = time.time() - start_time
            print(f"API call completed in {elapsed_time:.2f} seconds")
            return chat_responses
    except concurrent.futures.TimeoutError:
        print(f"API call timed out after {timeout_seconds} seconds")
        # Return a list of None values with the same length as prompts
        return [None] * len(prompts)
    except Exception as e:
        print(f"Error calling model: {e}")
        # Return a list of None values with the same length as prompts
        return [None] * len(prompts)

# Collect all prompts from files
all_prompts = []
all_gene_ids = []

# Read gene IDs and query locally
for filename in os.listdir(directory):
    if filename.endswith(".txt"):
        file_path = os.path.join(directory, filename)
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
    
    print(f"\nProcessing batch {i//batch_size + 1} of {(len(all_prompts) + batch_size - 1)//batch_size}")
    print(f"Sending {len(batch_prompts)} prompts to the model...")
    
    # Call the model with the batch of prompts
    # responses = call_model_with_timeout(batch_prompts, timeout)
    responses = call_model(batch_prompts)
    print(responses)

    # Process the responses
    #for j, response in enumerate(responses):
    #    gene_id = batch_gene_ids[j]
    #    print("\nGene IDs: ", gene_id)
    #    print("\nPrompt: ", batch_prompts[j])
          
    #    if response is None:
    #        print("\nResponse: ERROR - Request timed out or failed")
    #    else:
    #        print("\nResponse: ", response)
    #        #print("\nResponse: ", response.choices[0].message.content)
        
    #    print("\n" + "-" * 80 + "\n")

print(f"Processed {len(all_prompts)} prompts in {(len(all_prompts) + batch_size - 1)//batch_size} batches")
