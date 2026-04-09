import cv2
import sys
from cv_analyzer import analyze_frame

res = analyze_frame(sys.argv[1])
print(res)
