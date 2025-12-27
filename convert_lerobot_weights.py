#!/usr/bin/env python3
"""
Convert LeRobot weights to OpenPI format by stripping the 'model.' prefix from all keys.

This script loads a safetensors file from LeRobot (which has 'model.' prefix on all keys)
and saves a new safetensors file with the prefix removed for compatibility with OpenPI.

Usage:
    python scripts/convert_lerobot_weights.py --input_path /path/to/lerobot/model.safetensors --output_dir /path/to/output
"""

import os
import shutil
from pathlib import Path

import safetensors
import safetensors.torch
import torch
import tyro


def convert_lerobot_weights(input_path: str, output_dir: str):
    """
    Convert LeRobot weights to OpenPI format.

    Args:
        input_path: Path to the input safetensors file (or directory containing model.safetensors)
        output_dir: Directory to save the converted weights
    """
    # Handle input path - can be file or directory
    input_path = Path(input_path)
    if input_path.is_dir():
        input_file = input_path / "model.safetensors"
        input_dir = input_path
    else:
        input_file = input_path
        input_dir = input_path.parent

    if not input_file.exists():
        raise FileNotFoundError(f"Input file not found: {input_file}")

    print(f"Loading weights from: {input_file}")

    # Load the safetensors file
    state_dict = {}
    with safetensors.safe_open(str(input_file), framework="pt") as f:
        for key in f.keys():
            state_dict[key] = f.get_tensor(key)

    print(f"Loaded {len(state_dict)} tensors")

    # Strip 'model.' prefix from all keys
    converted_state_dict = {}
    for key, value in state_dict.items():
        if key.startswith("model."):
            new_key = key[6:]  # Remove 'model.' prefix (6 characters)
            converted_state_dict[new_key] = value
            print(f"  {key} -> {new_key}")
        else:
            converted_state_dict[key] = value
            print(f"  {key} (no change)")

    # Create output directory
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Save converted weights
    output_file = output_dir / "model.safetensors"
    print(f"\nSaving converted weights to: {output_file}")
    safetensors.torch.save_file(converted_state_dict, str(output_file))

    # Copy other files from input directory if they exist
    files_to_copy = [
        "config.json",
        "train_config.json",
        "policy_preprocessor.json",
        "policy_postprocessor.json",
        "policy_preprocessor_step_2_normalizer_processor.safetensors",
        "policy_postprocessor_step_0_unnormalizer_processor.safetensors",
    ]

    for filename in files_to_copy:
        src = input_dir / filename
        if src.exists():
            dst = output_dir / filename
            print(f"Copying {filename}")
            shutil.copy2(src, dst)

    print(f"\nConversion complete! Output saved to: {output_dir}")
    print(f"Total tensors converted: {len(converted_state_dict)}")


if __name__ == "__main__":
    tyro.cli(convert_lerobot_weights)
