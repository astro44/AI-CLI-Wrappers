#!/usr/bin/env python3
"""
Sync personas and skills to DynamoDB or S3.

Usage:
    python sync_config.py --target dynamodb --table ai_agent_data
    python sync_config.py --target s3 --bucket my-bucket --prefix ai-agent/

Environment:
    AWS_PROFILE: AWS profile to use (default: default)
    AWS_REGION: AWS region (default: us-east-1)
"""

import argparse
import json
import os
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError


def load_json_files(directory: str) -> list:
    """Load all JSON files from a directory."""
    items = []
    dir_path = Path(directory)

    if not dir_path.exists():
        print(f"Directory not found: {directory}")
        return items

    for json_file in dir_path.glob("*.json"):
        try:
            with open(json_file, "r") as f:
                data = json.load(f)
                data["_source_file"] = json_file.name
                items.append(data)
                print(f"  Loaded: {json_file.name}")
        except json.JSONDecodeError as e:
            print(f"  Error loading {json_file.name}: {e}")

    return items


def sync_to_dynamodb(personas: list, skills: list, table_name: str, region: str):
    """Sync personas and skills to DynamoDB."""
    dynamodb = boto3.resource("dynamodb", region_name=region)
    table = dynamodb.Table(table_name)

    print(f"\nSyncing to DynamoDB table: {table_name}")

    # Sync personas
    print("\nSyncing personas...")
    for persona in personas:
        persona_id = persona.get("persona_id")
        if not persona_id:
            print(f"  Skipping persona without persona_id: {persona.get('_source_file')}")
            continue

        item = {
            "PK": f"PERSONA#{persona_id}",
            "SK": "META",
            **{k: v for k, v in persona.items() if not k.startswith("_")}
        }

        try:
            table.put_item(Item=item)
            print(f"  Synced: {persona_id}")
        except ClientError as e:
            print(f"  Error syncing {persona_id}: {e}")

    # Sync skills
    print("\nSyncing skills...")
    for skill in skills:
        skill_id = skill.get("skill_id")
        if not skill_id:
            print(f"  Skipping skill without skill_id: {skill.get('_source_file')}")
            continue

        item = {
            "PK": f"SKILL#{skill_id}",
            "SK": "META",
            **{k: v for k, v in skill.items() if not k.startswith("_")}
        }

        try:
            table.put_item(Item=item)
            print(f"  Synced: {skill_id}")
        except ClientError as e:
            print(f"  Error syncing {skill_id}: {e}")

    print("\nDynamoDB sync complete!")


def sync_to_s3(personas: list, skills: list, bucket: str, prefix: str, region: str):
    """Sync personas and skills to S3."""
    s3 = boto3.client("s3", region_name=region)

    print(f"\nSyncing to S3: s3://{bucket}/{prefix}")

    # Sync personas
    print("\nSyncing personas...")
    for persona in personas:
        persona_id = persona.get("persona_id")
        if not persona_id:
            continue

        key = f"{prefix}personas/{persona_id}.json"
        data = {k: v for k, v in persona.items() if not k.startswith("_")}

        try:
            s3.put_object(
                Bucket=bucket,
                Key=key,
                Body=json.dumps(data, indent=2),
                ContentType="application/json"
            )
            print(f"  Synced: {key}")
        except ClientError as e:
            print(f"  Error syncing {persona_id}: {e}")

    # Sync skills
    print("\nSyncing skills...")
    for skill in skills:
        skill_id = skill.get("skill_id")
        if not skill_id:
            continue

        key = f"{prefix}skills/{skill_id}.json"
        data = {k: v for k, v in skill.items() if not k.startswith("_")}

        try:
            s3.put_object(
                Bucket=bucket,
                Key=key,
                Body=json.dumps(data, indent=2),
                ContentType="application/json"
            )
            print(f"  Synced: {key}")
        except ClientError as e:
            print(f"  Error syncing {skill_id}: {e}")

    print("\nS3 sync complete!")


def main():
    parser = argparse.ArgumentParser(description="Sync personas and skills to AWS")
    parser.add_argument("--target", choices=["dynamodb", "s3"], required=True,
                        help="Target storage (dynamodb or s3)")
    parser.add_argument("--table", default="ai_agent_data",
                        help="DynamoDB table name (for dynamodb target)")
    parser.add_argument("--bucket", help="S3 bucket name (for s3 target)")
    parser.add_argument("--prefix", default="ai-agent/",
                        help="S3 key prefix (for s3 target)")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"),
                        help="AWS region")
    parser.add_argument("--personas-dir", default="personas",
                        help="Directory containing persona JSON files")
    parser.add_argument("--skills-dir", default="skills",
                        help="Directory containing skill JSON files")

    args = parser.parse_args()

    # Get script directory
    script_dir = Path(__file__).parent
    personas_dir = script_dir / args.personas_dir
    skills_dir = script_dir / args.skills_dir

    print("Loading configuration files...")
    print(f"\nPersonas from: {personas_dir}")
    personas = load_json_files(personas_dir)

    print(f"\nSkills from: {skills_dir}")
    skills = load_json_files(skills_dir)

    print(f"\nLoaded {len(personas)} personas and {len(skills)} skills")

    if args.target == "dynamodb":
        sync_to_dynamodb(personas, skills, args.table, args.region)
    elif args.target == "s3":
        if not args.bucket:
            print("Error: --bucket is required for s3 target")
            sys.exit(1)
        sync_to_s3(personas, skills, args.bucket, args.prefix, args.region)


if __name__ == "__main__":
    main()
