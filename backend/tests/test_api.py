from fastapi.testclient import TestClient
import pytest
from app.main import app
from db.database import init_db

@pytest.fixture(scope="module", autouse=True)
def setup_database():
    init_db()

client = TestClient(app)

def test_get_progress():
    response = client.get("/progress")
    assert response.status_code == 200
    assert isinstance(response.json(), dict)

def test_get_stats():
    response = client.get("/stats")
    assert response.status_code == 200
    data = response.json()
    assert "total_frames" in data
    assert "issues_count" in data
    assert "health_score" in data

def test_get_system_resources():
    response = client.get("/system/resources")
    assert response.status_code == 200
    assert isinstance(response.json(), list) or isinstance(response.json(), dict)

@pytest.mark.asyncio
async def test_check_ollama_status():
    with TestClient(app) as client:
        response = client.get("/system/ollama_status")
        assert response.status_code == 200
        data = response.json()
        assert "status" in data
        assert data["status"] in ["running", "stopped"]

def test_get_logs():
    response = client.get("/logs")
    assert response.status_code == 200
    data = response.json()
    assert "logs" in data
    assert isinstance(data["logs"], list)
    if len(data["logs"]) > 0:
        assert "analysis_engine" in data["logs"][0]

def test_upload_video():
    files = {"file": ("dummy.mp4", b"dummy content", "video/mp4")}
    response = client.post("/upload", files=files)
    assert response.status_code == 200
    assert "message" in response.json()
    assert "Successfully uploaded" in response.json()["message"]
