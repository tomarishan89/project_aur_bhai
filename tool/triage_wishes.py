#!/usr/bin/env python3
"""
Project Aur Bhai — Offline Wish Clustering & Roadmap Prioritization Tool
(MS-I-WISH-FEEDBACK)

Reads raw user feedback batches, clusters semantically similar wishes,
evaluates decentralization/sovereignty architectural fit, and outputs
a prioritized Markdown digest.

Usage:
  python tool/triage_wishes.py --input feedback/raw_wishes.json --output feedback/digests/2026-08-26.md
  python tool/triage_wishes.py --test
"""

import sys
import os
import json
import argparse
import re
from datetime import datetime
from collections import defaultdict

# Known architectural categories and feasibility rules
ARCH_RULES = {
    "local_first": {"score": 1.0, "label": "Native On-Device (High Fit)"},
    "voice_core": {"score": 1.0, "label": "Voice / Ambient OS (High Fit)"},
    "ui_theme": {"score": 0.9, "label": "UI & Accessibility (High Fit)"},
    "new_agent": {"score": 0.85, "label": "New Bhai Code Seed (High Fit)"},
    "external_cloud": {"score": 0.1, "label": "Incompatible (Violates Zero-Cloud Sovereignty)"},
}

MOCK_WISHES = [
    {"text": "I wish I could increase font size in the app", "category": "ui", "app_version": "3.12"},
    {"text": "Make the text bigger on screen please", "category": "ui", "app_version": "3.12"},
    {"text": "Can we have larger text setting?", "category": "ui", "app_version": "3.12"},
    {"text": "Wish there was a dark red or crimson theme", "category": "ui", "app_version": "3.12"},
    {"text": "Add a currency converter and unit calculator", "category": "agent", "app_version": "3.12"},
    {"text": "Need a unit converter tool for miles to km", "category": "agent", "app_version": "3.12"},
    {"text": "Wish I could backup my data to AWS Cloud database", "category": "general", "app_version": "3.12"},
    {"text": "Faster voice response latency on wake", "category": "voice", "app_version": "3.12"},
]

def normalize_text(text):
    text = text.lower()
    text = re.sub(r'^(i wish|bhai i wish|my wish is|please add|can we have|wish)\s+', '', text)
    text = re.sub(r'[^\w\s]', '', text)
    return text.strip()

def cluster_wishes(raw_wishes):
    """
    Heuristic & Keyword Semantic Clustering for offline triage.
    Groups semantically overlapping phrases into canonical topic buckets.
    """
    clusters = defaultdict(lambda: {
        "title": "",
        "category": "general",
        "quotes": [],
        "count": 0,
        "arch_type": "local_first",
        "action": ""
    })

    for item in raw_wishes:
        text = item.get("text", "").strip()
        if not text:
            continue
        
        lower = text.lower()
        
        # 1. Font / Text size
        if any(w in lower for w in ["font", "text size", "bigger text", "larger text", "readability"]):
            c = clusters["ui_font_size"]
            c["title"] = "Adjustable UI Font Size & Scaling"
            c["category"] = "UI / Core UX"
            c["arch_type"] = "ui_theme"
            c["action"] = "Add font scaling slider to Settings"
            c["quotes"].append(text)
            c["count"] += 1
            
        # 2. Themes / Colors
        elif any(w in lower for w in ["theme", "color", "crimson", "dark red", "solar", "accent"]):
            c = clusters["ui_themes"]
            c["title"] = "Additional Accent Glows & Color Palettes"
            c["category"] = "UI / Themes"
            c["arch_type"] = "ui_theme"
            c["action"] = "Expand ThemeService palette list"
            c["quotes"].append(text)
            c["count"] += 1

        # 3. Unit / Currency Converter
        elif any(w in lower for w in ["converter", "unit", "currency", "miles to km", "kg to lbs"]):
            c = clusters["agent_converter"]
            c["title"] = "Unit & Currency Converter Bro Code"
            c["category"] = "New Bhai Code"
            c["arch_type"] = "new_agent"
            c["action"] = "Seed UnitConverter.js into Sabke Bhai catalog"
            c["quotes"].append(text)
            c["count"] += 1

        # 4. Voice Latency / Audio
        elif any(w in lower for w in ["voice latency", "faster voice", "wake speed", "response time", "lag"]):
            c = clusters["voice_latency"]
            c["title"] = "Audio Handshake Latency Optimization"
            c["category"] = "Voice Core"
            c["arch_type"] = "voice_core"
            c["action"] = "Profile native audio recording buffer & wake delay"
            c["quotes"].append(text)
            c["count"] += 1

        # 5. Incompatible Cloud Requests
        elif any(w in lower for w in ["aws", "google drive", "central cloud", "firebase database", "cloud sync"]):
            c = clusters["incompatible_cloud"]
            c["title"] = "Centralized Cloud Database Sync"
            c["category"] = "Incompatible"
            c["arch_type"] = "external_cloud"
            c["action"] = "Reject: Violates Zero-Cloud Data Sovereignty"
            c["quotes"].append(text)
            c["count"] += 1

        else:
            norm = normalize_text(text)
            key = "misc_" + norm[:20]
            c = clusters[key]
            c["title"] = text[:50] + ("..." if len(text) > 50 else "")
            c["category"] = item.get("category", "general").capitalize()
            c["arch_type"] = "local_first"
            c["action"] = "Investigate feature scope"
            c["quotes"].append(text)
            c["count"] += 1

    return list(clusters.values())

