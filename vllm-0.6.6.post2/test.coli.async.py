import asyncio
from openai import AsyncOpenAI
import argparse
parser = argparse.ArgumentParser()

# This seems like alot of lines of code to manage arguments.
parser.add_argument("--port", type=int, default=8000, help="port number, default 8000")
parser.add_argument("--host", type=str, default="localhost", help="host name, default localhost")
parser.add_argument("--model", type=str, default="meta-llama/Llama-3.3-70B-Instruct", help="repo/model, default meta-llama/Llama-3.3-70B-Instruct")
parser.add_argument("--key", type=str, default="EMPTY", help="the key passed to the vllm entrypoint when it was started")
parser.add_argument('directory', help='Directory containing gene ID files')
parser.add_argument('--batch-size', type=int, default=1, help='Number of prompts to send in a batch (default: 1)')

args = parser.parse_args()

print(f'using host: {args.host}')
print(f'using port: {args.port}')
print(f'using model: {args.model}')
print(f'using api-key: {args.key}')
print(f'using dir: {args.directory')
print(f'using batch size: {args.batch-size}')

model=args.model
key=args.key
host=args.host
port=args.port
base_url=f"http://{host}:{port}/v1"
# Done dealing with command line arguments.



client = AsyncOpenAI(api_key=key,
        base_url=base_url)

async def fetch_completion(prompt):
    response = await client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}]
    )
    return response.choices[0].message.content

async def main():

    # build a prompt for every file in the directory
    for filename in os.listdir(directory):
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
    # done building a prompt for every file in the directory

    batch_size = 2  # set your desired batch size
    for i in range(0, len(all_prompts), batch_size):
        batch_prompts = all_prompts[i:i + batch_size]
        results = await asyncio.gather(*(fetch_completion(p) for p in batch_prompts))

        for prompt, result in zip(batch_prompts, results):
            print(f"Prompt: {prompt}\nAnswer: {result}\n")


asyncio.run(main())

