import abc
import asyncio
from concurrent import futures

from agentless import data_types
from agentless.util import api_requests
from agentless.pub_sub import manager


class DecoderBase(abc.ABC):
    name: str
    batch_size: int
    temperature: float
    max_new_tokens: int

    def __init__(
        self,
        name: str,
        batch_size: int = 1,
        temperature: float = 0.8,
        max_new_tokens: int = 1024,
    ) -> None:
        self.name = name
        self.batch_size = batch_size
        self.temperature = temperature
        self.max_new_tokens = max_new_tokens

    @abc.abstractmethod
    def codegen(
        self,
        message: str,
        num_samples: int = 1,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> list[data_types.Trajectory]:
        return asyncio.run(self.codegen_async(message, num_samples))

    @abc.abstractmethod
    async def codegen_async(
        self,
        message: str,
        num_samples: int = 1,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> list[data_types.Trajectory]:
        pass

    def __repr__(self) -> str:
        return self.name

    def __str__(self) -> str:
        return self.name


class OpenAIDecoder(DecoderBase):

    def __init__(self, executor: futures.ThreadPoolExecutor, **kwargs):
        super().__init__(**kwargs)
        self._executor = executor

    def codegen(
        self,
        message: str,
        num_samples: int = 1,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> list[data_types.Trajectory]:
        if self.temperature == 0:
            assert num_samples == 1
        batch_size = min(self.batch_size, num_samples)

        config = api_requests.create_chatgpt_config(
            message=message,
            max_tokens=max_new_tokens or self.max_new_tokens,
            temperature=temperature or self.temperature,
            batch_size=batch_size,
            model=self.name,
        )
        ret = api_requests.request_chatgpt_engine(config)
        if ret:
            responses = [choice.message.content for choice in ret.choices]
            completion_tokens = ret.usage.completion_tokens
            prompt_tokens = ret.usage.prompt_tokens
        else:
            responses = [""]
            completion_tokens = 0
            prompt_tokens = 0

        # The nice thing is, when we generate multiple samples from the same input (message),
        # the input tokens are only charged once according to openai API.
        # Therefore, we assume the request cost is only counted for the first sample.
        # More specifically, the `prompt_tokens` is for one input message,
        # and the `completion_tokens` is the sum of all returned completions.
        # Therefore, for the second and later samples, the cost is zero.
        trajs = [
            {
                "response": responses[0],
                "usage": {
                    "completion_tokens": completion_tokens,
                    "prompt_tokens": prompt_tokens,
                },
            }
        ]
        for response in responses[1:]:
            trajs.append(
                {
                    "response": response,
                    "usage": {
                        "completion_tokens": 0,
                        "prompt_tokens": 0,
                    },
                }
            )
        return trajs

    async def codegen_async(
        self,
        message: str,
        num_samples: int = 1,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> list[data_types.Trajectory]:
        await asyncio.get_running_loop().run_in_executor(
            self._executor,
            self.codegen,
            message,
            num_samples=num_samples,
            max_new_tokens=max_new_tokens,
            temperature=temperature,
        )


class PubSubDecoder(DecoderBase):
    def __init__(self, pub_sub_mgr: manager.PubSubManager, **kwargs):
        super().__init__(**kwargs)
        self._pub_sub_mgr = pub_sub_mgr

    def codegen(
        self,
        message: str,
        num_samples: int = 1,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> list[data_types.Trajectory]:
        super().codegen(
            message,
            num_samples=num_samples,
            max_new_tokens=max_new_tokens,
            temperature=temperature,
        )

    async def _codegen_single_async(
        self,
        message: str,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> data_types.Trajectory:
        response = await self._pub_sub_mgr.call_async(
            message,
            attributes={
                "kernel_id": self.name,
                "max_decoding_steps": str(max_new_tokens or self.max_new_tokens),
                "temperature": str(temperature or self.temperature),
            },
        )
        return {
            "response": response,
            "usage": {
                "completion_tokens": 0,
                "prompt_tokens": 0,
            },
        }

    async def codegen_async(
        self,
        message: str,
        num_samples: int = 1,
        max_new_tokens: int | None = None,
        temperature: float | None = None,
    ) -> list[data_types.Trajectory]:
        aws = [
            self._codegen_single_async(
                message, max_new_tokens=max_new_tokens, temperature=temperature
            )
            for _ in range(num_samples)
        ]
        return await asyncio.gather(*aws)
