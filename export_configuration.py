#!/usr/bin/env python3
"""Export the iPhone config locally with owner-only permissions. Never print values."""
import argparse
import json
import os
from pathlib import Path

FIELDS = ("openAIApiKey", "anthropicApiKey", "cleanupModel", "cleanupPrompt", "cleanupMaxTokens",
          "transcriptionModel", "transcriptionPrompt", "transcriptionKeywords")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source", type=Path, default=Path.home() / ".config/voice-dictate/config.json")
    args = parser.parse_args()
    try:
        original = json.loads(args.source.read_text())
        payload = {key: original[key] for key in FIELDS if key in original}
        # O_EXCL refuses to replace existing files or follow symlinks.
        descriptor = os.open(args.destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            json.dump(payload, output)
        print("Configuration exported locally. Import it in Voice Dictate, then delete the transfer file.")
    except Exception:
        parser.exit(1, "Could not export configuration. Check the source and choose a new destination.\n")

if __name__ == "__main__":
    main()
