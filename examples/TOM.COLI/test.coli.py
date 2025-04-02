import sys, os
from openai import OpenAI

# Ensure that a file path is provided
if len(sys.argv) != 2:
    print(f"usage: {sys.argv[0]} dirname") 
    sys.exit(1)

directory = sys.argv[1]

# Model configuration
model = "meta-llama/Llama-3.3-70B-Instruct"
host = "localhost"
port = "8000"
key = "EMPTY"

openai_api_base = f"http://{host}:{port}/v1"

client = OpenAI(
    api_key=key,
    base_url=openai_api_base,
)

def call_model(prompt):

    chat_response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "user", "content": prompt},
        ],
        temperature=0.0,
        max_tokens=2056,
    )
    print("Chat response:", chat_response)
    return chat_response

# Read gene IDs and query locally
for filename in os.listdir(directory):
    if filename.endswith(".txt"):
        file_path = os.path.join(directory, filename)
        with open(file_path, "r", encoding="utf-8") as file:
            for line in file:
                line = line.strip()
            prompt = (
            "Please tell me (using the knowledge you have been trained on) what you know about this bacterial gene whose various IDs are given here, though they all refer to the same gene: "
            + line
            + ". In particular, we want to know the following information: Is this gene well studied or is it hypothetical with unknown function? "
            "Is the gene essential for survival? Is the gene or gene product a good antibacterial drug target? What other genes does this gene interact with? "
            "Is this gene part of an operon (cluster of genes on the chromosome that work together to carry out complex functions)? "
            "Is this gene involved in transcriptional regulation? Is it known what gene regulates this gene’s expression? "
            "Does this gene also occur in other bacteria? If you were starting out as a research microbiologist, what might be a hypothesis you could explore related to this protein that would have significant scientific impact? "
            "Where possible, give concise answers to these questions as well as describe the function of the gene more generally if it is known."
        )
            response = ""
            response = call_model(prompt)
            print("\nGene IDs: ", line)
            print("\nPrompt: ", prompt)
            print("\nResponse: ", response.choices[0].message.content)
            print("\n" + "-" * 80 + "\n")
