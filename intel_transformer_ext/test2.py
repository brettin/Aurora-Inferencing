
from intel_extension_for_transformers.neural_chat import build_chatbot
from intel_extension_for_transformers.neural_chat.config import PipelineConfig
from intel_extension_for_transformers.neural_chat.config import LoadingConfig

model = "meta-llama/Llama-3.1-70B-Instruct"
# model = "meta-llama/Meta-Llama-3-8B-Instruct"
# model = "facebook/opt-125m"
# model = "Intel/neural-chat-7b-v3-1"

loading_config =  LoadingModelConfig(use_deepspeed = True,
                                    cpu_jit=True if self.device == "cpu" else False,
                                    use_hpu_graphs = True if self.device == "hpu" else False)

config = PipelineConfig(model_name_or_path=model,
                        loading_config=loading_config)

chatbot = build_chatbot(config)

for n in range(10):
    response = chatbot.predict("Tell me about Intel Xeon Scalable Processors.")
    print(f'response: {response}')
