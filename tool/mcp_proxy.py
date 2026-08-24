#!/usr/bin/env python3
import sys
import json
import urllib.request
import argparse

def log(msg):
    # Print to stderr so it doesn't corrupt MCP stdio protocol on stdout
    print(msg, file=sys.stderr, flush=True)

def main():
    parser = argparse.ArgumentParser(description="MCP Proxy for Project Aur Bhai")
    parser.add_argument("--url", required=True, help="The Local Edge Server MCP URL (e.g. http://192.168.1.5:8080/api/mcp)")
    parser.add_argument("--token", required=True, help="The Pairing Token (e.g. 4F2A89)")
    args = parser.parse_args()

    headers = {
        "Content-Type": "application/json",
        "x-aur-pair": args.token
    }

    log(f"Starting MCP Proxy forwarding to {args.url}")

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        
        line = line.strip()
        if not line:
            continue
            
        try:
            req_data = json.loads(line)
        except json.JSONDecodeError:
            log("Warning: Received invalid JSON on stdin")
            continue

        try:
            req = urllib.request.Request(
                args.url,
                data=json.dumps(req_data).encode("utf-8"),
                headers=headers,
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=30) as response:
                resp_text = response.read().decode("utf-8")
                sys.stdout.write(resp_text + "\n")
                sys.stdout.flush()
        except Exception as e:
            log(f"Error forwarding request: {e}")
            error_response = {
                "jsonrpc": "2.0",
                "id": req_data.get("id"),
                "error": {
                    "code": -32603,
                    "message": f"Proxy Error: {e}"
                }
            }
            sys.stdout.write(json.dumps(error_response) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
