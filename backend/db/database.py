import os
from datetime import datetime
from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()


class VideoLog(Base):
    __tablename__ = "video_logs"

    id = Column(Integer, primary_key=True, index=True)
    video_filename = Column(String, index=True)
    timestamp_sec = Column(Float, index=True)  # Frame timestamp in seconds
    node_source = Column(String)               # Mock source e.g., 'Source-A'
    node_backbone = Column(String)             # Mock backbone
    node_dest = Column(String)                 # Mock dest
    # e.g., 'black_screen', 'macroblocking', 'slate', 'no_audio', 'ok'
    issue_type = Column(String, index=True)
    issue_score = Column(Float)                # Confidence or severity score
    thumbnail_path = Column(String)            # Path to saved frame image
    created_at = Column(DateTime, default=datetime.utcnow)


DB_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "sqlite.db")
SQLALCHEMY_DATABASE_URL = f"sqlite:///{DB_PATH}"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def init_db():
    Base.metadata.create_all(bind=engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
