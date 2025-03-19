import asyncio
import functools


def make_limiter(max_concurreny: int):
    """Limit the maximum concurrent runs of the async function."""
    semaphore = asyncio.Semaphore(max_concurreny)

    def decorator(f_async):
        @functools.wraps(f_async)
        async def wrapper(*args, **kwargs):
            async with semaphore:
                return await f_async(*args, **kwargs)

        return wrapper

    return decorator


def make_async(f, executor):
    @functools.wraps(f)
    async def f_async(*args, **kwargs):
        fut = executor.submit(f, *args, **kwargs)
        return await asyncio.wrap_future(fut)

    return f_async
