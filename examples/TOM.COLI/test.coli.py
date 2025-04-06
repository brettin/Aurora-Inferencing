import sys, os
import argparse
from openai import OpenAI

# Parse command line arguments
parser = argparse.ArgumentParser(description='Process gene IDs and query the model')
parser.add_argument('directory', help='Directory containing gene ID files')
parser.add_argument('host', help='Hostname of the vLLM server')
parser.add_argument('--batch-size', type=int, default=1, help='Number of prompts to send in a batch (default: 1)')
args = parser.parse_args()

directory = args.directory
host = args.host
batch_size = args.batch_size

# Model configuration
model = "meta-llama/Llama-3.3-70B-Instruct"
port = "8000"
key = "EMPTY"

openai_api_base = f"http://{host}:{port}/v1"

client = OpenAI(
    api_key=key,
    base_url=openai_api_base,
)

def call_model(prompts):
    """
    Call the model with a batch of prompts
    """
    # Create a list of messages for each prompt
    messages_list = []
    for prompt in prompts:
        messages_list.append([
            {"role": "user", "content": prompt},
        ])
    
    # Call the model with the batch of prompts
    chat_responses = client.chat.completions.create(
        model=model,
        messages=messages_list,
        temperature=0.0,
        max_tokens=2056,
    )
    
    return chat_responses

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
    responses = call_model(batch_prompts)
    
    # Process the responses
    for j, response in enumerate(responses):
        gene_id = batch_gene_ids[j]
        print("\nGene IDs: ", gene_id)
        print("\nPrompt: ", batch_prompts[j])
        print("\nResponse: ", response.choices[0].message.content)
        print("\n" + "-" * 80 + "\n")

print(f"Processed {len(all_prompts)} prompts in {(len(all_prompts) + batch_size - 1)//batch_size} batches")
