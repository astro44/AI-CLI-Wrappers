"""
AI-Agent-Codex Lambda

Handles all Codex/OpenAI agent operations:
- Invoke: Send messages to GPT-4/Codex with personas, skills, and context
- Sessions: Manage conversation history
- Personas/Skills: Loaded from DynamoDB

Environment Variables:
- OPENAI_API_KEY: OpenAI API key (or use Secrets Manager)
- DYNAMODB_TABLE: Table for personas, skills, sessions
- AWS_REGION: AWS region (default: us-east-1)
"""

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import ClientError

# OpenAI SDK - vendored in Lambda package
from openai import OpenAI

# Initialize clients
dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))
secrets_client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "ai_agent_data")
table = dynamodb.Table(TABLE_NAME)


def get_api_key() -> str:
    """Get OpenAI API key from environment or Secrets Manager."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if api_key:
        return api_key

    # Try Secrets Manager
    secret_name = os.environ.get("OPENAI_SECRET_NAME", "ai-agent/openai-api-key")
    try:
        response = secrets_client.get_secret_value(SecretId=secret_name)
        secret = json.loads(response["SecretString"])
        return secret.get("api_key", secret.get("OPENAI_API_KEY"))
    except ClientError as e:
        raise ValueError(f"Failed to get API key: {e}")


def get_openai_client() -> OpenAI:
    """Initialize OpenAI client."""
    return OpenAI(api_key=get_api_key())


# ============================================================================
# DynamoDB Operations
# ============================================================================

def get_persona(persona_id: str) -> Optional[Dict[str, Any]]:
    """Fetch persona from DynamoDB."""
    try:
        response = table.get_item(
            Key={"PK": f"PERSONA#{persona_id}", "SK": "META"}
        )
        return response.get("Item")
    except ClientError:
        return None


def get_skill(skill_id: str) -> Optional[Dict[str, Any]]:
    """Fetch skill definition from DynamoDB."""
    try:
        response = table.get_item(
            Key={"PK": f"SKILL#{skill_id}", "SK": "META"}
        )
        return response.get("Item")
    except ClientError:
        return None


def get_skills(skill_ids: List[str]) -> List[Dict[str, Any]]:
    """Fetch multiple skills."""
    skills = []
    for skill_id in skill_ids:
        skill = get_skill(skill_id)
        if skill:
            skills.append(skill)
    return skills


def get_session(session_id: str) -> Optional[Dict[str, Any]]:
    """Fetch session from DynamoDB."""
    try:
        response = table.get_item(
            Key={"PK": f"SESSION#{session_id}", "SK": "META"}
        )
        return response.get("Item")
    except ClientError:
        return None


def create_session(person_id: str, persona_id: str) -> Dict[str, Any]:
    """Create a new session."""
    session_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    session = {
        "PK": f"SESSION#{session_id}",
        "SK": "META",
        "session_id": session_id,
        "person_id": person_id,
        "persona_id": persona_id,
        "model": "codex",
        "messages": [],
        "created_at": now,
        "last_active": now,
        "GSI1PK": f"PERSON#{person_id}",
        "GSI1SK": f"SESSION#{now}"
    }

    table.put_item(Item=session)
    return session


def update_session_messages(session_id: str, messages: List[Dict]) -> bool:
    """Update session with new messages."""
    now = datetime.now(timezone.utc).isoformat()
    try:
        table.update_item(
            Key={"PK": f"SESSION#{session_id}", "SK": "META"},
            UpdateExpression="SET messages = :msgs, last_active = :now",
            ExpressionAttributeValues={":msgs": messages, ":now": now}
        )
        return True
    except ClientError:
        return False


def delete_session(session_id: str) -> bool:
    """Delete a session."""
    try:
        table.delete_item(
            Key={"PK": f"SESSION#{session_id}", "SK": "META"}
        )
        return True
    except ClientError:
        return False


def list_sessions(person_id: str, limit: int = 10) -> List[Dict]:
    """List sessions for a person."""
    try:
        response = table.query(
            IndexName="GSI1",
            KeyConditionExpression="GSI1PK = :pk",
            ExpressionAttributeValues={":pk": f"PERSON#{person_id}"},
            ScanIndexForward=False,
            Limit=limit
        )
        return response.get("Items", [])
    except ClientError:
        return []


# ============================================================================
# OpenAI/Codex Invocation
# ============================================================================

def build_system_message(persona: Dict, context: Optional[Dict] = None) -> str:
    """Build system message from persona and context."""
    system_prompt = persona.get("system_prompt", "You are a helpful AI assistant.")

    if context:
        system_prompt += "\n\n## Current Context\n"
        for key, value in context.items():
            if isinstance(value, dict):
                system_prompt += f"\n### {key}\n"
                for k, v in value.items():
                    if isinstance(v, list):
                        system_prompt += f"- {k}: {', '.join(str(i) for i in v)}\n"
                    else:
                        system_prompt += f"- {k}: {v}\n"
            elif isinstance(value, list):
                system_prompt += f"\n{key}: {', '.join(str(i) for i in value)}"
            else:
                system_prompt += f"\n{key}: {value}"

    return system_prompt


def skills_to_functions(skills: List[Dict]) -> List[Dict]:
    """Convert skill definitions to OpenAI function format."""
    functions = []
    for skill in skills:
        func = {
            "type": "function",
            "function": {
                "name": skill.get("name", skill.get("skill_id")),
                "description": skill.get("description", ""),
                "parameters": skill.get("input_schema", {"type": "object", "properties": {}})
            }
        }
        functions.append(func)
    return functions


def invoke_codex(
    messages: List[Dict],
    persona: Dict,
    skills: Optional[List[Dict]] = None,
    context: Optional[Dict] = None
) -> Dict[str, Any]:
    """
    Invoke OpenAI/Codex with persona, skills, and context.

    Args:
        messages: Conversation history [{role, content}, ...]
        persona: Persona configuration with system_prompt, model, etc.
        skills: Optional list of skill definitions (converted to functions)
        context: Optional context to inject into system message

    Returns:
        Response dict with content, tokens_used, etc.
    """
    client = get_openai_client()

    # Build system message
    system_message = build_system_message(persona, context)

    # Get model config from persona
    model = persona.get("model_codex", persona.get("model", "gpt-4-turbo-preview"))
    max_tokens = persona.get("max_tokens", 4096)
    temperature = persona.get("temperature", 0.7)

    # Build messages with system message first
    full_messages = [{"role": "system", "content": system_message}] + messages

    # Build request
    request_params = {
        "model": model,
        "messages": full_messages,
        "max_tokens": max_tokens,
        "temperature": temperature
    }

    # Add tools if skills provided
    if skills:
        request_params["tools"] = skills_to_functions(skills)
        request_params["tool_choice"] = "auto"

    try:
        response = client.chat.completions.create(**request_params)

        choice = response.choices[0]
        content = choice.message.content or ""

        # Extract tool calls
        tool_calls = []
        if choice.message.tool_calls:
            for tc in choice.message.tool_calls:
                tool_calls.append({
                    "id": tc.id,
                    "name": tc.function.name,
                    "arguments": json.loads(tc.function.arguments)
                })

        return {
            "success": True,
            "content": content,
            "tool_calls": tool_calls,
            "model": model,
            "tokens_used": {
                "input": response.usage.prompt_tokens,
                "output": response.usage.completion_tokens,
                "total": response.usage.total_tokens
            },
            "finish_reason": choice.finish_reason
        }

    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "error_type": type(e).__name__
        }


# ============================================================================
# Lambda Handler
# ============================================================================

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler.

    Supports multiple operations via 'action' parameter:
    - invoke: Send message to Codex/GPT-4
    - create_session: Create new session
    - get_session: Get session details
    - list_sessions: List sessions for a person
    - delete_session: Delete a session
    """
    # Handle API Gateway event format
    if "body" in event:
        body = json.loads(event["body"]) if isinstance(event["body"], str) else event["body"]
    else:
        body = event

    action = body.get("action", "invoke")

    try:
        if action == "invoke":
            return handle_invoke(body)
        elif action == "create_session":
            return handle_create_session(body)
        elif action == "get_session":
            return handle_get_session(body)
        elif action == "list_sessions":
            return handle_list_sessions(body)
        elif action == "delete_session":
            return handle_delete_session(body)
        else:
            return response(400, {"error": f"Unknown action: {action}"})

    except Exception as e:
        return response(500, {"error": str(e), "error_type": type(e).__name__})


