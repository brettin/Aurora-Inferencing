import sys
from vllm import LLM, SamplingParams

if len(sys.argv) == 3:
    infile=sys.argv[1]
    outfile=sys.argv[2]
else:
    print(f"usage {sys.argv[0]} infile outfile")

prompts = []

with open(infile, "r") as f:
    for line in f:
        clean = line.strip()
        if clean:
            prompts.append(clean)

sampling_params = SamplingParams(temperature=0.8, top_p=0.95)
llm = LLM(model=os.getenv("MODEL_NAME", "facebook/opt-125m"), device="xpu")
outputs = llm.generate(prompts, sampling_params)

with open(outfile, "w") as f:
    for output in outputs:
        prompt = output.prompt
        generated_text = output.outputs[0].text
        f.write(f"Prompt: {prompt!r}, Generated text: {generated_text!r}\n\n")
