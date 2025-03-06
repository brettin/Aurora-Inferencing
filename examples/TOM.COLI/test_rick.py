import sys
from intel_extension_for_transformers.neural_chat import build_chatbot
from intel_extension_for_transformers.neural_chat.config import PipelineConfig

# Ensure that a file path is provided
if len(sys.argv) != 2:
    print(“Usage: python script.py <file_path>“)
    sys.exit(1)
file_path = sys.argv[1]

# Model configuration
model = “meta-llama/Meta-Llama-3-8B-Instruct”
config = PipelineConfig(model_name_or_path=model)
chatbot = build_chatbot(config)

# Read gene IDs and query locally
with open(file_path, ‘r’) as file:
    for line in file:
        line = line.strip()
        prompt = (
            “Please tell me (using the knowledge you have been trained on) what you know about this bacterial gene whose various IDs are given here, though they all refer to the same gene: ”
            + line
            + “. In particular, we want to know the following information: Is this gene well studied or is it hypothetical with unknown function? ”
            “Is the gene essential for survival? Is the gene or gene product a good antibacterial drug target? What other genes does this gene interact with? ”
            “Is this gene part of an operon (cluster of genes on the chromosome that work together to carry out complex functions)? ”
            “Is this gene involved in transcriptional regulation? Is it known what gene regulates this gene’s expression? ”
            “Does this gene also occur in other bacteria? If you were starting out as a research microbiologist, what might be a hypothesis you could explore related to this protein that would have significant scientific impact? ”
            “Where possible, give concise answers to these questions as well as describe the function of the gene more generally if it is known.”
        )
        response = chatbot.predict(prompt)
        print(“\nGene IDs:“, line)
        print(“Response:“, response)
        print(“\n” + “-” * 80 + “\n”)”
