"""
Project Aur Bhai - Telemetry Driving Coach Model Trainer

This script demonstrates Alternative 3 (Data Science in Python -> Native Logic).
It trains a simple Scikit-learn DecisionTree on mock SQLite-style accelerometer data
to determine whether the user is "Idle", "Walking", or "Driving" based on Z-Axis variance.

Outputs a JSON logic map that the Dart plugin executes locally 100% offline.
"""

import json
import numpy as np
import pandas as pd
from sklearn.tree import DecisionTreeClassifier, export_text

def simulate_telemetry_dataset():
    # Simulate Telemetry Data (Variance of accelerometer Z axis over 10s windows)
    # Idle: low variance (phone flat)
    # Walking: medium variance (bouncing)
    # Driving: high variance (engine vibration, bumps, turning)
    np.random.seed(42)
    
    idle_variance = np.random.normal(loc=0.1, scale=0.05, size=100)
    walk_variance = np.random.normal(loc=1.2, scale=0.3, size=100)
    drive_variance = np.random.normal(loc=3.5, scale=0.8, size=100)
    
    data = []
    for v in idle_variance: data.append({"accZ_variance": v, "label": "Idle"})
    for v in walk_variance: data.append({"accZ_variance": v, "label": "Walking"})
    for v in drive_variance: data.append({"accZ_variance": v, "label": "Driving"})
    
    return pd.DataFrame(data)

def train_and_export_model():
    df = simulate_telemetry_dataset()
    X = df[['accZ_variance']]
    y = df['label']
    
    # Train simple decision tree with max depth 2
    clf = DecisionTreeClassifier(max_depth=2, random_state=42)
    clf.fit(X, y)
    
    print("--- Scikit-Learn Decision Tree Trained ---")
    print(export_text(clf, feature_names=['accZ_variance']))
    
    # In a real environment, we would export to ONNX here.
    # For this offline edge-demonstration, we extract the learned thresholds
    # so Dart can run them perfectly without C++ compilation errors on Windows.
    tree = clf.tree_
    feature = tree.feature
    threshold = tree.threshold
    
    # Extract root threshold and right child threshold
    t1 = threshold[0]
    t2 = threshold[tree.children_right[0]]
    
    logic_map = {
        "model": "DecisionTree_DrivingCoach",
        "feature": "accZ_variance",
        "thresholds": {
            "idle_max": round(t1, 3),
            "walk_max": round(t2, 3)
        }
    }
    
    print("\n--- Extracted Model Logic for Native Dart Execution ---")
    print(json.dumps(logic_map, indent=2))
    
if __name__ == "__main__":
    train_and_export_model()