def score_and_rank(clusters, total_submissions):
    ranked = []
    for c in clusters:
        fit_info = ARCH_RULES.get(c["arch_type"], {"score": 0.5, "label": "Unknown"})
        fit_score = fit_info["score"]
        freq = c["count"]
        
        # Priority score
        score = freq * fit_score * (10 if c["arch_type"] != "external_cloud" else 0.1)
        ranked.append({
            **c,
            "fit_label": fit_info["label"],
            "score": round(score, 2),
            "percentage": round((freq / max(1, total_submissions)) * 100, 1)
        })

    ranked.sort(key=lambda x: x["score"], reverse=True)
    return ranked

def generate_markdown_digest(ranked_clusters, total_count):
    lines = [
        "# Project Aur Bhai — Weekly Wishlist Digest",
        f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')} | **Total Submissions Processed:** {total_count}",
        "",
        "## Prioritized Product Demand Matrix",
        "",
        "| Rank | Canonical Wish Topic | Count (%) | Category | Arch Fit | Recommended Action |",
        "| :---: | :--- | :---: | :--- | :--- | :--- |"
    ]

    for idx, r in enumerate(ranked_clusters, start=1):
        count_str = f"{r['count']} ({r['percentage']}%)"
        lines.append(
            f"| **#{idx}** | **{r['title']}** | {count_str} | {r['category']} | {r['fit_label']} | {r['action']} |"
        )

    lines.append("")
    lines.append("## Verbatim User Quotes Sample")
    for r in ranked_clusters[:5]:
        lines.append(f"\n### {r['title']} ({r['count']} users)")
        for q in r["quotes"][:3]:
            lines.append(f"- *\"{q}\"*")

    return "\n".join(lines)

def main():
    parser = argparse.ArgumentParser(description="Triage & Cluster Project Aur Bhai User Wishes")
    parser.add_argument("--input", help="Path to raw wishes JSON file")
    parser.add_argument("--output", help="Path to write Markdown digest")
    parser.add_argument("--test", action="store_true", help="Run self-test with mock data")
    args = parser.parse_args()

    if args.test:
        print("[Triage] Running self-test with mock wishes dataset...")
        raw_data = MOCK_WISHES
    elif args.input:
        if not os.path.exists(args.input):
            print(f"Error: File not found: {args.input}", file=sys.stderr)
            sys.exit(1)
        with open(args.input, "r", encoding="utf-8") as f:
            raw_data = json.load(f)
    else:
        print("[Triage] No input provided; running with mock dataset.")
        raw_data = MOCK_WISHES

    if isinstance(raw_data, dict) and "wishes" in raw_data:
        raw_data = raw_data["wishes"]

    total = len(raw_data)
    clusters = cluster_wishes(raw_data)
    ranked = score_and_rank(clusters, total)
    digest_md = generate_markdown_digest(ranked, total)

    if args.output:
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(digest_md)
        print(f"[Triage] Wrote digest to {args.output}")
    else:
        print("\n" + digest_md)

if __name__ == "__main__":
    main()
