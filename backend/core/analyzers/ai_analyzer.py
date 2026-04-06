import httpx
import base64

async def analyze_frame_ai(frame_path: str) -> dict:
    """
    Calls a local Ollama instance (e.g., llava or moondream) to detect slates or complex issues.
    If Ollama is not running, falls back to a mock 'ok' response.
    """
    try:
        with open(frame_path, "rb") as image_file:
            encoded_string = base64.b64encode(image_file.read()).decode('utf-8')
        
        prompt = "Describe this image briefly. Is it a blank slate, a test pattern, or a normal video frame?"
        
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "http://localhost:11434/api/generate",
                json={
                    "model": "llava",  # Using llava as default vision model
                    "prompt": prompt,
                    "images": [encoded_string],
                    "stream": False
                },
                timeout=10.0
            )
            
            if response.status_code == 200:
                result = response.json().get("response", "").lower()
                
                is_slate = "slate" in result or "test pattern" in result
                
                return {
                    "is_slate": bool(is_slate),
                    "ai_description": result,
                    "confidence": 0.85 if is_slate else 0.9
                }
    except Exception as e:
        # Fallback if Ollama is not available
        pass

    return {
        "is_slate": False,
        "ai_description": "Ollama not reachable or failed",
        "confidence": 0.0
    }