def handle_invoke(body: Dict) -> Dict:
    """Handle invoke action."""
    person_id = body.get("person_id")
    persona_id = body.get("persona_id", "default")
    skill_ids = body.get("skill_ids", [])
    message = body.get("message")
    context = body.get("context")
    session_id = body.get("session_id")

    if not message:
        return response(400, {"error": "message is required"})

    # Load persona
    persona = get_persona(persona_id)
    if not persona:
        persona = {
            "system_prompt": "You are a helpful AI assistant.",
            "model_codex": "gpt-4-turbo-preview",
            "max_tokens": 4096,
            "temperature": 0.7
        }

    # Load skills
    skills = get_skills(skill_ids) if skill_ids else None

    # Get or create session
    if session_id:
        session = get_session(session_id)
        if not session:
            return response(404, {"error": "Session not found"})
        messages = session.get("messages", [])
    else:
        session = create_session(person_id or "anonymous", persona_id)
        session_id = session["session_id"]
        messages = []

    # Add user message
    messages.append({"role": "user", "content": message})

    # Invoke Codex
    result = invoke_codex(
        messages=messages,
        persona=persona,
        skills=skills,
        context=context
    )

    if result["success"]:
        messages.append({"role": "assistant", "content": result["content"]})
        update_session_messages(session_id, messages)

        return response(200, {
            "session_id": session_id,
            "response": result["content"],
            "tool_calls": result.get("tool_calls", []),
            "tokens_used": result["tokens_used"],
            "model": result["model"]
        })
    else:
        return response(500, {
            "error": result["error"],
            "error_type": result.get("error_type")
        })


