
from intel_extension_for_transformers.neural_chat import build_chatbot
from intel_extension_for_transformers.neural_chat.config import PipelineConfig

model = "meta-llama/Meta-Llama-3-8B-Instruct"
# model = "facebook/opt-125m"
# model = "Intel/neural-chat-7b-v3-1"

config = PipelineConfig(model_name_or_path=model,)

chatbot = build_chatbot(config)

for n in range(10):
    response = chatbot.predict("Tell me about Intel Xeon Scalable Processors.")
    print(f'response: {response}')
