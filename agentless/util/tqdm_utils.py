import asyncio

import tqdm

async def _as_completed(coros):
    for future in asyncio.as_completed(coros):
        yield await future


async def as_completed(coros, **tqdm_args):
    pbar = tqdm.tqdm(**tqdm_args)
    async for result in _as_completed(coros):
        pbar.update(1)
        yield result
