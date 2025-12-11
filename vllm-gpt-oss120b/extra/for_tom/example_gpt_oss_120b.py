from vllm import LLM, SamplingParams

# Replace with your model path or Hugging Face model name
def main():
    model_name = "openai/gpt-oss-120b"  # or 

# Initialize the model with the same options used in the CLI
    llm = LLM(
        model=model_name,
        tensor_parallel_size=8,
        trust_remote_code=True,
        enforce_eager=True,
    )

# Define sampling parameters (adjust as needed)
    sampling_params = SamplingParams(
        temperature=0.2,
        max_tokens=384,
    )
# Run inference
    prompt = "Explain protein structures."
    outputs = llm.generate(prompt, sampling_params)

# Print output(s)
    for output in outputs:
        print(output.outputs[0].text)

if __name__ == '__main__':
    main()
