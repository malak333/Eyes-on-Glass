import datetime
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from db.database import Base, VideoLog

@pytest.fixture(scope="module")
def sqlite_test_db():
    engine = create_engine("sqlite:///:memory:", echo=False)
    Base.metadata.create_all(bind=engine)
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    db = TestingSessionLocal()
    yield db
    db.close()

def test_iso8601_datetime_format(sqlite_test_db):
    """
    Verifies that the `created_at` field natively serializes into a standard string pattern
    when evaluated by SQLAlchemy. This defends against cross-language format leakage
    (for example, Swift accidentally writing floats instead of ISO8601 strings into the shared DB).
    """
    
    # Create test log entry securely 
    log_entry = VideoLog(
        video_filename="test_formatting.mp4",
        timestamp_sec=2.5,
        node_source="Test-Node",
        node_backbone="Test-Backbone",
        node_dest="Test-Dest",
        issue_type="ok",
        issue_score=1.0,
        analysis_engine="swift_validator",
        thumbnail_path="test_frame.jpg",
        created_at=datetime.datetime.utcnow()
    )
    
    sqlite_test_db.add(log_entry)
    sqlite_test_db.commit()
    sqlite_test_db.refresh(log_entry)
    
    # Query it back
    fetched_entry = sqlite_test_db.query(VideoLog).filter(VideoLog.video_filename == "test_formatting.mp4").first()
    
    # Verify the object extracts as a proper `datetime`, proving that SQLite serialized it correctly
    assert fetched_entry.created_at is not None
    assert isinstance(fetched_entry.created_at, datetime.datetime)
    
    from sqlalchemy.sql import text
    # Manually extract the raw inserted type from sqlite sequence
    raw_created_at = sqlite_test_db.execute(text("SELECT created_at FROM video_logs WHERE video_filename='test_formatting.mp4'")).scalar()
    
    # Natively SQLite represents it as strings under SA execution, not a float epoch
    assert isinstance(raw_created_at, str)
    assert "-" in raw_created_at
