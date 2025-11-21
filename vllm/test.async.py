import asyncio
from openai import AsyncOpenAI
import argparse
parser = argparse.ArgumentParser()

# This seems like alot of lines of code to manage arguments.
parser.add_argument("--port", type=int, default=8000,
                    help="port number, default 8000")
parser.add_argument("--host", type=str, default="localhost",
            help="host name, default localhost")
parser.add_argument("--model", type=str, default="meta-llama/Llama-3.3-70B-Instruct",
                    help="repo/model, default meta-llama/Llama-3.3-70B-Instruct")
parser.add_argument("--key", type=str, default="EMPTY",
        help="the key passed to the vllm entrypoint when it was started")
parser.add_argument("--timeout", type=float, default=60.0,
        help="timeout in seconds for API calls (default: 60.0)")

args = parser.parse_args()
print(f'using host: {args.host}')
print(f'using port: {args.port}')
print(f'using model: {args.model}')
print(f'using api-key: {args.key}')
print(f'using timeout: {args.timeout} seconds')

model=args.model
key=args.key
host=args.host
port=args.port
timeout=args.timeout
base_url=f"http://{host}:{port}/v1"
# Done dealing with command line arguments.



client = AsyncOpenAI(api_key=key,
        base_url=base_url)

async def fetch_completion(prompt):
    try:
        # Use asyncio.wait_for to implement timeout
        response = await asyncio.wait_for(
            client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}]
            ),
            timeout=timeout
        )
        return response.choices[0].message.content
    except asyncio.TimeoutError:
        print(f"Request timed out after {timeout} seconds")
        return f"ERROR: Request timed out after {timeout} seconds"
    except Exception as e:
        print(f"Error: {e}")
        return f"ERROR: {str(e)}"

async def main():
    prompts = [
        "Prompt A: What is the capital of France?",
        "Prompt B: Explain photosynthesis in one sentence.",
        "Prompt C: What is the largest planet in our solar system?"
    ]
    prompts = [
        "A detailed description of the biochemical function 5-(hydroxymethyl)furfural/furfural transporter is",
        "A detailed description of the biochemical function post-translational modification of the P2X7 receptor by N-linked glycosylation, adenosine 5'-diphosphate ribosylation and palmitoylation.",
        "A review of interaction partners of the P2X7 receptor, and its cellular localisation and trafficking within cells.",
    ]

    # Execute concurrently; results will retain input order.
    results = await asyncio.gather(*(fetch_completion(prompt) for prompt in prompts))

    for prompt, result in zip(prompts, results):
        print(f"Prompt: {prompt}\nAnswer: {result}\n")

asyncio.run(main())