def handle_create_session(body: Dict) -> Dict:
    """Handle create_session action."""
    person_id = body.get("person_id")
    persona_id = body.get("persona_id", "default")

    if not person_id:
        return response(400, {"error": "person_id is required"})

    session = create_session(person_id, persona_id)

    return response(200, {
        "session_id": session["session_id"],
        "person_id": person_id,
        "persona_id": persona_id,
        "created_at": session["created_at"]
    })


def handle_get_session(body: Dict) -> Dict:
    """Handle get_session action."""
    session_id = body.get("session_id")

    if not session_id:
        return response(400, {"error": "session_id is required"})

    session = get_session(session_id)
    if not session:
        return response(404, {"error": "Session not found"})

    return response(200, {
        "session_id": session["session_id"],
        "person_id": session.get("person_id"),
        "persona_id": session.get("persona_id"),
        "message_count": len(session.get("messages", [])),
        "created_at": session.get("created_at"),
        "last_active": session.get("last_active")
    })


def handle_list_sessions(body: Dict) -> Dict:
    """Handle list_sessions action."""
    person_id = body.get("person_id")
    limit = body.get("limit", 10)

    if not person_id:
        return response(400, {"error": "person_id is required"})

    sessions = list_sessions(person_id, limit)

    return response(200, {
        "person_id": person_id,
        "sessions": [
            {
                "session_id": s["session_id"],
                "persona_id": s.get("persona_id"),
                "message_count": len(s.get("messages", [])),
                "created_at": s.get("created_at"),
                "last_active": s.get("last_active")
            }
            for s in sessions
        ]
    })


def handle_delete_session(body: Dict) -> Dict:
    """Handle delete_session action."""
    session_id = body.get("session_id")

    if not session_id:
        return response(400, {"error": "session_id is required"})

    success = delete_session(session_id)

    if success:
        return response(200, {"deleted": True, "session_id": session_id})
    else:
        return response(404, {"error": "Session not found or delete failed"})


def response(status_code: int, body: Dict) -> Dict:
    """Format Lambda response for API Gateway."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps(body)
    }
