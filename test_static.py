import asyncio
from backend.core.video_pipeline import detect_static_audio

async def main():
    has_static = await detect_static_audio("uploads/KGO-VOD-Encoder.ts")
    print(f"KGO-VOD-Encoder has static: {has_static}")
    
    has_static = await detect_static_audio("uploads/stlu-chaifetz-audio2.ts")
    print(f"stlu-chaifetz-audio2 has static: {has_static}")

asyncio.run(main())
