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
